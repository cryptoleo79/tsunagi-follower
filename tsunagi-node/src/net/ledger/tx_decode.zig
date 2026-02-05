const std = @import("std");
const cbor = @import("../cbor/term.zig");
const utxo = @import("utxo.zig");

pub const TxIn = utxo.TxIn;
pub const Produced = utxo.Produced;

pub const TxDeltas = struct {
    consumed: []TxIn,
    produced: []Produced,
};

pub fn freeTxDeltas(alloc: std.mem.Allocator, deltas: TxDeltas) void {
    if (deltas.consumed.len != 0) alloc.free(deltas.consumed);
    if (deltas.produced.len != 0) alloc.free(deltas.produced);
}

/// Era-agnostic, best-effort tx delta extractor.
/// MUST NOT panic. If decoding fails or format is unknown, returns empty deltas.
///
/// Current behavior: detects likely “tx bodies array” but does not yet parse full inputs/outputs.
/// TODO: implement per-era tx body decoding -> fill consumed/produced.
pub fn extractTxDeltas(alloc: std.mem.Allocator, block_body_bytes: []const u8) !TxDeltas {
    var fbs = std.io.fixedBufferStream(block_body_bytes);
    const top = cbor.decode(alloc, fbs.reader()) catch {
        return .{ .consumed = &[_]TxIn{}, .produced = &[_]Produced{} };
    };
    defer cbor.free(top, alloc);

    if (top != .array) {
        return .{ .consumed = &[_]TxIn{}, .produced = &[_]Produced{} };
    }

    // Heuristic: find a top-level item that is an array whose first element is a CBOR map (tx bodies)
    // This matches your existing tx discovery approach.
    for (top.array) |item| {
        if (item != .array) continue;
        const arr = item.array;
        if (arr.len == 0) continue;
        if (arr[0] != .map_u64) continue;

        // We FOUND a plausible tx-bodies container, but we are not decoding it yet.
        // Return empty deltas for now (safe & type-correct).
        return .{ .consumed = &[_]TxIn{}, .produced = &[_]Produced{} };
    }

    return .{ .consumed = &[_]TxIn{}, .produced = &[_]Produced{} };
}
