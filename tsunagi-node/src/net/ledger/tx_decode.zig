const std = @import("std");
const cbor = @import("../cbor/term.zig");
const utxo = @import("utxo.zig");

pub const TxDeltas = struct {
    consumed: []const utxo.TxIn,
    produced: []const utxo.Produced,
    tx_count: u64,
};

pub fn freeTxDeltas(alloc: std.mem.Allocator, deltas: TxDeltas) void {
    for (deltas.produced) |p| {
        alloc.free(p.output.address);
    }
    if (deltas.consumed.len != 0) alloc.free(@constCast(deltas.consumed));
    if (deltas.produced.len != 0) alloc.free(@constCast(deltas.produced));
}

fn emptyDeltas(tx_count: u64) TxDeltas {
    return .{ .consumed = &[_]utxo.TxIn{}, .produced = &[_]utxo.Produced{}, .tx_count = tx_count };
}

fn encodeTermBytes(alloc: std.mem.Allocator, term: cbor.Term) ![]u8 {
    var list = std.ArrayList(u8).init(alloc);
    errdefer list.deinit();
    try cbor.encode(term, list.writer());
    return list.toOwnedSlice();
}

fn findTxBodies(body_items: []cbor.Term) ?[]cbor.Term {
    for (body_items) |item| {
        if (item != .array) continue;
        if (item.array.len == 0) continue;
        if (item.array[0] != .map_u64) continue;
        return item.array;
    }
    return null;
}

fn findMapValue(entries: []cbor.MapEntry, key: u64) ?cbor.Term {
    for (entries) |entry| {
        if (entry.key == key) return entry.value;
    }
    return null;
}

fn termKindName(term: cbor.Term) []const u8 {
    return switch (term) {
        .u64 => "u64",
        .i64 => "i64",
        .bool => "bool",
        .null => "null",
        .bytes => "bytes",
        .text => "text",
        .array => "array",
        .map_u64 => "map",
        .tag => "tag",
    };
}

fn extractBodyBytesIfWrapped(top: cbor.Term) ?[]const u8 {
    if (top != .array) return null;
    if (top.array.len != 2) return null;
    if (top.array[1] != .bytes) return null;
    return top.array[1].bytes;
}

fn extractTxBodiesCountFromTerm(
    alloc: std.mem.Allocator,
    top: cbor.Term,
    debug: bool,
    allow_recurse: bool,
) u64 {
    if (debug) std.debug.print("tx bodies top={s}\n", .{termKindName(top)});
    if (extractBodyBytesIfWrapped(top)) |inner_body_bytes| {
        var inner_fbs = std.io.fixedBufferStream(inner_body_bytes);
        const inner_top = cbor.decode(alloc, inner_fbs.reader()) catch return 0;
        defer cbor.free(inner_top, alloc);
        return extractTxBodiesCountFromTerm(alloc, inner_top, debug, allow_recurse);
    }
    switch (top) {
        .array => |items| {
            for (items) |item| {
                if (item != .array) continue;
                if (item.array.len == 0) continue;
                if (item.array[0] != .map_u64) continue;
                return @intCast(item.array.len);
            }
            return 0;
        },
        .map_u64 => |entries| {
            const value = findMapValue(entries, 0) orelse return 0;
            const tx_count = switch (value) {
                .array => |items| @as(u64, @intCast(items.len)),
                .bytes => |bytes| blk: {
                    if (!allow_recurse) break :blk 0;
                    var fbs = std.io.fixedBufferStream(bytes);
                    const inner = cbor.decode(alloc, fbs.reader()) catch break :blk 0;
                    defer cbor.free(inner, alloc);
                    break :blk extractTxBodiesCountFromTerm(alloc, inner, debug, false);
                },
                .tag => |t| blk: {
                    if (!allow_recurse) break :blk 0;
                    if (t.tag != 24 or t.value.* != .bytes) break :blk 0;
                    const bytes = t.value.*.bytes;
                    var fbs = std.io.fixedBufferStream(bytes);
                    const inner = cbor.decode(alloc, fbs.reader()) catch break :blk 0;
                    defer cbor.free(inner, alloc);
                    break :blk extractTxBodiesCountFromTerm(alloc, inner, debug, false);
                },
                else => 0,
            };
            if (debug) std.debug.print("tx bodies key0={s} count={d}\n", .{ termKindName(value), tx_count });
            return tx_count;
        },
        else => return 0,
    }
}

pub fn extractTxBodiesCount(alloc: std.mem.Allocator, body_bytes: []const u8, debug: bool) u64 {
    if (debug and body_bytes.len > 0) {
        const first = body_bytes[0];
        const major: u8 = first >> 5;
        const ai: u8 = first & 0x1f;
        std.debug.print(
            "TX_BODY first_byte=0x{x} major={d} ai={d} len={d}\n",
            .{ first, major, ai, body_bytes.len },
        );
    }
    var fbs = std.io.fixedBufferStream(body_bytes);
    const top = cbor.decode(alloc, fbs.reader()) catch return 0;
    defer cbor.free(top, alloc);
    if (debug) std.debug.print("TX_BODY top_kind={s}\n", .{termKindName(top)});
    if (debug and top == .map_u64) {
        var printed: usize = 0;
        std.debug.print("TX_BODY keys=", .{});
        for (top.map_u64) |entry| {
            if (printed >= 12) break;
            if (printed > 0) std.debug.print(",", .{});
            std.debug.print("{d}", .{entry.key});
            printed += 1;
        }
        std.debug.print("\n", .{});
        if (findMapValue(top.map_u64, 0)) |value| {
            std.debug.print("TX_BODY key0_kind={s}\n", .{termKindName(value)});
        }
    }
    return extractTxBodiesCountFromTerm(alloc, top, debug, true);
}

fn freeProducedList(alloc: std.mem.Allocator, list: *std.ArrayList(utxo.Produced)) void {
    for (list.items) |p| {
        alloc.free(p.output.address);
    }
    list.deinit();
}

fn unwrapTag24Bytes(term: cbor.Term) ?[]const u8 {
    if (term != .tag) return null;
    if (term.tag.tag != 24) return null;
    if (term.tag.value.* != .bytes) return null;
    return term.tag.value.*.bytes;
}

fn decodeTxBodyFromTerm(alloc: std.mem.Allocator, tx_term: cbor.Term) ?cbor.Term {
    return switch (tx_term) {
        .map_u64 => tx_term,
        .array => |items| blk: {
            if (items.len == 0) break :blk null;
            if (items[0] != .map_u64) break :blk null;
            break :blk items[0];
        },
        .bytes => |bytes| blk: {
            var fbs = std.io.fixedBufferStream(bytes);
            const decoded = cbor.decode(alloc, fbs.reader()) catch break :blk null;
            break :blk decoded;
        },
        .tag => blk: {
            const bytes = unwrapTag24Bytes(tx_term) orelse break :blk null;
            var fbs = std.io.fixedBufferStream(bytes);
            const decoded = cbor.decode(alloc, fbs.reader()) catch break :blk null;
            break :blk decoded;
        },
        else => null,
    };
}

fn decodeTxDelta(
    alloc: std.mem.Allocator,
    tx_term: cbor.Term,
    consumed: *std.ArrayList(utxo.TxIn),
    produced: *std.ArrayList(utxo.Produced),
) !void {
    var decoded_tx: ?cbor.Term = null;
    const tx_body_term = blk: {
        const body = decodeTxBodyFromTerm(alloc, tx_term) orelse return error.InvalidType;
        if (body != .map_u64 and body != .array) {
            if (tx_term == .bytes or tx_term == .tag) {
                cbor.free(body, alloc);
            }
            return error.InvalidType;
        }
        if (tx_term == .bytes or tx_term == .tag) {
            decoded_tx = body;
        }
        if (body == .map_u64) break :blk body;
        if (body == .array and body.array.len > 0 and body.array[0] == .map_u64) {
            break :blk body.array[0];
        }
        if (decoded_tx) |t| cbor.free(t, alloc);
        return error.InvalidType;
    };
    defer if (decoded_tx) |t| cbor.free(t, alloc);

    const inputs_term = findMapValue(tx_body_term.map_u64, 0) orelse return error.InvalidType;
    const outputs_term = findMapValue(tx_body_term.map_u64, 1) orelse return error.InvalidType;
    if (inputs_term != .array or outputs_term != .array) return error.InvalidType;

    const tx_body_bytes = try encodeTermBytes(alloc, tx_body_term);
    defer alloc.free(tx_body_bytes);

    var tx_hash: [32]u8 = undefined;
    std.crypto.hash.blake2.Blake2b256.hash(tx_body_bytes, &tx_hash, .{});

    var local_consumed = std.ArrayList(utxo.TxIn).init(alloc);
    errdefer local_consumed.deinit();
    var local_produced = std.ArrayList(utxo.Produced).init(alloc);
    errdefer freeProducedList(alloc, &local_produced);

    for (inputs_term.array) |input_term| {
        if (input_term != .array or input_term.array.len < 2) return error.InvalidType;
        const hash_term = input_term.array[0];
        const index_term = input_term.array[1];
        if (hash_term != .bytes or hash_term.bytes.len != 32) return error.InvalidType;
        if (index_term != .u64) return error.InvalidType;
        if (index_term.u64 > std.math.maxInt(u32)) return error.InvalidType;
        var hash32: [32]u8 = undefined;
        std.mem.copyForwards(u8, hash32[0..], hash_term.bytes);
        try local_consumed.append(.{ .tx_hash = hash32, .index = @intCast(index_term.u64) });
    }

    var out_index: u32 = 0;
    for (outputs_term.array) |output| {
        if (output != .array or output.array.len < 2) return error.InvalidType;
        const addr_bytes = try encodeTermBytes(alloc, output.array[0]);
        const lovelace = if (output.array[1] == .u64) output.array[1].u64 else 0;
        try local_produced.append(.{
            .input = .{ .tx_hash = tx_hash, .index = out_index },
            .output = .{ .address = addr_bytes, .lovelace = lovelace },
        });
        out_index += 1;
    }

    if (local_consumed.items.len == 0 and local_produced.items.len == 0) {
        local_consumed.deinit();
        local_produced.deinit();
        return;
    }

    try consumed.appendSlice(local_consumed.items);
    local_consumed.deinit();
    try produced.appendSlice(local_produced.items);
    local_produced.items.len = 0;
    local_produced.deinit();
}

pub fn extractTxDeltas(
    alloc: std.mem.Allocator,
    tx_list: []cbor.Term,
    debug: bool,
) !TxDeltas {
    _ = debug;
    return extractTxDeltasFromTxList(alloc, tx_list);
}

fn extractTxDeltasFromTxList(alloc: std.mem.Allocator, tx_list: []cbor.Term) TxDeltas {
    if (tx_list.len == 0) return emptyDeltas(0);

    var consumed = std.ArrayList(utxo.TxIn).init(alloc);
    errdefer consumed.deinit();
    var produced = std.ArrayList(utxo.Produced).init(alloc);
    errdefer freeProducedList(alloc, &produced);

    var tx_count: u64 = 0;
    for (tx_list) |tx_term| {
        tx_count += 1;
        _ = decodeTxDelta(alloc, tx_term, &consumed, &produced) catch continue;
    }

    const consumed_slice = consumed.toOwnedSlice() catch {
        consumed.deinit();
        freeProducedList(alloc, &produced);
        return emptyDeltas(tx_count);
    };
    const produced_slice = produced.toOwnedSlice() catch {
        alloc.free(consumed_slice);
        freeProducedList(alloc, &produced);
        return emptyDeltas(tx_count);
    };
    return .{ .consumed = consumed_slice, .produced = produced_slice, .tx_count = tx_count };
}

test "tx decode tx bodies array yields tx_count" {
    const alloc = std.testing.allocator;

    const input_hash = [_]u8{1} ** 32;
    var input_items = [_]cbor.Term{
        .{ .bytes = input_hash[0..] },
        .{ .u64 = 0 },
    };
    var inputs = [_]cbor.Term{.{ .array = input_items[0..] }};

    var output_items = [_]cbor.Term{
        .{ .bytes = "addr" },
        .{ .u64 = 42 },
    };
    var outputs = [_]cbor.Term{.{ .array = output_items[0..] }};

    var map_entries = [_]cbor.MapEntry{
        .{ .key = 0, .value = .{ .array = inputs[0..] } },
        .{ .key = 1, .value = .{ .array = outputs[0..] } },
    };
    const tx_body = cbor.Term{ .map_u64 = map_entries[0..] };
    var tx_list = [_]cbor.Term{tx_body};
    const deltas = try extractTxDeltas(alloc, tx_list[0..], false);
    defer freeTxDeltas(alloc, deltas);
    try std.testing.expect(deltas.tx_count > 0);
}
