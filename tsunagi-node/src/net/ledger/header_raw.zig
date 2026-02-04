const std = @import("std");

const cbor = @import("../cbor/term.zig");

pub const HeaderBodyRaw = struct {
    pub const F2 = union(enum) { null, bytes32: [32]u8 };

    f0_u64: u64,
    f1_u64: u64,
    f2: F2,
    f3_bytes32: [32]u8,
    f4_bytes32: [32]u8,
    f5: cbor.Term,
    f6: cbor.Term,
    f7_u64: u64,
    f8_bytes32: [32]u8,
    f9_bytes32: [32]u8,
    f10_u64: u64,
    f11_u64: u64,
    f12_bytes64: [64]u8,
    f13_u64: u64,
    f14_u64: u64,
};

pub const HeaderBodyRawSnapshot = struct {
    f0_u64: u64,
    f1_u64: u64,
    f2: HeaderBodyRaw.F2,
    f3_bytes32: [32]u8,
    f4_bytes32: [32]u8,
    f7_u64: u64,
    f8_bytes32: [32]u8,
    f9_bytes32: [32]u8,
    f10_u64: u64,
    f11_u64: u64,
    f12_bytes64: [64]u8,
    f13_u64: u64,
    f14_u64: u64,
};

pub fn decodeHeaderBodyRaw(term: cbor.Term) ?HeaderBodyRaw {
    if (term != .array) return null;
    const items = term.array;
    if (items.len != 15) return null;

    if (items[0] != .u64) return null;
    if (items[1] != .u64) return null;

    var f2: HeaderBodyRaw.F2 = undefined;
    if (items[2] == .null) {
        f2 = .null;
    } else if (items[2] == .bytes and items[2].bytes.len == 32) {
        var bytes32: [32]u8 = undefined;
        std.mem.copyForwards(u8, bytes32[0..], items[2].bytes);
        f2 = .{ .bytes32 = bytes32 };
    } else {
        return null;
    }

    if (items[3] != .bytes or items[3].bytes.len != 32) return null;
    if (items[4] != .bytes or items[4].bytes.len != 32) return null;
    if (items[5] != .array or items[5].array.len != 2) return null;
    if (items[6] != .array or items[6].array.len != 2) return null;
    if (items[7] != .u64) return null;
    if (items[8] != .bytes or items[8].bytes.len != 32) return null;
    if (items[9] != .bytes or items[9].bytes.len != 32) return null;
    if (items[10] != .u64) return null;
    if (items[11] != .u64) return null;
    if (items[12] != .bytes or items[12].bytes.len != 64) return null;
    if (items[13] != .u64) return null;
    if (items[14] != .u64) return null;

    var f3_bytes32: [32]u8 = undefined;
    var f4_bytes32: [32]u8 = undefined;
    var f8_bytes32: [32]u8 = undefined;
    var f9_bytes32: [32]u8 = undefined;
    var f12_bytes64: [64]u8 = undefined;
    std.mem.copyForwards(u8, f3_bytes32[0..], items[3].bytes);
    std.mem.copyForwards(u8, f4_bytes32[0..], items[4].bytes);
    std.mem.copyForwards(u8, f8_bytes32[0..], items[8].bytes);
    std.mem.copyForwards(u8, f9_bytes32[0..], items[9].bytes);
    std.mem.copyForwards(u8, f12_bytes64[0..], items[12].bytes);

    return HeaderBodyRaw{
        .f0_u64 = items[0].u64,
        .f1_u64 = items[1].u64,
        .f2 = f2,
        .f3_bytes32 = f3_bytes32,
        .f4_bytes32 = f4_bytes32,
        .f5 = items[5],
        .f6 = items[6],
        .f7_u64 = items[7].u64,
        .f8_bytes32 = f8_bytes32,
        .f9_bytes32 = f9_bytes32,
        .f10_u64 = items[10].u64,
        .f11_u64 = items[11].u64,
        .f12_bytes64 = f12_bytes64,
        .f13_u64 = items[13].u64,
        .f14_u64 = items[14].u64,
    };
}

pub fn printHeaderBodyRaw(body: HeaderBodyRaw) void {
    std.debug.print("HeaderBodyRaw:\n", .{});
    std.debug.print("  f0_u64={d}\n", .{body.f0_u64});
    std.debug.print("  f1_u64={d}\n", .{body.f1_u64});
    switch (body.f2) {
        .null => std.debug.print("  f2=null\n", .{}),
        .bytes32 => |bytes| std.debug.print(
            "  f2=bytes32 {s}\n",
            .{std.fmt.fmtSliceHexLower(bytes[0..8])},
        ),
    }
    std.debug.print("  f3_bytes32={s}\n", .{std.fmt.fmtSliceHexLower(body.f3_bytes32[0..8])});
    std.debug.print("  f4_bytes32={s}\n", .{std.fmt.fmtSliceHexLower(body.f4_bytes32[0..8])});
    std.debug.print("  f5=array len=2 (opaque)\n", .{});
    std.debug.print("  f6=array len=2 (opaque)\n", .{});
    std.debug.print("  f7_u64={d}\n", .{body.f7_u64});
    std.debug.print("  f8_bytes32={s}\n", .{std.fmt.fmtSliceHexLower(body.f8_bytes32[0..8])});
    std.debug.print("  f9_bytes32={s}\n", .{std.fmt.fmtSliceHexLower(body.f9_bytes32[0..8])});
    std.debug.print("  f10_u64={d}\n", .{body.f10_u64});
    std.debug.print("  f11_u64={d}\n", .{body.f11_u64});
    std.debug.print("  f12_bytes64={s}\n", .{std.fmt.fmtSliceHexLower(body.f12_bytes64[0..8])});
    std.debug.print("  f13_u64={d}\n", .{body.f13_u64});
    std.debug.print("  f14_u64={d}\n", .{body.f14_u64});
}

pub fn printHeaderBodyRawStability(
    prev: HeaderBodyRawSnapshot,
    curr: HeaderBodyRawSnapshot,
    structure_ok: bool,
) void {
    if (prev.f0_u64 != curr.f0_u64) {
        const delta: i64 = @as(i64, @intCast(curr.f0_u64)) - @as(i64, @intCast(prev.f0_u64));
        std.debug.print("u64 f0: prev={d} curr={d} delta={d}\n", .{ prev.f0_u64, curr.f0_u64, delta });
    }
    if (prev.f1_u64 != curr.f1_u64) {
        const delta: i64 = @as(i64, @intCast(curr.f1_u64)) - @as(i64, @intCast(prev.f1_u64));
        std.debug.print("u64 f1: prev={d} curr={d} delta={d}\n", .{ prev.f1_u64, curr.f1_u64, delta });
    }
    if (prev.f7_u64 != curr.f7_u64) {
        const delta: i64 = @as(i64, @intCast(curr.f7_u64)) - @as(i64, @intCast(prev.f7_u64));
        std.debug.print("u64 f7: prev={d} curr={d} delta={d}\n", .{ prev.f7_u64, curr.f7_u64, delta });
    }
    if (prev.f10_u64 != curr.f10_u64) {
        const delta: i64 = @as(i64, @intCast(curr.f10_u64)) - @as(i64, @intCast(prev.f10_u64));
        std.debug.print("u64 f10: prev={d} curr={d} delta={d}\n", .{ prev.f10_u64, curr.f10_u64, delta });
    }
    if (prev.f11_u64 != curr.f11_u64) {
        const delta: i64 = @as(i64, @intCast(curr.f11_u64)) - @as(i64, @intCast(prev.f11_u64));
        std.debug.print("u64 f11: prev={d} curr={d} delta={d}\n", .{ prev.f11_u64, curr.f11_u64, delta });
    }
    if (prev.f13_u64 != curr.f13_u64) {
        const delta: i64 = @as(i64, @intCast(curr.f13_u64)) - @as(i64, @intCast(prev.f13_u64));
        std.debug.print("u64 f13: prev={d} curr={d} delta={d}\n", .{ prev.f13_u64, curr.f13_u64, delta });
    }
    if (prev.f14_u64 != curr.f14_u64) {
        const delta: i64 = @as(i64, @intCast(curr.f14_u64)) - @as(i64, @intCast(prev.f14_u64));
        std.debug.print("u64 f14: prev={d} curr={d} delta={d}\n", .{ prev.f14_u64, curr.f14_u64, delta });
    }

    const f3_changed = !std.mem.eql(u8, prev.f3_bytes32[0..], curr.f3_bytes32[0..]);
    std.debug.print(
        "bytes32 f3 changed={s} prefix={s}\n",
        .{ if (f3_changed) "true" else "false", std.fmt.fmtSliceHexLower(curr.f3_bytes32[0..8]) },
    );
    const f4_changed = !std.mem.eql(u8, prev.f4_bytes32[0..], curr.f4_bytes32[0..]);
    std.debug.print(
        "bytes32 f4 changed={s} prefix={s}\n",
        .{ if (f4_changed) "true" else "false", std.fmt.fmtSliceHexLower(curr.f4_bytes32[0..8]) },
    );
    const f8_changed = !std.mem.eql(u8, prev.f8_bytes32[0..], curr.f8_bytes32[0..]);
    std.debug.print(
        "bytes32 f8 changed={s} prefix={s}\n",
        .{ if (f8_changed) "true" else "false", std.fmt.fmtSliceHexLower(curr.f8_bytes32[0..8]) },
    );
    const f9_changed = !std.mem.eql(u8, prev.f9_bytes32[0..], curr.f9_bytes32[0..]);
    std.debug.print(
        "bytes32 f9 changed={s} prefix={s}\n",
        .{ if (f9_changed) "true" else "false", std.fmt.fmtSliceHexLower(curr.f9_bytes32[0..8]) },
    );

    switch (curr.f2) {
        .null => std.debug.print("f2 kind: null\n", .{}),
        .bytes32 => std.debug.print("f2 kind: bytes32\n", .{}),
    }

    std.debug.print(
        "stability: f8_bytes32 constant={s}\n",
        .{if (f8_changed) "false" else "true"},
    );

    const slot_delta: i64 = @as(i64, @intCast(curr.f0_u64)) - @as(i64, @intCast(prev.f0_u64));
    const protocol_stable = prev.f7_u64 == curr.f7_u64;
    const body_hash_changed = !std.mem.eql(u8, prev.f12_bytes64[0..], curr.f12_bytes64[0..]);
    if (prev.f2 == .bytes32 and curr.f2 == .bytes32) {
        const stable = std.mem.eql(u8, prev.f2.bytes32[0..], curr.f2.bytes32[0..]);
        std.debug.print(
            "bytes32 {s}: header[2]\n",
            .{if (stable) "stable" else "changed"},
        );
    }
    {
        const stable = std.mem.eql(u8, prev.f3_bytes32[0..], curr.f3_bytes32[0..]);
        std.debug.print(
            "bytes32 {s}: header[3]\n",
            .{if (stable) "stable" else "changed"},
        );
    }
    {
        const stable = std.mem.eql(u8, prev.f4_bytes32[0..], curr.f4_bytes32[0..]);
        std.debug.print(
            "bytes32 {s}: header[4]\n",
            .{if (stable) "stable" else "changed"},
        );
    }
    {
        const stable = std.mem.eql(u8, prev.f8_bytes32[0..], curr.f8_bytes32[0..]);
        std.debug.print(
            "bytes32 {s}: header[8]\n",
            .{if (stable) "stable" else "changed"},
        );
    }
    {
        const stable = std.mem.eql(u8, prev.f9_bytes32[0..], curr.f9_bytes32[0..]);
        std.debug.print(
            "bytes32 {s}: header[9]\n",
            .{if (stable) "stable" else "changed"},
        );
    }

    std.debug.print("consensus slot delta={d}\n", .{slot_delta});
    std.debug.print("consensus protocol version stable={s}\n", .{if (protocol_stable) "true" else "false"});
    std.debug.print("consensus body hash changed={s}\n", .{if (body_hash_changed) "true" else "false"});
    const leader_changed = !std.mem.eql(u8, prev.f3_bytes32[0..], curr.f3_bytes32[0..]) or
        !std.mem.eql(u8, prev.f4_bytes32[0..], curr.f4_bytes32[0..]);
    std.debug.print("leader changed={s}\n", .{if (leader_changed) "true" else "false"});
    const ok = structure_ok and slot_delta >= 1 and protocol_stable;
    std.debug.print("consensus continuity: {s}\n", .{if (ok) "OK" else "BROKEN"});
}

pub fn headerBodyRawSnapshot(body: HeaderBodyRaw) HeaderBodyRawSnapshot {
    return HeaderBodyRawSnapshot{
        .f0_u64 = body.f0_u64,
        .f1_u64 = body.f1_u64,
        .f2 = body.f2,
        .f3_bytes32 = body.f3_bytes32,
        .f4_bytes32 = body.f4_bytes32,
        .f7_u64 = body.f7_u64,
        .f8_bytes32 = body.f8_bytes32,
        .f9_bytes32 = body.f9_bytes32,
        .f10_u64 = body.f10_u64,
        .f11_u64 = body.f11_u64,
        .f12_bytes64 = body.f12_bytes64,
        .f13_u64 = body.f13_u64,
        .f14_u64 = body.f14_u64,
    };
}

pub fn extractHeaderBodyRawSnapshot(alloc: std.mem.Allocator, block: cbor.Term) ?HeaderBodyRawSnapshot {
    if (block != .array) return null;
    const items = block.array;
    if (items.len < 2) return null;

    const block_bytes = blk: {
        if (items[1] == .bytes) break :blk items[1].bytes;
        if (items[1] == .tag and items[1].tag.tag == 24 and items[1].tag.value.* == .bytes) {
            break :blk items[1].tag.value.*.bytes;
        }
        return null;
    };

    const inner_bytes = getTag24InnerBytes(block_bytes) orelse block_bytes;
    var fbs = std.io.fixedBufferStream(inner_bytes);
    const top = cbor.decode(alloc, fbs.reader()) catch return null;
    defer cbor.free(top, alloc);

    if (top != .array) return null;
    const top_items = top.array;
    if (top_items.len == 0 or top_items[0] != .array) return null;
    if (decodeHeaderBodyRaw(top_items[0])) |body| {
        return headerBodyRawSnapshot(body);
    }
    return null;
}

pub fn getTag24InnerBytes(bytes: []const u8) ?[]const u8 {
    if (bytes.len == 0) return null;
    if ((bytes[0] >> 5) != 6) return null;

    var index: usize = 1;
    const ai: u8 = bytes[0] & 0x1f;
    var tag: u32 = 0;
    switch (ai) {
        0...23 => tag = ai,
        24 => {
            if (index + 1 > bytes.len) return null;
            tag = bytes[index];
            index += 1;
        },
        25 => {
            if (index + 2 > bytes.len) return null;
            tag = (@as(u32, bytes[index]) << 8) | bytes[index + 1];
            index += 2;
        },
        26 => {
            if (index + 4 > bytes.len) return null;
            tag = (@as(u32, bytes[index]) << 24) |
                (@as(u32, bytes[index + 1]) << 16) |
                (@as(u32, bytes[index + 2]) << 8) |
                bytes[index + 3];
            index += 4;
        },
        else => return null,
    }
    if (tag != 24) return null;
    if (index >= bytes.len) return null;

    const item_head = bytes[index];
    if ((item_head >> 5) != 2) return null;
    index += 1;

    const item_ai: u8 = item_head & 0x1f;
    var len: usize = 0;
    switch (item_ai) {
        0...23 => len = item_ai,
        24 => {
            if (index + 1 > bytes.len) return null;
            len = bytes[index];
            index += 1;
        },
        25 => {
            if (index + 2 > bytes.len) return null;
            len = (@as(usize, bytes[index]) << 8) | bytes[index + 1];
            index += 2;
        },
        26 => {
            if (index + 4 > bytes.len) return null;
            len = (@as(usize, bytes[index]) << 24) |
                (@as(usize, bytes[index + 1]) << 16) |
                (@as(usize, bytes[index + 2]) << 8) |
                bytes[index + 3];
            index += 4;
        },
        else => return null,
    }
    if (index + len > bytes.len) return null;
    return bytes[index .. index + len];
}
