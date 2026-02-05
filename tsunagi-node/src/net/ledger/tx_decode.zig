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

fn freeProducedList(alloc: std.mem.Allocator, list: *std.ArrayList(utxo.Produced)) void {
    for (list.items) |p| {
        alloc.free(p.output.address);
    }
    list.deinit();
}

fn decodeTxDelta(
    alloc: std.mem.Allocator,
    tx_term: cbor.Term,
    consumed: *std.ArrayList(utxo.TxIn),
    produced: *std.ArrayList(utxo.Produced),
) !void {
    if (tx_term != .map_u64) return error.InvalidType;

    const inputs_term = findMapValue(tx_term.map_u64, 0) orelse return error.InvalidType;
    const outputs_term = findMapValue(tx_term.map_u64, 1) orelse return error.InvalidType;
    if (inputs_term != .array or outputs_term != .array) return error.InvalidType;

    const tx_body_bytes = try encodeTermBytes(alloc, tx_term);
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
    block_inner_bytes: []const u8,
    debug: bool,
) !TxDeltas {
    _ = debug;
    var fbs = std.io.fixedBufferStream(block_inner_bytes);
    const top = cbor.decode(alloc, fbs.reader()) catch {
        return emptyDeltas(0);
    };
    defer cbor.free(top, alloc);

    if (top != .array or top.array.len < 2) {
        return emptyDeltas(0);
    }

    const body_bytes = switch (top.array[1]) {
        .bytes => |b| b,
        else => return emptyDeltas(0),
    };

    var body_fbs = std.io.fixedBufferStream(body_bytes);
    const body = cbor.decode(alloc, body_fbs.reader()) catch {
        return emptyDeltas(0);
    };
    defer cbor.free(body, alloc);

    if (body != .array) {
        return emptyDeltas(0);
    }

    const tx_bodies = findTxBodies(body.array) orelse return emptyDeltas(0);

    var consumed = std.ArrayList(utxo.TxIn).init(alloc);
    errdefer consumed.deinit();
    var produced = std.ArrayList(utxo.Produced).init(alloc);
    errdefer freeProducedList(alloc, &produced);

    var tx_count: u64 = 0;
    for (tx_bodies) |tx_term| {
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
    var tx_bodies = [_]cbor.Term{tx_body};
    const body = cbor.Term{ .array = &[_]cbor.Term{.{ .array = tx_bodies[0..] }} };

    var body_bytes = std.ArrayList(u8).init(alloc);
    defer body_bytes.deinit();
    try cbor.encode(body, body_bytes.writer());
    const body_slice = try body_bytes.toOwnedSlice();
    defer alloc.free(body_slice);

    const top = cbor.Term{ .array = &[_]cbor.Term{ .{ .u64 = 0 }, .{ .bytes = body_slice } } };
    var top_bytes = std.ArrayList(u8).init(alloc);
    defer top_bytes.deinit();
    try cbor.encode(top, top_bytes.writer());
    const top_slice = try top_bytes.toOwnedSlice();
    defer alloc.free(top_slice);

    const deltas = try extractTxDeltas(alloc, top_slice, false);
    defer freeTxDeltas(alloc, deltas);
    try std.testing.expect(deltas.tx_count > 0);
}
