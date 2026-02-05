const std = @import("std");

const cbor = @import("../cbor/term.zig");
const follower = @import("follower.zig");
const journal = @import("../ledger/journal.zig");
const tps = @import("../ledger/tps.zig");
const utxo_mod = @import("../ledger/utxo.zig");
const utxo_store = @import("../ledger/utxo_store.zig");
const i18n = @import("../../cli/i18n.zig");
const pretty = @import("../../cli/pretty.zig");
const header_raw = @import("../ledger/header_raw.zig");
const cursor_store = @import("../ledger/cursor.zig");

const cursor_dir = "/home/midnight/.tsunagi";
const cursor_path = "/home/midnight/.tsunagi/cursor.json";
const journal_path = "/home/midnight/.tsunagi/journal.ndjson";
const utxo_path = "/home/midnight/.tsunagi/utxo.snapshot";
var g_debug: bool = false;

fn vprint(comptime fmt: []const u8, args: anytype) void {
    if (g_debug) std.debug.print(fmt, args);
}

fn ensureCursorDir() !void {
    std.fs.makeDirAbsolute(cursor_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}

const HeaderCandidate = struct {
    index: usize,
    bytes: []u8,
};

fn freeHeaderCandidates(alloc: std.mem.Allocator, candidates: []HeaderCandidate) void {
    for (candidates) |candidate| {
        alloc.free(candidate.bytes);
    }
    alloc.free(candidates);
}

fn freeHeaderValues(alloc: std.mem.Allocator, values: *[15]?[]u8) void {
    for (values) |maybe_bytes| {
        if (maybe_bytes) |bytes| alloc.free(bytes);
    }
    values.* = [_]?[]u8{null} ** 15;
}

fn printHeader32List(label: []const u8, candidates: []HeaderCandidate) void {
    std.debug.print("{s} [", .{label});
    for (candidates, 0..) |candidate, i| {
        if (i > 0) std.debug.print(",", .{});
        std.debug.print("{d}", .{candidate.index});
    }
    std.debug.print("]\n", .{});
}

fn printContinuityVerdict(
    prev: header_raw.HeaderBodyRawSnapshot,
    curr: header_raw.HeaderBodyRawSnapshot,
    structure_ok: bool,
) void {
    const slot_delta: i64 = @as(i64, @intCast(curr.f0_u64)) - @as(i64, @intCast(prev.f0_u64));
    const block_delta: i64 = @as(i64, @intCast(curr.f1_u64)) - @as(i64, @intCast(prev.f1_u64));
    const protocol_stable = prev.f7_u64 == curr.f7_u64 and
        prev.f13_u64 == curr.f13_u64 and
        prev.f14_u64 == curr.f14_u64;
    const leader_changed = !std.mem.eql(u8, prev.f3_bytes32[0..], curr.f3_bytes32[0..]) or
        !std.mem.eql(u8, prev.f4_bytes32[0..], curr.f4_bytes32[0..]);

    std.debug.print("continuity slot delta={d}\n", .{slot_delta});
    std.debug.print("continuity block number delta={d}\n", .{block_delta});
    std.debug.print("continuity protocol stable={s}\n", .{if (protocol_stable) "true" else "false"});
    std.debug.print("continuity leader changed={s}\n", .{if (leader_changed) "true" else "false"});

    const ok = structure_ok and slot_delta >= 0 and block_delta >= 0 and protocol_stable;
    if (ok) {
        std.debug.print("continuity verdict: OK (light follower)\n", .{});
    } else {
        std.debug.print("continuity verdict: WARN (rollback or protocol change)\n", .{});
    }
}

fn captureFirstRollForward(
    alloc: std.mem.Allocator,
    tip: cbor.Term,
    header_cbor_bytes: []const u8,
    prev_hash: ?[32]u8,
) void {
    _ = alloc;
    const tip_hash = getTipHash(tip);
    if (tip_hash) |hash| {
        if (hash.len == 32) {
            std.debug.print("tip_hash_full={s}\n", .{std.fmt.fmtSliceHexLower(hash)});
        }
    }

    std.debug.print("header_cbor_len={d}\n", .{header_cbor_bytes.len});
    std.debug.print(
        "header_cbor_hex={s}\n",
        .{std.fmt.fmtSliceHexLower(header_cbor_bytes)},
    );

    const header_hash = follower.headerHashBlake2b256(header_cbor_bytes);
    std.debug.print("header_hash={s}\n", .{std.fmt.fmtSliceHexLower(&header_hash)});
    if (prev_hash) |hash| {
        std.debug.print("prev_hash={s}\n", .{std.fmt.fmtSliceHexLower(&hash)});
    } else {
        std.debug.print("prev_hash=(null)\n", .{});
    }
}

fn writeCaptureFile(tip: cbor.Term, header_cbor_bytes: []const u8) !void {
    var file = try std.fs.createFileAbsolute("/tmp/tsunagi_capture.txt", .{ .truncate = true });
    defer file.close();

    const tip_hash = getTipHash(tip);
    if (tip_hash) |hash| {
        if (hash.len == 32) {
            try file.writer().print(
                "tip_hash_full={s}\n",
                .{std.fmt.fmtSliceHexLower(hash)},
            );
        } else {
            try file.writer().print("tip_hash_full=(invalid)\n", .{});
        }
    } else {
        try file.writer().print("tip_hash_full=(null)\n", .{});
    }

    try file.writer().print(
        "header_cbor_hex={s}\n",
        .{std.fmt.fmtSliceHexLower(header_cbor_bytes)},
    );
    try file.writer().print("header_cbor_len={d}\n", .{header_cbor_bytes.len});
}

fn collectHeaderCandidates(alloc: std.mem.Allocator, block: cbor.Term) ![]HeaderCandidate {
    var list = std.ArrayList(HeaderCandidate).init(alloc);
    errdefer {
        for (list.items) |candidate| {
            alloc.free(candidate.bytes);
        }
        list.deinit();
    }

    if (block != .array) return list.toOwnedSlice();
    const items = block.array;
    if (items.len < 2) return list.toOwnedSlice();

    const block_bytes = blk: {
        if (items[1] == .bytes) break :blk items[1].bytes;
        if (items[1] == .tag and items[1].tag.tag == 24 and items[1].tag.value.* == .bytes) {
            break :blk items[1].tag.value.*.bytes;
        }
        return list.toOwnedSlice();
    };

    const inner_bytes = header_raw.getTag24InnerBytes(block_bytes) orelse block_bytes;
    var fbs = std.io.fixedBufferStream(inner_bytes);
    const top = cbor.decode(alloc, fbs.reader()) catch return list.toOwnedSlice();
    defer cbor.free(top, alloc);

    if (top != .array) return list.toOwnedSlice();
    const top_items = top.array;
    if (top_items.len == 0 or top_items[0] != .array) return list.toOwnedSlice();

    for (top_items[0].array, 0..) |item, i| {
        if (item == .bytes and item.bytes.len == 32) {
            const copy = try alloc.dupe(u8, item.bytes);
            try list.append(.{ .index = i, .bytes = copy });
        }
    }

    return list.toOwnedSlice();
}

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
        .null => {
            printIndent(level);
            std.debug.print("null\n", .{});
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
        .tag => |t| {
            printIndent(level);
            std.debug.print("tag {d}\n", .{t.tag});
            printTerm(t.value.*, level + 1);
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
                    .null => std.debug.print("  [{d}] null\n", .{i}),
                    .tag => |t| std.debug.print("  [{d}] tag {d}\n", .{ i, t.tag }),
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
        .null => std.debug.print("block: null\n", .{}),
        .tag => |t| std.debug.print("block: tag {d}\n", .{t.tag}),
    }
}

fn printBlockHash(alloc: std.mem.Allocator, term: cbor.Term, tip_hash: ?[]const u8) void {
    if (term == .array) {
        const items = term.array;
        if (items.len >= 2 and items[0] == .u64) {
            const era_id = items[0].u64;
            const bytes = blk: {
                if (items[1] == .bytes) break :blk items[1].bytes;
                if (items[1] == .tag and items[1].tag.tag == 24 and items[1].tag.value.* == .bytes) {
                    const tag_bytes = items[1].tag.value.*.bytes;
                    var tag_digest: [32]u8 = undefined;
                    std.crypto.hash.blake2.Blake2b256.hash(tag_bytes, &tag_digest, .{});
                    std.debug.print(
                        "block_tag24_hash={s} bytes={d}\n",
                        .{ std.fmt.fmtSliceHexLower(&tag_digest), tag_bytes.len },
                    );
                    var tag_full_list = std.ArrayList(u8).init(alloc);
                    defer tag_full_list.deinit();
                    cbor.encode(items[1], tag_full_list.writer()) catch return;
                    var tag_full_digest: [32]u8 = undefined;
                    std.crypto.hash.blake2.Blake2b256.hash(tag_full_list.items, &tag_full_digest, .{});
                    std.debug.print(
                        "block_tag24_full_hash={s} bytes={d}\n",
                        .{ std.fmt.fmtSliceHexLower(&tag_full_digest), tag_full_list.items.len },
                    );
                    if (tip_hash) |hash| {
                        if (hash.len == 32 and std.mem.eql(u8, tag_digest[0..], hash)) {
                            std.debug.print("match: tip_hash == block_tag24_hash\n", .{});
                        }
                        const tip_prefix = hash[0..8];
                        const tag_prefix = tag_digest[0..8];
                        std.debug.print(
                            "tip_hash_prefix={s}\n",
                            .{std.fmt.fmtSliceHexLower(tip_prefix)},
                        );
                        std.debug.print(
                            "tag24_hash_prefix={s} eq={s}\n",
                            .{
                                std.fmt.fmtSliceHexLower(tag_prefix),
                                if (std.mem.eql(u8, tag_digest[0..], hash)) "true" else "false",
                            },
                        );
                        std.debug.print(
                            "eq_tip_vs_tag24_full={s}\n",
                            .{if (std.mem.eql(u8, tag_full_digest[0..], hash)) "true" else "false"},
                        );
                    }
                    break :blk tag_bytes;
                }
                return;
            };
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
                printInnerBytes(alloc, bytes, tip_hash);
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
    printInnerBytes(alloc, inner, null);
    return true;
}

fn printInnerBytes(alloc: std.mem.Allocator, inner: []const u8, tip_hash: ?[]const u8) void {
    const prefix_len = if (inner.len < 16) inner.len else 16;
    std.debug.print(
        "block inner: bytes={d} prefix={s}\n",
        .{ inner.len, std.fmt.fmtSliceHexLower(inner[0..prefix_len]) },
    );
    if (inner.len == 0) {
        std.debug.print("block inner cbor top: (empty)\n", .{});
        return;
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

    if (inner_major != 4) return;
    var inner_index: usize = 1;
    const inner_ai: u8 = inner[0] & 0x1f;
    var array_len: usize = 0;
    switch (inner_ai) {
        0...23 => array_len = inner_ai,
        24 => {
            if (inner_index + 1 > inner.len) return;
            array_len = inner[inner_index];
            inner_index += 1;
        },
        25 => {
            if (inner_index + 2 > inner.len) return;
            array_len = (@as(usize, inner[inner_index]) << 8) | inner[inner_index + 1];
            inner_index += 2;
        },
        26 => {
            if (inner_index + 4 > inner.len) return;
            array_len = (@as(usize, inner[inner_index]) << 24) |
                (@as(usize, inner[inner_index + 1]) << 16) |
                (@as(usize, inner[inner_index + 2]) << 8) |
                inner[inner_index + 3];
            inner_index += 4;
        },
        else => return,
    }
    if (array_len != 2) return;

    var fbs = std.io.fixedBufferStream(inner[inner_index..]);
    const t0 = cbor.decode(alloc, fbs.reader()) catch {
        std.debug.print("block inner inspect: failed\n", .{});
        return;
    };
    defer cbor.free(t0, alloc);
    const t1 = cbor.decode(alloc, fbs.reader()) catch {
        std.debug.print("block inner inspect: failed\n", .{});
        return;
    };
    defer cbor.free(t1, alloc);

    printTermShallow(0, t0);
    if (header_raw.decodeHeaderBodyRaw(t0)) |header_body| {
        header_raw.printHeaderBodyRaw(header_body);
    } else {
        std.debug.print("HeaderBodyRaw parse failed\n", .{});
    }
    printHeaderShallow(alloc, t0, tip_hash);
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
        std.debug.print("inner1 scan:\n", .{});
        scanCborShallow(inner1);
    }
}

fn printTermShallow(index: usize, term: cbor.Term) void {
    switch (term) {
        .u64 => |v| std.debug.print("block inner[{d}]: u64 {d}\n", .{ index, v }),
        .i64 => |v| std.debug.print("block inner[{d}]: i64 {d}\n", .{ index, v }),
        .bool => |v| std.debug.print("block inner[{d}]: bool {s}\n", .{ index, if (v) "true" else "false" }),
        .null => std.debug.print("block inner[{d}]: null\n", .{index}),
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
        .tag => |t| std.debug.print("block inner[{d}]: tag {d}\n", .{ index, t.tag }),
    }
}

fn printInner1Term(term: cbor.Term) void {
    switch (term) {
        .u64 => |v| std.debug.print("inner1 term: u64 {d}\n", .{v}),
        .i64 => |v| std.debug.print("inner1 term: i64 {d}\n", .{v}),
        .bool => |v| std.debug.print("inner1 term: bool {s}\n", .{if (v) "true" else "false"}),
        .null => std.debug.print("inner1 term: null\n", .{}),
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
                    .null => std.debug.print("inner1[{d}]: null\n", .{i}),
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
                    .tag => |t| std.debug.print("inner1[{d}]: tag {d}\n", .{ i, t.tag }),
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
                    .null => std.debug.print("inner1[{d}]: key={d} null\n", .{ i, entry.key }),
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
                    .tag => |t| std.debug.print("inner1[{d}]: key={d} tag {d}\n", .{ i, entry.key, t.tag }),
                }
            }
        },
        .tag => |t| std.debug.print("inner1 term: tag {d}\n", .{t.tag}),
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
        .null => std.debug.print("header[{d}]: null\n", .{index}),
        .text => |v| std.debug.print("header[{d}]: text len={d}\n", .{ index, v.len }),
        .bytes => |b| {
            if (index == 8 and b.len == 32) {
                std.debug.print("prev_hash: {s}\n", .{std.fmt.fmtSliceHexLower(b)});
                return;
            }
            const end = if (b.len < 8) b.len else 8;
            std.debug.print(
                "header[{d}]: bytes len={d} prefix={s}\n",
                .{ index, b.len, std.fmt.fmtSliceHexLower(b[0..end]) },
            );
        },
        .array => |items| std.debug.print("header[{d}]: array len={d}\n", .{ index, items.len }),
        .map_u64 => |entries| std.debug.print("header[{d}]: map len={d}\n", .{ index, entries.len }),
        .tag => |t| std.debug.print("header[{d}]: tag {d}\n", .{ index, t.tag }),
    }
}

fn printHeaderItemNested(parent: usize, index: usize, term: cbor.Term) void {
    switch (term) {
        .u64 => |v| std.debug.print("header[{d}][{d}]: u64 {d}\n", .{ parent, index, v }),
        .i64 => |v| std.debug.print("header[{d}][{d}]: i64 {d}\n", .{ parent, index, v }),
        .bool => |v| std.debug.print("header[{d}][{d}]: bool {s}\n", .{ parent, index, if (v) "true" else "false" }),
        .null => std.debug.print("header[{d}][{d}]: null\n", .{ parent, index }),
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
        .tag => |t| std.debug.print("header[{d}][{d}]: tag {d}\n", .{ parent, index, t.tag }),
    }
}

fn printHeaderShallow(alloc: std.mem.Allocator, term: cbor.Term, tip_hash: ?[]const u8) void {
    if (term != .array) return;
    const items = term.array;
    if (items.len != 15) return;
    // HeaderBody index hints (suspected):
    //  0: slot
    //  1: block_no
    //  2: prev_hash (Maybe)
    //  3: issuer_vkey
    //  4: vrf_vkey
    //  5: vrf_result
    //  6: kes_info
    //  7: era
    //  8: constant_nonce / reserved
    //  9: metadata_hash
    // 10: body_size?
    // 11: body_hash?
    // 12: opcert / protocol?
    // 13: proto_version?
    // 14: extra / reserved
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
        "block_inner_hash={s} bytes={d}\n",
        .{ std.fmt.fmtSliceHexLower(&digest), bytes.len },
    );
    if (tip_hash) |hash| {
        if (hash.len == 32 and std.mem.eql(u8, digest[0..], hash)) {
            std.debug.print("match: tip_hash == block_inner_hash\n", .{});
        }
        const tip_prefix = hash[0..8];
        const inner_prefix = digest[0..8];
        std.debug.print(
            "tip_hash_prefix={s}\n",
            .{std.fmt.fmtSliceHexLower(tip_prefix)},
        );
        std.debug.print(
            "inner_hash_prefix={s} eq={s}\n",
            .{
                std.fmt.fmtSliceHexLower(inner_prefix),
                if (std.mem.eql(u8, digest[0..], hash)) "true" else "false",
            },
        );
    }

    var header32_indices: [15]usize = undefined;
    var header32_count: usize = 0;
    i = 0;
    while (i < items.len and i < 15) : (i += 1) {
        if (items[i] == .bytes and items[i].bytes.len == 32) {
            header32_indices[header32_count] = i;
            header32_count += 1;
            if (tip_hash) |hash| {
                if (hash.len == 32 and std.mem.eql(u8, items[i].bytes, hash)) {
                    std.debug.print("match: tip_hash == header[{d}]\n", .{i});
                }
            }
        }
    }
    if (header32_count > 0) {
        std.debug.print("header32 fields: [", .{});
        i = 0;
        while (i < header32_count) : (i += 1) {
            if (i > 0) std.debug.print(",", .{});
            std.debug.print("{d}", .{header32_indices[i]});
        }
        std.debug.print("]\n", .{});
    }

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

fn getTipHash(term: cbor.Term) ?[]const u8 {
    if (term != .array) return null;
    const items = term.array;
    const inner = blk: {
        if (items.len == 1 and items[0] == .array) break :blk items[0].array;
        break :blk items;
    };
    if (inner.len != 2) return null;
    if (inner[0] != .array or inner[1] != .u64) return null;
    const point = inner[0].array;
    if (point.len != 2) return null;
    if (point[0] != .u64 or point[1] != .bytes) return null;
    if (point[1].bytes.len != 32) return null;
    return point[1].bytes;
}

const TipSlotBlock = struct {
    slot: u64,
    block_no: u64,
};

fn getTipSlotBlock(term: cbor.Term) ?TipSlotBlock {
    if (term != .array) return null;
    const items = term.array;
    const inner = blk: {
        if (items.len == 1 and items[0] == .array) break :blk items[0].array;
        break :blk items;
    };
    if (inner.len == 2 and inner[0] == .array and inner[1] == .u64) {
        const point = inner[0].array;
        if (point.len == 2 and point[0] == .u64 and point[1] == .bytes) {
            return .{ .slot = point[0].u64, .block_no = inner[1].u64 };
        }
    }
    if (inner.len >= 3 and inner[0] == .u64 and inner[2] == .u64) {
        return .{ .slot = inner[0].u64, .block_no = inner[2].u64 };
    }
    return null;
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

const FollowerCtx = struct {
    base: follower.Context,
    alloc: std.mem.Allocator,
    tps_meter: ?tps.TpsMeter = null,
    utxo: utxo_mod.UTxO,
    undo_stack: std.ArrayList(utxo_mod.Undo),
    debug: bool,
    lang: i18n.Lang,
    pretty: bool,
    last_status_unix: i64 = 0,
    stopping: bool = false,
    prev_candidates: ?[]HeaderCandidate = null,
    prev_header_values: [15]?[]u8 = [_]?[]u8{null} ** 15,
    prev_changed: [15]bool = [_]bool{false} ** 15,
    captured_first_rollforward: bool = false,
    prev_header_hash_opt: ?[32]u8 = null,
    prev_header_cbor_len: ?usize = null,
    prev_header_body_raw: ?header_raw.HeaderBodyRawSnapshot = null,
    printed_continuity_verdict: bool = false,
    last_dup_tip_hex: ?[8]u8 = null,
    last_saved_tip_hex: ?[8]u8 = null,
};

fn ctxFromAny(ctx_any: *anyopaque) *FollowerCtx {
    return @as(*FollowerCtx, @ptrCast(@alignCast(ctx_any)));
}

fn onRollForward(
    ctx_any: *anyopaque,
    tip_slot: u64,
    tip_block: u64,
    tip_hash32: [32]u8,
    header_hash32: [32]u8,
    tx_count: u64,
) !void {
    _ = tip_slot;
    _ = tip_block;
    _ = tip_hash32;

    const ctx = ctxFromAny(ctx_any);
    if (ctx.stopping) return;
    const alloc = ctx.alloc;
    const tip = ctx.base.current_tip orelse return;
    const block = ctx.base.current_block orelse return;

    const tip_hash = getTipHash(tip);
    var new_slot: ?u64 = null;
    var new_block_no: ?u64 = null;
    if (getTipSlotBlock(tip)) |tip_info| {
        new_slot = tip_info.slot;
        new_block_no = tip_info.block_no;
    }
    var new_tip_hash_hex = ctx.base.cursor.tip_hash_hex;
    var has_tip_hash = false;
    if (tip_hash) |hash| {
        if (hash.len == 32) {
            _ = try std.fmt.bufPrint(
                &new_tip_hash_hex,
                "{s}",
                .{std.fmt.fmtSliceHexLower(hash)},
            );
            has_tip_hash = true;
        }
    }
    var tip_prefix8: ?[8]u8 = null;
    if (has_tip_hash) {
        var prefix: [8]u8 = [_]u8{'?'} ** 8;
        if (tip_hash) |hash| {
            if (hash.len >= 4) {
                _ = try std.fmt.bufPrint(
                    &prefix,
                    "{s}",
                    .{std.fmt.fmtSliceHexLower(hash[0..4])},
                );
            }
        }
        tip_prefix8 = prefix;
    }
    if (new_slot != null and new_block_no != null and has_tip_hash) {
        if (new_slot.? == ctx.base.cursor.slot and
            new_block_no.? == ctx.base.cursor.block_no and
            std.mem.eql(u8, new_tip_hash_hex[0..], ctx.base.cursor.tip_hash_hex[0..]))
        {
            if (tip_prefix8) |prefix| {
                const should_log = if (ctx.last_dup_tip_hex) |last_dup|
                    !std.mem.eql(u8, last_dup[0..], prefix[0..])
                else
                    true;
                if (should_log and ctx.debug) {
                    std.debug.print(
                        "ROLL FWD (duplicate) slot={d} block={d} tip={s} (no save)\n",
                        .{ new_slot.?, new_block_no.?, prefix[0..] },
                    );
                    ctx.last_dup_tip_hex = prefix;
                }
            }
            return;
        }
    }
    var header_hash_hex: [64]u8 = [_]u8{'0'} ** 64;
    _ = try std.fmt.bufPrint(
        &header_hash_hex,
        "{s}",
        .{std.fmt.fmtSliceHexLower(&header_hash32)},
    );
    ctx.base.cursor.header_hash_hex = header_hash_hex;
    if (new_slot) |slot| ctx.base.cursor.slot = slot;
    if (new_block_no) |block_no| ctx.base.cursor.block_no = block_no;
    if (has_tip_hash) {
        ctx.base.cursor.tip_hash_hex = new_tip_hash_hex;
    }
    if (ctx.debug and !ctx.stopping) {
        printBlockShallow(block);
        printBlockHash(alloc, block, tip_hash);
    }
    if (follower.extractHeaderCborInfo(alloc, block)) |header_info| {
        defer alloc.free(header_info.cbor_bytes);
        if (!ctx.captured_first_rollforward) {
            ctx.captured_first_rollforward = true;
            if (ctx.debug) {
                captureFirstRollForward(
                    alloc,
                    tip,
                    header_info.cbor_bytes,
                    header_info.prev_hash,
                );
                try writeCaptureFile(
                    tip,
                    header_info.cbor_bytes,
                );
            }
        }
        if (ctx.prev_header_hash_opt) |prev_hash| {
            if (header_info.prev_hash) |next_prev_hash| {
                const matches = std.mem.eql(u8, prev_hash[0..], next_prev_hash[0..]);
                vprint(
                    "header_hash == next.prev_hash ({s})\n",
                    .{if (matches) "true" else "false"},
                );
            }
        }
        const curr_body_opt = header_raw.extractHeaderBodyRawSnapshot(
            alloc,
            block,
        );
        if (curr_body_opt) |curr_body| {
            if (ctx.prev_header_body_raw) |prev_body| {
                if (ctx.base.roll_forward_count == 2 and !ctx.printed_continuity_verdict) {
                    if (ctx.debug) {
                        header_raw.printHeaderBodyRawStability(prev_body, curr_body, true);
                        printContinuityVerdict(prev_body, curr_body, true);
                    }
                    ctx.printed_continuity_verdict = true;
                }
            }
            ctx.prev_header_body_raw = curr_body;
            if (ctx.prev_header_hash_opt) |prev_hash| {
                var match_any = false;
                const matches_f3 = std.mem.eql(
                    u8,
                    prev_hash[0..],
                    curr_body.f3_bytes32[0..],
                );
                vprint(
                    "prev_header_hash == curr.f3_bytes32 -> {s}\n",
                    .{if (matches_f3) "true" else "false"},
                );
                if (matches_f3) {
                    vprint("MATCH FIELD: f3\n", .{});
                    match_any = true;
                }

                const matches_f4 = std.mem.eql(
                    u8,
                    prev_hash[0..],
                    curr_body.f4_bytes32[0..],
                );
                vprint(
                    "prev_header_hash == curr.f4_bytes32 -> {s}\n",
                    .{if (matches_f4) "true" else "false"},
                );
                if (matches_f4) {
                    vprint("MATCH FIELD: f4\n", .{});
                    match_any = true;
                }

                const matches_f8 = std.mem.eql(
                    u8,
                    prev_hash[0..],
                    curr_body.f8_bytes32[0..],
                );
                vprint(
                    "prev_header_hash == curr.f8_bytes32 -> {s}\n",
                    .{if (matches_f8) "true" else "false"},
                );
                if (matches_f8) {
                    vprint("MATCH FIELD: f8\n", .{});
                    match_any = true;
                }

                const matches_f9 = std.mem.eql(
                    u8,
                    prev_hash[0..],
                    curr_body.f9_bytes32[0..],
                );
                vprint(
                    "prev_header_hash == curr.f9_bytes32 -> {s}\n",
                    .{if (matches_f9) "true" else "false"},
                );
                if (matches_f9) {
                    vprint("MATCH FIELD: f9\n", .{});
                    match_any = true;
                }

                if (curr_body.f2 == .bytes32) {
                    const matches_f2 = std.mem.eql(
                        u8,
                        prev_hash[0..],
                        curr_body.f2.bytes32[0..],
                    );
                    vprint(
                        "prev_header_hash == curr.f2 -> {s}\n",
                        .{if (matches_f2) "true" else "false"},
                    );
                    if (matches_f2) {
                        vprint("MATCH FIELD: f2\n", .{});
                        match_any = true;
                    }
                }

                vprint(
                    "curr_prev_hash matches prev_header_hash={s}\n",
                    .{if (match_any) "true" else "false"},
                );
            }
        } else if (ctx.prev_header_body_raw != null and ctx.debug) {
            std.debug.print("consensus continuity: BROKEN\n", .{});
        }
        ctx.prev_header_hash_opt = header_hash32;
        ctx.prev_header_cbor_len = header_info.cbor_bytes.len;
    }
    const curr_candidates = try collectHeaderCandidates(
        alloc,
        block,
    );
    if (ctx.prev_header_hash_opt) |prev_hash| {
        for (curr_candidates) |curr_item| {
            if (std.mem.eql(u8, curr_item.bytes, prev_hash[0..])) {
                vprint(
                    "consensus prev-hash field: header[{d}] matches prev_header_hash\n",
                    .{curr_item.index},
                );
            }
        }
    }
    var curr_changed: [15]bool = [_]bool{false} ** 15;
    var curr_present: [15]bool = [_]bool{false} ** 15;
    for (curr_candidates) |curr_item| {
        if (curr_item.index < 15) {
            curr_present[curr_item.index] = true;
            if (ctx.prev_header_values[curr_item.index]) |prev_bytes| {
                curr_changed[curr_item.index] =
                    !std.mem.eql(u8, prev_bytes, curr_item.bytes);
            } else {
                curr_changed[curr_item.index] = true;
            }
        }
    }
    for (curr_candidates) |curr_item| {
        if (curr_item.index < 15) {
            if (ctx.prev_header_values[curr_item.index]) |prev_bytes| {
                alloc.free(prev_bytes);
            }
            ctx.prev_header_values[curr_item.index] = try alloc.dupe(
                u8,
                curr_item.bytes,
            );
        }
    }
    var idx: usize = 0;
    while (idx < ctx.prev_header_values.len) : (idx += 1) {
        if (!curr_present[idx]) {
            if (ctx.prev_header_values[idx]) |prev_bytes| {
                alloc.free(prev_bytes);
            }
            ctx.prev_header_values[idx] = null;
        }
    }
    if (ctx.debug) printHeader32List("curr header32:", curr_candidates);
    if (ctx.prev_candidates) |prev| {
        if (ctx.debug) printHeader32List("prev header32:", prev);
        for (prev) |prev_item| {
            for (curr_candidates) |curr_item| {
                if (!ctx.prev_changed[prev_item.index] or
                    !curr_changed[curr_item.index])
                {
                    continue;
                }
                if (std.mem.eql(u8, prev_item.bytes, curr_item.bytes)) {
                    vprint(
                        "link candidate: prev.header[{d}] -> curr.header[{d}]\n",
                        .{ prev_item.index, curr_item.index },
                    );
                }
                if (std.mem.eql(u8, prev_item.bytes, curr_item.bytes)) {
                    vprint(
                        "match32: prev.header[{d}] == curr.header[{d}]\n",
                        .{ prev_item.index, curr_item.index },
                    );
                    vprint(
                        "prev.header[{d}] == curr.header[{d}] (possible prev-hash link)\n",
                        .{ prev_item.index, curr_item.index },
                    );
                    vprint(
                        "matching indices: prev={d} curr={d}\n",
                        .{ prev_item.index, curr_item.index },
                    );
                }
            }
        }
        freeHeaderCandidates(alloc, prev);
    }
    ctx.prev_candidates = curr_candidates;
    ctx.prev_changed = curr_changed;
    if (ctx.debug) printTip(tip);
    if (ctx.debug and !ctx.stopping) {
        var header_prefix: [8]u8 = [_]u8{'?'} ** 8;
        _ = try std.fmt.bufPrint(
            &header_prefix,
            "{s}",
            .{std.fmt.fmtSliceHexLower(header_hash32[0..4])},
        );
        std.debug.print("header_hash_prefix={s}\n", .{header_prefix[0..]});
    }
    ctx.base.cursor.roll_forward_count += 1;
    ctx.base.cursor.updated_unix = std.time.timestamp();
    try cursor_store.save(ctx.base.cursor, cursor_path);
    if (!ctx.stopping) {
        std.debug.print("CURSOR saved {s}\n", .{cursor_path});
    }
    try journal.appendRollForward(
        journal_path,
        std.time.timestamp(),
        ctx.base.cursor.slot,
        ctx.base.cursor.block_no,
        ctx.base.cursor.tip_hash_hex[0..],
        header_hash_hex[0..],
        tx_count,
        ctx.utxo.count(),
    );
    if (ctx.debug and !ctx.stopping) {
        std.debug.print("JOURNAL append fwd\n", .{});
    }
    const now = std.time.timestamp();
    if (ctx.tps_meter == null) {
        ctx.tps_meter = tps.TpsMeter.init(now);
    }
    ctx.tps_meter.?.addBlock(tx_count, now, ctx.debug);
    if (ctx.debug and !ctx.stopping) {
        std.debug.print("TX_COUNT={d}\n", .{tx_count});
    }
    if (tx_count > 0) {
        var produced = std.ArrayList(utxo_mod.Produced).init(alloc);
        defer produced.deinit();

        var i: u64 = 0;
        while (i < tx_count) : (i += 1) {
            const input = utxo_mod.TxIn{
                .tx_hash = header_hash32,
                .index = @as(u32, @intCast(i)),
            };
            const output = utxo_mod.TxOut{
                .address = "DUMMY",
                .lovelace = 1,
            };
            produced.append(.{ .input = input, .output = output }) catch |err| {
                std.debug.print("UTXO produced append failed: {s}\n", .{@errorName(err)});
                break;
            };
        }

        var undo = ctx.utxo.applyDelta(&[_]utxo_mod.TxIn{}, produced.items) catch |err| {
            std.debug.print("UTXO applyDelta failed: {s}\n", .{@errorName(err)});
            return;
        };
        ctx.undo_stack.append(undo) catch |err| {
            std.debug.print("UTXO undo append failed: {s}\n", .{@errorName(err)});
            undo.deinit();
            return;
        };
        if (ctx.debug and !ctx.stopping) {
            std.debug.print(
                "UTXO count={d} undo_depth={d}\n",
                .{ ctx.utxo.count(), ctx.undo_stack.items.len },
            );
        }
        utxo_store.save(utxo_path, &ctx.utxo) catch {};
    }
    var tip_prefix: [8]u8 = [_]u8{'?'} ** 8;
    if (tip_prefix8) |prefix| {
        tip_prefix = prefix;
    }
    ctx.last_saved_tip_hex = tip_prefix;
    ctx.last_dup_tip_hex = null;
    if (!ctx.stopping) {
        std.debug.print(
            "ROLL FWD slot={d} block={d} tip={s} fwd={d} back={d}\n",
            .{
                ctx.base.cursor.slot,
                ctx.base.cursor.block_no,
                tip_prefix[0..],
                ctx.base.cursor.roll_forward_count,
                ctx.base.cursor.roll_backward_count,
            },
        );
    }
}

fn onRollBackward(
    ctx_any: *anyopaque,
    tip_slot: u64,
    tip_block: u64,
    tip_hash32: [32]u8,
) !void {
    _ = tip_slot;
    _ = tip_block;
    _ = tip_hash32;

    const ctx = ctxFromAny(ctx_any);
    if (ctx.stopping) return;
    const tip = ctx.base.current_tip orelse return;

    if (ctx.debug and !ctx.stopping) {
        if (ctx.base.current_point) |point| {
            printPoint(point);
        }
        printTip(tip);
    }
    ctx.base.cursor.roll_backward_count += 1;
    ctx.base.cursor.updated_unix = std.time.timestamp();
    try cursor_store.save(ctx.base.cursor, cursor_path);
    if (!ctx.stopping) {
        std.debug.print("CURSOR saved {s}\n", .{cursor_path});
    }
    try journal.appendRollBackward(
        journal_path,
        std.time.timestamp(),
        ctx.base.cursor.slot,
        ctx.base.cursor.block_no,
        ctx.base.cursor.tip_hash_hex[0..],
    );
    if (ctx.debug and !ctx.stopping) {
        std.debug.print("JOURNAL append back\n", .{});
    }
    if (ctx.undo_stack.items.len > 0) {
        var undo = ctx.undo_stack.pop();
        ctx.utxo.rollbackDelta(&undo);
        undo.deinit();
    }
    if (ctx.debug and !ctx.stopping) {
        std.debug.print(
            "UTXO rollback count={d} undo_depth={d}\n",
            .{ ctx.utxo.count(), ctx.undo_stack.items.len },
        );
    }
    const tip_hash = getTipHash(tip);
    if (getTipSlotBlock(tip)) |tip_info| {
        ctx.base.cursor.slot = tip_info.slot;
        ctx.base.cursor.block_no = tip_info.block_no;
    }
    var tip_prefix: [8]u8 = [_]u8{'?'} ** 8;
    if (tip_hash) |hash| {
        if (hash.len >= 4) {
            _ = try std.fmt.bufPrint(
                &tip_prefix,
                "{s}",
                .{std.fmt.fmtSliceHexLower(hash[0..4])},
            );
        }
    }
    if (!ctx.stopping) {
        std.debug.print(
            "ROLL BACK slot={d} block={d} tip={s} fwd={d} back={d}\n",
            .{
                ctx.base.cursor.slot,
                ctx.base.cursor.block_no,
                tip_prefix[0..],
                ctx.base.cursor.roll_forward_count,
                ctx.base.cursor.roll_backward_count,
            },
        );
    }
}

fn onStatus(
    ctx_any: *anyopaque,
    slot: u64,
    block: u64,
    fwd: u64,
    back: u64,
    tip_prefix8: [8]u8,
) void {
    const ctx = ctxFromAny(ctx_any);
    if (ctx.stopping) return;
    const now = std.time.timestamp();
    if (now - ctx.last_status_unix < 3) return;
    ctx.last_status_unix = now;
    if (ctx.pretty) {
        pretty.printStatusLine(
            ctx.lang,
            slot,
            block,
            0.0,
            ctx.utxo.count(),
            fwd,
            back,
            tip_prefix8[0..],
        );
        return;
    }
    std.debug.print(
        "STATUS slot={d} block={d} fwd={d} back={d} tip={s}\n",
        .{ slot, block, fwd, back, tip_prefix8[0..] },
    );
}

fn onShutdown(ctx_any: *anyopaque) void {
    const ctx = ctxFromAny(ctx_any);
    ctx.stopping = true;
    std.debug.print(
        "Final cursor: slot={d} block={d} fwd={d} back={d} tip={s}\n",
        .{
            ctx.base.cursor.slot,
            ctx.base.cursor.block_no,
            ctx.base.cursor.roll_forward_count,
            ctx.base.cursor.roll_backward_count,
            ctx.base.cursor.tip_hash_hex[0..8],
        },
    );
}

pub fn runWithOptions(
    alloc: std.mem.Allocator,
    host: []const u8,
    port: u16,
    lang: i18n.Lang,
    debug: bool,
    pretty_status: bool,
) !void {
    g_debug = debug;
    var ctx = FollowerCtx{
        .base = .{
            .cursor = try cursor_store.loadOrInit(alloc, cursor_path),
            .current_tip = null,
            .current_block = null,
            .current_point = null,
            .roll_forward_count = 0,
            .debug_verbose = debug,
        },
        .alloc = alloc,
        .tps_meter = null,
        .utxo = utxo_mod.UTxO.init(alloc),
        .undo_stack = std.ArrayList(utxo_mod.Undo).init(alloc),
        .debug = debug,
        .lang = lang,
        .pretty = pretty_status,
        .prev_candidates = null,
        .prev_header_values = [_]?[]u8{null} ** 15,
        .prev_changed = [_]bool{false} ** 15,
        .captured_first_rollforward = false,
        .prev_header_hash_opt = null,
        .prev_header_cbor_len = null,
        .prev_header_body_raw = null,
        .printed_continuity_verdict = false,
        .last_dup_tip_hex = null,
        .last_saved_tip_hex = null,
    };
    defer {
        if (ctx.prev_candidates) |candidates| freeHeaderCandidates(alloc, candidates);
        freeHeaderValues(alloc, &ctx.prev_header_values);
        for (ctx.undo_stack.items) |*undo| {
            undo.deinit();
        }
        ctx.undo_stack.deinit();
        utxo_store.save(utxo_path, &ctx.utxo) catch {};
        ctx.utxo.deinit();
    }

    try ensureCursorDir();
    {
        var home = try std.fs.openDirAbsolute("/home/midnight", .{});
        defer home.close();
        try home.makePath(".tsunagi");
    }

    const utxo_file = std.fs.openFileAbsolute(utxo_path, .{}) catch null;
    if (utxo_file) |file| {
        file.close();
        ctx.utxo.deinit();
        ctx.utxo = try utxo_store.load(alloc, utxo_path);
        std.debug.print(
            "{s} (count={d})\n",
            .{ i18n.msg(lang, "snapshot_loaded"), ctx.utxo.count() },
        );
    }
    try utxo_store.save(utxo_path, &ctx.utxo);
    std.debug.print(
        "{s}: {s} (count={d})\n",
        .{ i18n.msg(lang, "snapshot_ready"), utxo_path, ctx.utxo.count() },
    );

    vprint(
        "cursor loaded: slot={d} block_no={d} fwd={d} back={d}\n",
        .{
            ctx.base.cursor.slot,
            ctx.base.cursor.block_no,
            ctx.base.cursor.roll_forward_count,
            ctx.base.cursor.roll_backward_count,
        },
    );

    const callbacks = follower.Callbacks{
        .on_roll_forward = onRollForward,
        .on_roll_backward = onRollBackward,
        .on_status = onStatus,
        .on_shutdown = onShutdown,
    };

    try follower.run(alloc, host, port, callbacks, &ctx);
}

pub fn run(alloc: std.mem.Allocator, host: []const u8, port: u16) !void {
    try runWithOptions(alloc, host, port, .en, true, false);
}
