const std = @import("std");

const cbor = @import("../cbor/term.zig");
const chainsync_codec = @import("chainsync_codec.zig");
const handshake_codec = @import("../handshake/handshake_codec.zig");
const mux_bearer = @import("../muxwire/mux_bearer.zig");
const bt_boundary = @import("../transport/byte_transport.zig");
const tcp_bt = @import("../transport/tcp_byte_transport.zig");

const chainsync_proto: u16 = 2;

fn printPoint(term: cbor.Term) void {
    if (term == .array) {
        const items = term.array;
        if (items.len == 0) {
            std.debug.print("point: origin\n", .{});
            return;
        }
        if (items.len >= 2 and items[0] == .u64 and items[1] == .bytes) {
            const slot = items[0].u64;
            const hash = items[1].bytes;
            const end = if (hash.len < 8) hash.len else 8;
            std.debug.print(
                "point: slot={d} hash={s}\n",
                .{ slot, std.fmt.fmtSliceHexLower(hash[0..end]) },
            );
            return;
        }
    }
    std.debug.print("point: (opaque)\n", .{});
}

fn cloneTerm(alloc: std.mem.Allocator, term: cbor.Term) !cbor.Term {
    return switch (term) {
        .u64 => |v| cbor.Term{ .u64 = v },
        .i64 => |v| cbor.Term{ .i64 = v },
        .bool => |v| cbor.Term{ .bool = v },
        .bytes => |b| cbor.Term{ .bytes = try alloc.dupe(u8, b) },
        .text => |t| cbor.Term{ .text = try alloc.dupe(u8, t) },
        .array => |items| blk: {
            var out = try alloc.alloc(cbor.Term, items.len);
            errdefer {
                for (out) |item| cbor.free(item, alloc);
                alloc.free(out);
            }
            for (items, 0..) |item, i| {
                out[i] = try cloneTerm(alloc, item);
            }
            break :blk cbor.Term{ .array = out };
        },
        .map_u64 => |entries| blk: {
            var out = try alloc.alloc(cbor.MapEntry, entries.len);
            errdefer {
                for (out) |e| cbor.free(e.value, alloc);
                alloc.free(out);
            }
            for (entries, 0..) |e, i| {
                out[i] = .{ .key = e.key, .value = try cloneTerm(alloc, e.value) };
            }
            break :blk cbor.Term{ .map_u64 = out };
        },
    };
}

fn storeTip(alloc: std.mem.Allocator, last_tip: *?cbor.Term, tip: cbor.Term) !void {
    if (last_tip.*) |existing| {
        cbor.free(existing, alloc);
    }
    last_tip.* = try cloneTerm(alloc, tip);
}

fn printIndent(level: usize) void {
    var i: usize = 0;
    while (i < level) : (i += 1) {
        std.debug.print("  ", .{});
    }
}

fn printTerm(term: cbor.Term, level: usize) void {
    switch (term) {
        .u64 => |v| {
            printIndent(level);
            std.debug.print("u64 {d}\n", .{v});
        },
        .i64 => |v| {
            printIndent(level);
            std.debug.print("i64 {d}\n", .{v});
        },
        .bool => |v| {
            printIndent(level);
            std.debug.print("bool {s}\n", .{if (v) "true" else "false"});
        },
        .text => |v| {
            printIndent(level);
            std.debug.print("text \"{s}\"\n", .{v});
        },
        .bytes => |v| {
            const end = if (v.len < 8) v.len else 8;
            printIndent(level);
            std.debug.print(
                "bytes {s} len={d}\n",
                .{ std.fmt.fmtSliceHexLower(v[0..end]), v.len },
            );
        },
        .array => |items| {
            printIndent(level);
            std.debug.print("array len={d}\n", .{items.len});
            for (items) |item| {
                printTerm(item, level + 1);
            }
        },
        .map_u64 => |entries| {
            printIndent(level);
            std.debug.print("map_u64 len={d}\n", .{entries.len});
            for (entries) |entry| {
                printIndent(level + 1);
                std.debug.print("key {d}\n", .{entry.key});
                printTerm(entry.value, level + 2);
            }
        },
    }
}

fn printBlockShallow(term: cbor.Term) void {
    std.debug.print("block term:\n", .{});
    switch (term) {
        .array => |items| {
            std.debug.print("array len={d}\n", .{items.len});
            const max_items = if (items.len < 2) items.len else 2;
            var i: usize = 0;
            while (i < max_items) : (i += 1) {
                const item = items[i];
                switch (item) {
                    .u64 => |v| std.debug.print("  [{d}] u64 {d}\n", .{ i, v }),
                    .bytes => |b| std.debug.print("  [{d}] bytes len={d}\n", .{ i, b.len }),
                    .array => std.debug.print("  [{d}] array\n", .{i}),
                    .map_u64 => std.debug.print("  [{d}] map_u64\n", .{i}),
                    .i64 => std.debug.print("  [{d}] i64\n", .{i}),
                    .bool => std.debug.print("  [{d}] bool\n", .{i}),
                    .text => std.debug.print("  [{d}] text\n", .{i}),
                }
            }
        },
        .map_u64 => |entries| {
            std.debug.print("map len={d}\n", .{entries.len});
        },
        .u64 => std.debug.print("block: u64\n", .{}),
        .i64 => std.debug.print("block: i64\n", .{}),
        .bool => std.debug.print("block: bool\n", .{}),
        .text => std.debug.print("block: text\n", .{}),
        .bytes => std.debug.print("block: bytes\n", .{}),
    }
}

fn printBlockHash(alloc: std.mem.Allocator, term: cbor.Term) void {
    if (term == .array) {
        const items = term.array;
        if (items.len >= 2 and items[0] == .u64 and items[1] == .bytes) {
            const era_id = items[0].u64;
            const bytes = items[1].bytes;
            var digest: [32]u8 = undefined;
            std.crypto.hash.blake2.Blake2b256.hash(bytes, &digest, .{});
            std.debug.print(
                "block: era={d} bytes={d} blake2b256={s}\n",
                .{ era_id, bytes.len, std.fmt.fmtSliceHexLower(&digest) },
            );

            const prefix_len = if (bytes.len < 16) bytes.len else 16;
            std.debug.print(
                "block: era={d} bytes={d} prefix={s}\n",
                .{ era_id, bytes.len, std.fmt.fmtSliceHexLower(bytes[0..prefix_len]) },
            );
            if (bytes.len > 0) {
                const major: u8 = bytes[0] >> 5;
                const kind = switch (major) {
                    0 => "uint",
                    1 => "negint",
                    2 => "bytes",
                    3 => "text",
                    4 => "array",
                    5 => "map",
                    6 => "tag",
                    else => "simple",
                };
                std.debug.print("cbor top: {s}\n", .{kind});
            }
            if (!printTag24Inner(alloc, bytes)) {
                std.debug.print("block inner: (not tag24)\n", .{});
            }
        }
    }
}

fn printTag24Inner(alloc: std.mem.Allocator, bytes: []const u8) bool {
    if (bytes.len == 0) return false;
    if ((bytes[0] >> 5) != 6) return false;

    var index: usize = 1;
    const ai: u8 = bytes[0] & 0x1f;
    var tag: u32 = 0;
    switch (ai) {
        0...23 => tag = ai,
        24 => {
            if (index + 1 > bytes.len) return false;
            tag = bytes[index];
            index += 1;
        },
        25 => {
            if (index + 2 > bytes.len) return false;
            tag = (@as(u32, bytes[index]) << 8) | bytes[index + 1];
            index += 2;
        },
        26 => {
            if (index + 4 > bytes.len) return false;
            tag = (@as(u32, bytes[index]) << 24) |
                (@as(u32, bytes[index + 1]) << 16) |
                (@as(u32, bytes[index + 2]) << 8) |
                bytes[index + 3];
            index += 4;
        },
        else => return false,
    }
    if (tag != 24) return false;
    if (index >= bytes.len) return false;

    const item_head = bytes[index];
    if ((item_head >> 5) != 2) return false;
    index += 1;

    const item_ai: u8 = item_head & 0x1f;
    var len: usize = 0;
    switch (item_ai) {
        0...23 => len = item_ai,
        24 => {
            if (index + 1 > bytes.len) return false;
            len = bytes[index];
            index += 1;
        },
        25 => {
            if (index + 2 > bytes.len) return false;
            len = (@as(usize, bytes[index]) << 8) | bytes[index + 1];
            index += 2;
        },
        26 => {
            if (index + 4 > bytes.len) return false;
            len = (@as(usize, bytes[index]) << 24) |
                (@as(usize, bytes[index + 1]) << 16) |
                (@as(usize, bytes[index + 2]) << 8) |
                bytes[index + 3];
            index += 4;
        },
        else => return false,
    }
    if (index + len > bytes.len) return false;
    const inner = bytes[index .. index + len];
    const prefix_len = if (inner.len < 16) inner.len else 16;
    std.debug.print(
        "block inner: bytes={d} prefix={s}\n",
        .{ inner.len, std.fmt.fmtSliceHexLower(inner[0..prefix_len]) },
    );
    if (inner.len == 0) {
        std.debug.print("block inner cbor top: (empty)\n", .{});
        return true;
    }

    const inner_major: u8 = inner[0] >> 5;
    const inner_kind = switch (inner_major) {
        0 => "uint",
        1 => "negint",
        2 => "bytes",
        3 => "text",
        4 => "array",
        5 => "map",
        6 => "tag",
        else => "simple",
    };
    std.debug.print("block inner cbor top: {s}\n", .{inner_kind});

    if (inner_major != 4) return true;
    var inner_index: usize = 1;
    const inner_ai: u8 = inner[0] & 0x1f;
    var array_len: usize = 0;
    switch (inner_ai) {
        0...23 => array_len = inner_ai,
        24 => {
            if (inner_index + 1 > inner.len) return true;
            array_len = inner[inner_index];
            inner_index += 1;
        },
        25 => {
            if (inner_index + 2 > inner.len) return true;
            array_len = (@as(usize, inner[inner_index]) << 8) | inner[inner_index + 1];
            inner_index += 2;
        },
        26 => {
            if (inner_index + 4 > inner.len) return true;
            array_len = (@as(usize, inner[inner_index]) << 24) |
                (@as(usize, inner[inner_index + 1]) << 16) |
                (@as(usize, inner[inner_index + 2]) << 8) |
                inner[inner_index + 3];
            inner_index += 4;
        },
        else => return true,
    }
    if (array_len != 2) return true;

    var fbs = std.io.fixedBufferStream(inner[inner_index..]);
    const t0 = cbor.decode(alloc, fbs.reader()) catch {
        std.debug.print("block inner inspect: failed\n", .{});
        return true;
    };
    defer cbor.free(t0, alloc);
    const t1 = cbor.decode(alloc, fbs.reader()) catch {
        std.debug.print("block inner inspect: failed\n", .{});
        return true;
    };
    defer cbor.free(t1, alloc);

    printTermShallow(0, t0);
    printHeaderShallow(alloc, t0);
    printTermShallow(1, t1);
    if (t1 == .bytes) {
        const inner1 = t1.bytes;
        if (inner1.len > 0) {
            const major: u8 = inner1[0] >> 5;
            const kind = switch (major) {
                0 => "uint",
                1 => "negint",
                2 => "bytes",
                3 => "text",
                4 => "array",
                5 => "map",
                6 => "tag",
                else => "simple",
            };
            std.debug.print("inner1 cbor top: {s}\n", .{kind});
        } else {
            std.debug.print("inner1 cbor top: (empty)\n", .{});
        }

        var inner1_fbs = std.io.fixedBufferStream(inner1);
        const inner1_term = cbor.decode(alloc, inner1_fbs.reader()) catch {
            std.debug.print("inner1 decode: failed\n", .{});
            std.debug.print("inner1 scan:\n", .{});
            scanCborShallow(inner1);
            return true;
        };
        defer cbor.free(inner1_term, alloc);
        printInner1Term(inner1_term);
    }
    return true;
}

fn printTermShallow(index: usize, term: cbor.Term) void {
    switch (term) {
        .u64 => |v| std.debug.print("block inner[{d}]: u64 {d}\n", .{ index, v }),
        .i64 => |v| std.debug.print("block inner[{d}]: i64 {d}\n", .{ index, v }),
        .bool => |v| std.debug.print("block inner[{d}]: bool {s}\n", .{ index, if (v) "true" else "false" }),
        .text => |v| std.debug.print("block inner[{d}]: text len={d}\n", .{ index, v.len }),
        .bytes => |b| {
            const end = if (b.len < 8) b.len else 8;
            std.debug.print(
                "block inner[{d}]: bytes len={d} prefix={s}\n",
                .{ index, b.len, std.fmt.fmtSliceHexLower(b[0..end]) },
            );
        },
        .array => |items| std.debug.print("block inner[{d}]: array len={d}\n", .{ index, items.len }),
        .map_u64 => |entries| std.debug.print("block inner[{d}]: map len={d}\n", .{ index, entries.len }),
    }
}

fn printInner1Term(term: cbor.Term) void {
    switch (term) {
        .u64 => |v| std.debug.print("inner1 term: u64 {d}\n", .{v}),
        .i64 => |v| std.debug.print("inner1 term: i64 {d}\n", .{v}),
        .bool => |v| std.debug.print("inner1 term: bool {s}\n", .{if (v) "true" else "false"}),
        .text => |v| std.debug.print("inner1 term: text len={d}\n", .{v.len}),
        .bytes => |b| {
            const end = if (b.len < 8) b.len else 8;
            std.debug.print(
                "inner1 term: bytes len={d} prefix={s}\n",
                .{ b.len, std.fmt.fmtSliceHexLower(b[0..end]) },
            );
        },
        .array => |items| {
            std.debug.print("inner1 term: array len={d}\n", .{items.len});
            const max_items = if (items.len < 3) items.len else 3;
            var i: usize = 0;
            while (i < max_items) : (i += 1) {
                const item = items[i];
                switch (item) {
                    .u64 => |v| std.debug.print("inner1[{d}]: u64 {d}\n", .{ i, v }),
                    .i64 => |v| std.debug.print("inner1[{d}]: i64 {d}\n", .{ i, v }),
                    .bool => |v| std.debug.print("inner1[{d}]: bool {s}\n", .{ i, if (v) "true" else "false" }),
                    .text => |v| std.debug.print("inner1[{d}]: text len={d}\n", .{ i, v.len }),
                    .bytes => |b| {
                        const end = if (b.len < 8) b.len else 8;
                        std.debug.print(
                            "inner1[{d}]: bytes len={d} prefix={s}\n",
                            .{ i, b.len, std.fmt.fmtSliceHexLower(b[0..end]) },
                        );
                    },
                    .array => |arr| std.debug.print("inner1[{d}]: array len={d}\n", .{ i, arr.len }),
                    .map_u64 => |map| std.debug.print("inner1[{d}]: map len={d}\n", .{ i, map.len }),
                }
            }
        },
        .map_u64 => |entries| {
            std.debug.print("inner1 term: map len={d}\n", .{entries.len});
            const max_entries = if (entries.len < 3) entries.len else 3;
            var i: usize = 0;
            while (i < max_entries) : (i += 1) {
                const entry = entries[i];
                const value = entry.value;
                switch (value) {
                    .u64 => |v| std.debug.print("inner1[{d}]: key={d} u64 {d}\n", .{ i, entry.key, v }),
                    .i64 => |v| std.debug.print("inner1[{d}]: key={d} i64 {d}\n", .{ i, entry.key, v }),
                    .bool => |v| std.debug.print("inner1[{d}]: key={d} bool {s}\n", .{ i, entry.key, if (v) "true" else "false" }),
                    .text => |v| std.debug.print("inner1[{d}]: key={d} text len={d}\n", .{ i, entry.key, v.len }),
                    .bytes => |b| {
                        const end = if (b.len < 8) b.len else 8;
                        std.debug.print(
                            "inner1[{d}]: key={d} bytes len={d} prefix={s}\n",
                            .{ i, entry.key, b.len, std.fmt.fmtSliceHexLower(b[0..end]) },
                        );
                    },
                    .array => |arr| std.debug.print("inner1[{d}]: key={d} array len={d}\n", .{ i, entry.key, arr.len }),
                    .map_u64 => |map| std.debug.print("inner1[{d}]: key={d} map len={d}\n", .{ i, entry.key, map.len }),
                }
            }
        },
    }
}

fn majorName(major: u8) []const u8 {
    return switch (major) {
        0 => "uint",
        1 => "negint",
        2 => "bytes",
        3 => "text",
        4 => "array",
        5 => "map",
        6 => "tag",
        else => "simple",
    };
}

fn readAiValue(bytes: []const u8, index: *usize) ?usize {
    if (index.* >= bytes.len) return null;
    const head = bytes[index.*];
    const ai: u8 = head & 0x1f;
    index.* += 1;
    switch (ai) {
        0...23 => return ai,
        24 => {
            if (index.* + 1 > bytes.len) return null;
            const v = bytes[index.*];
            index.* += 1;
            return v;
        },
        25 => {
            if (index.* + 2 > bytes.len) return null;
            const v = (@as(usize, bytes[index.*]) << 8) | bytes[index.* + 1];
            index.* += 2;
            return v;
        },
        26 => {
            if (index.* + 4 > bytes.len) return null;
            const v = (@as(usize, bytes[index.*]) << 24) |
                (@as(usize, bytes[index.* + 1]) << 16) |
                (@as(usize, bytes[index.* + 2]) << 8) |
                bytes[index.* + 3];
            index.* += 4;
            return v;
        },
        31 => return null,
        else => return null,
    }
}

fn scanItem(bytes: []const u8, index: *usize, label: []const u8) bool {
    if (index.* >= bytes.len) return false;
    const head = bytes[index.*];
    const major: u8 = head >> 5;
    const ai: u8 = head & 0x1f;
    if (ai == 31) {
        std.debug.print("{s}: {s} indefinite (not supported)\n", .{ label, majorName(major) });
        return false;
    }
    const start = index.*;
    const len_or_val = readAiValue(bytes, index) orelse return false;

    switch (major) {
        0 => std.debug.print("{s}: uint {d}\n", .{ label, len_or_val }),
        1 => std.debug.print("{s}: negint {d}\n", .{ label, len_or_val }),
        2, 3 => {
            const kind = if (major == 2) "bytes" else "text";
            if (index.* + len_or_val > bytes.len) return false;
            const end = if (len_or_val < 8) len_or_val else 8;
            std.debug.print(
                "{s}: {s} len={d} prefix={s}\n",
                .{ label, kind, len_or_val, std.fmt.fmtSliceHexLower(bytes[index.* .. index.* + end]) },
            );
            index.* += len_or_val;
        },
        4 => std.debug.print("{s}: array len={d}\n", .{ label, len_or_val }),
        5 => std.debug.print("{s}: map pairs={d}\n", .{ label, len_or_val }),
        6 => std.debug.print("{s}: tag {d}\n", .{ label, len_or_val }),
        else => std.debug.print("{s}: simple ai={d}\n", .{ label, ai }),
    }

    _ = start;
    return true;
}

fn scanCborShallow(bytes: []const u8) void {
    var index: usize = 0;
    if (bytes.len == 0) {
        std.debug.print("inner1 scan: empty\n", .{});
        return;
    }

    if (index >= bytes.len) return;
    const head = bytes[index];
    const major: u8 = head >> 5;
    const ai: u8 = head & 0x1f;
    if (ai == 31) {
        std.debug.print("inner1 scan: {s} indefinite (not supported)\n", .{majorName(major)});
        return;
    }
    const len_or_val = readAiValue(bytes, &index) orelse {
        std.debug.print("inner1 scan: failed\n", .{});
        return;
    };

    if (major == 6) {
        std.debug.print("inner1 scan: tag {d}\n", .{len_or_val});
        if (index >= bytes.len) return;
        const sub_head = bytes[index];
        const sub_major: u8 = sub_head >> 5;
        const sub_ai: u8 = sub_head & 0x1f;
        if (sub_ai == 31) {
            std.debug.print("inner1 scan: {s} indefinite (not supported)\n", .{majorName(sub_major)});
            return;
        }
        const sub_len = readAiValue(bytes, &index) orelse return;
        std.debug.print("inner1 scan: {s}\n", .{majorName(sub_major)});
        if (sub_major == 2 or sub_major == 3) {
            if (index + sub_len > bytes.len) return;
            index += sub_len;
        }
        if (sub_major != 4 and sub_major != 5) return;
        const pairs = sub_len;
        if (sub_major == 4) {
            const max_items = if (pairs < 3) pairs else 3;
            var i: usize = 0;
            while (i < max_items) : (i += 1) {
                if (!scanItem(bytes, &index, "inner1 scan item")) return;
            }
            return;
        }
        const max_pairs = if (pairs < 3) pairs else 3;
        var i: usize = 0;
        while (i < max_pairs) : (i += 1) {
            if (!scanItem(bytes, &index, "inner1 scan key")) return;
            if (!scanItem(bytes, &index, "inner1 scan val")) return;
        }
        return;
    }

    std.debug.print("inner1 scan: {s}\n", .{majorName(major)});
    if (major == 4) {
        const max_items = if (len_or_val < 3) len_or_val else 3;
        var i: usize = 0;
        while (i < max_items) : (i += 1) {
            if (!scanItem(bytes, &index, "inner1 scan item")) return;
        }
        return;
    }
    if (major == 5) {
        const max_pairs = if (len_or_val < 3) len_or_val else 3;
        var i: usize = 0;
        while (i < max_pairs) : (i += 1) {
            if (!scanItem(bytes, &index, "inner1 scan key")) return;
            if (!scanItem(bytes, &index, "inner1 scan val")) return;
        }
        return;
    }
}

fn printHeaderItem(index: usize, term: cbor.Term) void {
    switch (term) {
        .u64 => |v| std.debug.print("header[{d}]: u64 {d}\n", .{ index, v }),
        .i64 => |v| std.debug.print("header[{d}]: i64 {d}\n", .{ index, v }),
        .bool => |v| std.debug.print("header[{d}]: bool {s}\n", .{ index, if (v) "true" else "false" }),
        .text => |v| std.debug.print("header[{d}]: text len={d}\n", .{ index, v.len }),
        .bytes => |b| {
            const end = if (b.len < 8) b.len else 8;
            std.debug.print(
                "header[{d}]: bytes len={d} prefix={s}\n",
                .{ index, b.len, std.fmt.fmtSliceHexLower(b[0..end]) },
            );
        },
        .array => |items| std.debug.print("header[{d}]: array len={d}\n", .{ index, items.len }),
        .map_u64 => |entries| std.debug.print("header[{d}]: map len={d}\n", .{ index, entries.len }),
    }
}

fn printHeaderItemNested(parent: usize, index: usize, term: cbor.Term) void {
    switch (term) {
        .u64 => |v| std.debug.print("header[{d}][{d}]: u64 {d}\n", .{ parent, index, v }),
        .i64 => |v| std.debug.print("header[{d}][{d}]: i64 {d}\n", .{ parent, index, v }),
        .bool => |v| std.debug.print("header[{d}][{d}]: bool {s}\n", .{ parent, index, if (v) "true" else "false" }),
        .text => |v| std.debug.print("header[{d}][{d}]: text len={d}\n", .{ parent, index, v.len }),
        .bytes => |b| {
            const end = if (b.len < 8) b.len else 8;
            std.debug.print(
                "header[{d}][{d}]: bytes len={d} prefix={s}\n",
                .{ parent, index, b.len, std.fmt.fmtSliceHexLower(b[0..end]) },
            );
        },
        .array => |items| std.debug.print("header[{d}][{d}]: array len={d}\n", .{ parent, index, items.len }),
        .map_u64 => |entries| std.debug.print("header[{d}][{d}]: map len={d}\n", .{ parent, index, entries.len }),
    }
}

fn printHeaderShallow(alloc: std.mem.Allocator, term: cbor.Term) void {
    if (term != .array) return;
    const items = term.array;
    if (items.len != 15) return;
    var i: usize = 0;
    while (i < items.len and i < 15) : (i += 1) {
        printHeaderItem(i, items[i]);
    }

    var list = std.ArrayList(u8).init(alloc);
    defer list.deinit();
    cbor.encode(term, list.writer()) catch return;
    const bytes = list.items;
    var digest: [32]u8 = undefined;
    std.crypto.hash.blake2.Blake2b256.hash(bytes, &digest, .{});
    std.debug.print(
        "header: cbor_bytes={d} blake2b256={s}\n",
        .{ bytes.len, std.fmt.fmtSliceHexLower(&digest) },
    );

    if (items.len >= 6 and items[5] == .array) {
        const header5 = items[5].array;
        if (header5.len == 2) {
            printHeaderItemNested(5, 0, header5[0]);
            printHeaderItemNested(5, 1, header5[1]);
            if (header5[0] == .u64 and header5[1] == .bytes) {
                const slot = header5[0].u64;
                const hash = header5[1].bytes;
                const end = if (hash.len < 8) hash.len else 8;
                std.debug.print(
                    "header point candidate: slot={d} hash={s}\n",
                    .{ slot, std.fmt.fmtSliceHexLower(hash[0..end]) },
                );
            }
        }
    }

    if (items.len >= 7 and items[6] == .array) {
        const header6 = items[6].array;
        if (header6.len == 2) {
            printHeaderItemNested(6, 0, header6[0]);
            printHeaderItemNested(6, 1, header6[1]);
            if (header6[0] == .u64 and header6[1] == .bytes and header6[1].bytes.len == 32) {
                const slot = header6[0].u64;
                const hash = header6[1].bytes;
                const end = if (hash.len < 8) hash.len else 8;
                std.debug.print(
                    "header[6] point candidate: slot={d} hash={s}\n",
                    .{ slot, std.fmt.fmtSliceHexLower(hash[0..end]) },
                );
            } else if ((header6[0] == .array and header6[0].array.len == 2 and header6[1] == .u64) or
                (header6[0] == .u64 and header6[1] == .array and header6[1].array.len == 2))
            {
                std.debug.print("header[6] looks nested\n", .{});
            }
        }
    }

    i = 6;
    while (i < items.len and i < 15) : (i += 1) {
        if (items[i] == .array) {
            const entry = items[i].array;
            if (entry.len == 2 and entry[0] == .u64 and entry[1] == .bytes) {
                const slot = entry[0].u64;
                const hash = entry[1].bytes;
                if (hash.len == 32) {
                    const end = if (hash.len < 8) hash.len else 8;
                    std.debug.print(
                        "header point candidate at [{d}]: slot={d} hash={s}\n",
                        .{ i, slot, std.fmt.fmtSliceHexLower(hash[0..end]) },
                    );
                }
            }
        }
    }
}

fn printTipArray(items: []const cbor.Term) void {
    if (items.len == 2 and items[0] == .array and items[1] == .u64) {
        const inner = items[0].array;
        if (inner.len == 2 and inner[0] == .u64 and inner[1] == .bytes) {
            const slot = inner[0].u64;
            const hash = inner[1].bytes;
            const block_no = items[1].u64;
            const end = if (hash.len < 8) hash.len else 8;
            std.debug.print(
                "tip(from msg): slot={d} blockNo={d} hash={s}\n",
                .{ slot, block_no, std.fmt.fmtSliceHexLower(hash[0..end]) },
            );
            return;
        }
    }
    if (items.len >= 1 and items[0] == .u64) {
        if (items.len >= 3 and items[2] == .u64) {
            std.debug.print(
                "tip(from msg): slot={d} blockNo={d}\n",
                .{ items[0].u64, items[2].u64 },
            );
            return;
        }
        std.debug.print("tip(from msg): slot={d}\n", .{items[0].u64});
        return;
    }
    std.debug.print("tip(from msg): (opaque)\n", .{});
    std.debug.print("tip term:\n", .{});
    printTerm(.{ .array = @constCast(items) }, 1);
}

fn printTip(term: cbor.Term) void {
    if (term == .array) {
        const items = term.array;
        if (items.len == 1 and items[0] == .array) {
            printTipArray(items[0].array);
            return;
        }
        printTipArray(items);
        return;
    }
    std.debug.print("tip(from msg): (opaque)\n", .{});
    std.debug.print("tip term:\n", .{});
    printTerm(term, 1);
}

fn doHandshake(alloc: std.mem.Allocator, bt: *bt_boundary.ByteTransport) !bool {
    var version_items = try alloc.alloc(cbor.Term, 4);
    version_items[0] = .{ .u64 = 2 };
    version_items[1] = .{ .bool = false };
    version_items[2] = .{ .u64 = 1 };
    version_items[3] = .{ .bool = false };
    const version_data = cbor.Term{ .array = version_items };

    var entries = try alloc.alloc(cbor.MapEntry, 1);
    entries[0] = .{ .key = 14, .value = version_data };
    var propose = handshake_codec.HandshakeMsg{
        .propose = .{ .versions = .{ .map_u64 = entries } },
    };
    defer handshake_codec.free(alloc, &propose);

    var payload_list = std.ArrayList(u8).init(alloc);
    defer payload_list.deinit();
    try handshake_codec.encodeMsg(propose, payload_list.writer());
    const payload = try payload_list.toOwnedSlice();
    defer alloc.free(payload);

    try mux_bearer.sendSegment(bt, .initiator, 0, payload);

    const seg = try mux_bearer.recvSegment(alloc, bt);
    if (seg == null) return false;
    defer alloc.free(seg.?.payload);

    var fbs = std.io.fixedBufferStream(seg.?.payload);
    var msg = handshake_codec.decodeMsg(alloc, fbs.reader()) catch return false;
    defer handshake_codec.free(alloc, &msg);

    return msg == .accept;
}

pub fn run(alloc: std.mem.Allocator, host: []const u8, port: u16) !void {
    var bt = try tcp_bt.connect(alloc, host, port);
    defer bt.deinit();
    var last_tip: ?cbor.Term = null;
    defer if (last_tip) |tip| {
        cbor.free(tip, alloc);
    };

    const timeout_ms: u32 = 10_000;
    tcp_bt.setReadTimeout(&bt, timeout_ms) catch {};

    const accepted = try doHandshake(alloc, &bt);
    if (!accepted) {
        std.debug.print("chainsync: no response\n", .{});
        return;
    }

    const origin_point = cbor.Term{ .array = @constCast((&[_]cbor.Term{})[0..]) };
    var points_items = try alloc.alloc(cbor.Term, 1);
    defer alloc.free(points_items);
    points_items[0] = origin_point;
    const points = cbor.Term{ .array = points_items };
    var list = std.ArrayList(u8).init(alloc);
    defer list.deinit();
    try chainsync_codec.encodeFindIntersect(list.writer(), points);
    const msg_bytes = try list.toOwnedSlice();
    defer alloc.free(msg_bytes);

    try mux_bearer.sendSegment(&bt, .responder, chainsync_proto, msg_bytes);
    std.debug.print("chainsync: sent FindIntersect ({d} bytes)\n", .{msg_bytes.len});

    const deadline_ms: i64 = std.time.milliTimestamp() + timeout_ms;

    while (true) {
        const now_ms = std.time.milliTimestamp();
        if (now_ms >= deadline_ms) {
            std.debug.print("chainsync: timed out after 10000ms\n", .{});
            return;
        }

        const remaining_ms: u32 = @intCast(deadline_ms - now_ms);
        tcp_bt.setReadTimeout(&bt, remaining_ms) catch {};

        const seg = mux_bearer.recvSegmentWithTimeout(alloc, &bt) catch |err| switch (err) {
            error.TimedOut => continue,
            else => return err,
        };
        if (seg == null) {
            std.debug.print("peer closed\n", .{});
            return;
        }
        defer alloc.free(seg.?.payload);

        const hdr = seg.?.hdr;
        std.debug.print(
            "mux: rx hdr dir={s} proto={d} len={d}\n",
            .{ @tagName(hdr.dir), hdr.proto, hdr.len },
        );

        if (hdr.proto == chainsync_proto) {
            var fbs = std.io.fixedBufferStream(seg.?.payload);
            var msg = try chainsync_codec.decodeResponse(alloc, fbs.reader());
            defer chainsync_codec.free(alloc, &msg);

            switch (msg) {
                .intersect_found => {
                    std.debug.print("chainsync: intersect found\n", .{});
                    printTip(msg.intersect_found.tip);
                    try storeTip(alloc, &last_tip, msg.intersect_found.tip);

                    var req_list = std.ArrayList(u8).init(alloc);
                    defer req_list.deinit();
                    try chainsync_codec.encodeRequestNext(req_list.writer());
                    const req_bytes = try req_list.toOwnedSlice();
                    defer alloc.free(req_bytes);

                    var i: u8 = 0;
                    while (i < 3) : (i += 1) {
                        try mux_bearer.sendSegment(&bt, .responder, chainsync_proto, req_bytes);

                        const req_deadline_ms: i64 = std.time.milliTimestamp() + timeout_ms;
                        var awaiting_reply = true;
                        while (awaiting_reply) {
                            const req_now_ms = std.time.milliTimestamp();
                            if (req_now_ms >= req_deadline_ms) {
                                std.debug.print("chainsync: timed out after 10000ms\n", .{});
                                return;
                            }

                            const req_remaining_ms: u32 = @intCast(req_deadline_ms - req_now_ms);
                            tcp_bt.setReadTimeout(&bt, req_remaining_ms) catch {};

                            const next_seg = mux_bearer.recvSegmentWithTimeout(alloc, &bt) catch |err| switch (err) {
                                error.TimedOut => continue,
                                else => return err,
                            };
                            if (next_seg == null) {
                                std.debug.print("peer closed\n", .{});
                                return;
                            }
                            defer alloc.free(next_seg.?.payload);

                            const next_hdr = next_seg.?.hdr;
                            std.debug.print(
                                "mux: rx hdr dir={s} proto={d} len={d}\n",
                                .{ @tagName(next_hdr.dir), next_hdr.proto, next_hdr.len },
                            );

                            if (next_hdr.proto == chainsync_proto) {
                                var next_fbs = std.io.fixedBufferStream(next_seg.?.payload);
                                var next_msg = try chainsync_codec.decodeResponse(alloc, next_fbs.reader());
                                defer chainsync_codec.free(alloc, &next_msg);

                                switch (next_msg) {
                                    .await_reply => {
                                        std.debug.print("chainsync[{d}]: await reply\n", .{i});
                                        awaiting_reply = true;
                                    },
                                    .roll_forward => {
                                        std.debug.print("chainsync[{d}]: roll forward\n", .{i});
                                        printBlockShallow(next_msg.roll_forward.block);
                                        printBlockHash(alloc, next_msg.roll_forward.block);
                                        printTip(next_msg.roll_forward.tip);
                                        try storeTip(alloc, &last_tip, next_msg.roll_forward.tip);
                                        awaiting_reply = false;
                                    },
                                    .roll_backward => {
                                        std.debug.print("chainsync[{d}]: roll backward\n", .{i});
                                        printPoint(next_msg.roll_backward.point);
                                        printTip(next_msg.roll_backward.tip);
                                        try storeTip(alloc, &last_tip, next_msg.roll_backward.tip);
                                        awaiting_reply = false;
                                    },
                                    else => {
                                        std.debug.print("chainsync[{d}]: no response\n", .{i});
                                        awaiting_reply = false;
                                    },
                                }
                            } else if (next_hdr.proto == 8) {
                                std.debug.print("keepalive: rx (ignored)\n", .{});
                                continue;
                            } else {
                                std.debug.print("mux: rx unexpected proto={d}\n", .{next_hdr.proto});
                                continue;
                            }
                        }
                    }
                    return;
                },
                .intersect_not_found => {
                    std.debug.print("chainsync: intersect not found\n", .{});
                    return;
                },
                else => std.debug.print("chainsync: no response\n", .{}),
            }
            return;
        } else if (hdr.proto == 8) {
            std.debug.print("keepalive: rx (ignored)\n", .{});
            continue;
        } else {
            std.debug.print("mux: rx unexpected proto={d}\n", .{hdr.proto});
            continue;
        }
    }
}
