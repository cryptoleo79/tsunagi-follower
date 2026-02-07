const std = @import("std");
const cbor = @import("../cbor/term.zig");
const cbor_term = @import("../cbor/term.zig");
const utxo = @import("utxo.zig");

pub const TxDeltas = struct {
    consumed: []const utxo.TxIn,
    produced: []const utxo.Produced,
    tx_count: u64,
};

pub const TxBodyScan = struct {
    tx_list: []cbor.Term,
    owner: cbor.Term,
};

pub fn freeTxDeltas(alloc: std.mem.Allocator, d: TxDeltas) void {
    // elements are value types, slices were allocated
    alloc.free(@constCast(d.consumed));
    alloc.free(@constCast(d.produced));
}

fn isTag24Bytes(t: cbor.Term) bool {
    return t == .tag and t.tag.tag == 24 and t.tag.value.* == .bytes;
}

fn termKindName(t: cbor.Term) []const u8 {
    return switch (t) {
        .u64 => "u64",
        .i64 => "i64",
        .bool => "bool",
        .null => "null",
        .bytes => "bytes",
        .text => "text",
        .array => "array",
        .map_u64 => "map_u64",
        .tag => "tag",
    };
}

fn decodeCborFromBytes(alloc: std.mem.Allocator, bytes: []const u8) anyerror!cbor.Term {
    if (bytes.len == 0) return error.EndOfStream;
    var fbs = std.io.fixedBufferStream(bytes);
    const reader = fbs.reader();
    const first_byte = bytes[0];
    const tx_term = cbor.decode(alloc, reader) catch |err| {
        if (err == error.UnsupportedCborType) {
            // Fallback: preserve raw CBOR bytes (indefinite arrays / maps)
            const raw = try cbor_term.decodeUnsupportedAsBytes(
                alloc,
                reader,
                first_byte,
            );
            return cbor.Term{ .bytes = raw };
        }
        return err;
    };
    return tx_term;
}

/// Turn one tx-body item (bytes/tag24/map) into a tx-body map_u64 term.
/// Returned term must be freed by caller with cbor.free().
fn decodeTxBodyItemToMap(alloc: std.mem.Allocator, item: cbor.Term) ?cbor.Term {
    if (item == .map_u64) return item; // note: borrowed, caller must NOT free

    if (item == .bytes) {
        const t = decodeCborFromBytes(alloc, item.bytes) catch return null;
        if (t != .map_u64) {
            cbor.free(t, alloc);
            return null;
        }
        return t;
    }

    if (isTag24Bytes(item)) {
        const inner = item.tag.value.*.bytes;
        const t = decodeCborFromBytes(alloc, inner) catch return null;
        if (t != .map_u64) {
            cbor.free(t, alloc);
            return null;
        }
        return t;
    }

    return null;
}

fn findMapValue(entries: []const cbor.MapEntry, key: u64) ?cbor.Term {
    for (entries) |e| {
        if (e.key == key) return e.value;
    }
    return null;
}

fn decodeTxBodyTermWithFallback(
    alloc: std.mem.Allocator,
    body_bytes: []const u8,
) !cbor.Term {
    var fbs = std.io.fixedBufferStream(body_bytes);
    const r = fbs.reader();
    // Peek first byte (CBOR major type)
    var first_byte: u8 = undefined;
    try r.readNoEof(std.mem.asBytes(&first_byte));

    // Rewind reader
    var fbs2 = std.io.fixedBufferStream(body_bytes);
    const r2 = fbs2.reader(); // Try normal decode first
    var term = cbor.decode(alloc, r2) catch |err| switch (err) {
        error.UnsupportedCborType => blk: {
            // Fallback: decode entire CBOR object as raw bytes
            var fbs3 = std.io.fixedBufferStream(body_bytes[1..]);
            const r3 = fbs3.reader();
            const raw = try cbor_term.decodeUnsupportedAsBytes(
                alloc,
                r3,
                first_byte,
            );
            defer alloc.free(raw);

            var fbs4 = std.io.fixedBufferStream(raw);
            const r4 = fbs4.reader();
            break :blk try cbor.decode(alloc, r4);
        },
        else => return err,
    };

    defer cbor.free(term, alloc);
    const out = term;
    term = cbor.Term{ .null = {} };
    return out;
}

pub fn scanTxBodiesFromBodyBytes(
    alloc: std.mem.Allocator,
    block_body_bytes: []const u8,
    debug: bool,
) ?TxBodyScan {
    const term = decodeTxBodyTermWithFallback(alloc, block_body_bytes) catch |err| {
        if (err == error.EndOfStream) return null;
        if (debug) std.debug.print("TX_SEQ: decode err={any}\n", .{err});
        return null;
    };

    if (debug) std.debug.print("TX_SEQ: item_kind={s}\n", .{termKindName(term)});

    if (term == .array and term.array.len > 0 and term.array[0] == .array) {
        const txs = term.array[0].array;
        if (txs.len > 0 and txs[0] == .map_u64) {
            if (debug) std.debug.print("TX_SEQ: FOUND (case A) txs={d}\n", .{txs.len});
            return .{ .tx_list = txs, .owner = term };
        }
    }

    if (term == .map_u64) {
        for (term.map_u64) |e| {
            if (e.key == 0 and e.value == .array) {
                const txs = e.value.array;
                if (txs.len > 0 and txs[0] == .map_u64) {
                    if (debug) std.debug.print("TX_SEQ: FOUND (case B) txs={d}\n", .{txs.len});
                    return .{ .tx_list = txs, .owner = term };
                }
            }
        }
    }

    cbor.free(term, alloc);
    return null;
}

/// Compute a temporary tx hash from a tx-body map by CBOR-encoding it and blake2b256.
/// (This is *not* the canonical txid yet; good enough for UTxO scaffolding.)
fn hashTxBodyMap(alloc: std.mem.Allocator, tx_map: []const cbor.MapEntry) ?[32]u8 {
    var list = std.ArrayList(u8).init(alloc);
    defer list.deinit();
    cbor.encode(cbor.Term{ .map_u64 = @constCast(tx_map) }, list.writer()) catch return null;

    var out: [32]u8 = undefined;
    std.crypto.hash.blake2.Blake2b256.hash(list.items, &out, .{});
    return out;
}

fn parseInputs(alloc: std.mem.Allocator, tx_hash: [32]u8, tx_term: cbor.Term) ?[]utxo.TxIn {
    if (tx_term != .map_u64) return null;

    // Cardano tx-body key 0 = inputs (array)
    const inputs_term = findMapValue(tx_term.map_u64, 0) orelse return null;
    if (inputs_term != .array) return null;

    // We don't have real txid yet for referenced inputs inside the tx,
    // so we just store (tx_hash, index) placeholder when we can parse index.
    // Many formats are [ txid, ix ] but txid itself is bytes32.
    var out = std.ArrayList(utxo.TxIn).init(alloc);
    errdefer out.deinit();

    for (inputs_term.array) |inp| {
        if (inp != .array or inp.array.len < 2) continue;

        const ix_term = inp.array[1];
        if (ix_term != .u64) continue;

        out.append(.{ .tx_hash = tx_hash, .index = @intCast(ix_term.u64) }) catch return null;
    }

    return out.toOwnedSlice() catch null;
}

fn parseOutputs(alloc: std.mem.Allocator, tx_hash: [32]u8, tx_term: cbor.Term) ?[]utxo.Produced {
    if (tx_term != .map_u64) return null;

    // Cardano tx-body key 1 = outputs (array)
    const outputs_term = findMapValue(tx_term.map_u64, 1) orelse return null;
    if (outputs_term != .array) return null;

    var out = std.ArrayList(utxo.Produced).init(alloc);
    errdefer out.deinit();

    var out_index: u32 = 0;
    for (outputs_term.array) |o| {
        // output shape varies by era; we only need a placeholder TxOut for now.
        // We'll store:
        // - address: empty
        // - lovelace: 0 unless we can find it
        var lovelace: u64 = 0;

        // Common simple form: [addr_bytes, amount]
        if (o == .array and o.array.len >= 2) {
            const amt = o.array[1];

            // amount may be u64 or map (multi-asset). If u64, use it.
            if (amt == .u64) lovelace = amt.u64;
            if (amt == .map_u64) {
                // Sometimes lovelace sits under key 0 in a map
                const v0 = findMapValue(amt.map_u64, 0);
                if (v0 != null and v0.? == .u64) lovelace = v0.?.u64;
            }
        }

        const produced = utxo.Produced{
            .input = .{ .tx_hash = tx_hash, .index = out_index },
            .output = .{ .address = "", .lovelace = lovelace },
        };

        out.append(produced) catch return null;
        out_index += 1;
    }

    return out.toOwnedSlice() catch null;
}

/// Extract deltas from a tx-list (array items) where each item is bytes/tag24/map.
/// - Never panics; best-effort.
/// - Returns empty deltas if we can't decode.
pub fn extractTxDeltas(
    alloc: std.mem.Allocator,
    tx_source: anytype,
    debug: bool,
) !TxDeltas {
    var consumed_list = std.ArrayList(utxo.TxIn).init(alloc);
    errdefer consumed_list.deinit();
    var produced_list = std.ArrayList(utxo.Produced).init(alloc);
    errdefer produced_list.deinit();

    var tx_count: u64 = 0;

    const SourceT = @TypeOf(tx_source);
    var tx_list_items: []cbor.Term = &[_]cbor.Term{};
    const seq_owner: ?cbor.Term = null;
    if (SourceT == []const u8) {
        // === Step 2: robust tx body decode with raw CBOR fallback (Babbage) ===

        const body_bytes = tx_source;
        var tx_list: ?[]cbor.Term = null;
        var tx_list_kind: []const u8 = "unknown";

        // reader over block body bytes
        var fbs0 = std.io.fixedBufferStream(body_bytes);
        const r0 = fbs0.reader();
        // read first CBOR byte so we can fall back if needed
        const first_byte = try r0.readByte();

        // rewind reader
        var fbs = std.io.fixedBufferStream(body_bytes);
        const r = fbs.reader(); // decode outer term, preserving raw CBOR on UnsupportedCborType
        var term: cbor.Term = cbor.decode(alloc, r) catch |err| blk: {
            if (err == error.UnsupportedCborType) {
                // raw CBOR scanner (indefinite array/map safe)
                const raw = try cbor_term.decodeUnsupportedAsBytes(
                    alloc,
                    r,
                    first_byte,
                );
                break :blk cbor.Term{ .bytes = raw };
            }
            return err;
        };
        defer cbor.free(term, alloc);

        // if wrapped as raw bytes, decode AGAIN to reach real structure
        if (term == .bytes) {
            var inner_fbs = std.io.fixedBufferStream(term.bytes);
            const inner_r = inner_fbs.reader();
            term = try cbor.decode(alloc, inner_r);
        }

        // === Babbage tx bodies live at map[0] ===
        if (term == .map_u64) {
            const entries = term.map_u64;
            if (findMapValue(entries, 0)) |txs_term| {
                if (txs_term == .array) {
                    tx_list = txs_term.array;
                    tx_list_kind = "babbage-map-0";
                }
            }
        }

        // optional debug
        if (debug) {
            std.debug.print(
                "TX_DECODE: tx_list_kind={s} len={d}\n",
                .{
                    tx_list_kind,
                    if (tx_list) |l| l.len else 0,
                },
            );
        }

        if (tx_list) |items| {
            tx_list_items = items;
        } else {
            return .{
                .consumed = try consumed_list.toOwnedSlice(),
                .produced = try produced_list.toOwnedSlice(),
                .tx_count = 0,
            };
        }
    } else if (SourceT == []cbor.Term) {
        tx_list_items = tx_source;
    } else {
        @compileError("extractTxDeltas expects []const u8 or []cbor.Term");
    }
    defer if (seq_owner) |t| cbor.free(t, alloc);

    for (tx_list_items) |item| {
        tx_count += 1;

        // Decode to a tx-body map
        const decoded_opt = decodeTxBodyItemToMap(alloc, item);
        if (decoded_opt == null) {
            if (debug) std.debug.print("TX_DECODE: skip tx_item (not decodable)\n", .{});
            continue;
        }
        const tx_term = decoded_opt.?;

        // If we allocated it (bytes/tag24 path), we must free it.
        const allocated = (item != .map_u64);
        if (allocated) {
            defer cbor.free(tx_term, alloc);
        }

        // Compute temporary tx hash
        const h_opt = if (tx_term == .map_u64) hashTxBodyMap(alloc, tx_term.map_u64) else null;
        if (h_opt == null) continue;
        const tx_hash = h_opt.?;

        // Parse inputs/outputs
        const ins = parseInputs(alloc, tx_hash, tx_term) orelse continue;
        defer alloc.free(ins);

        const outs = parseOutputs(alloc, tx_hash, tx_term) orelse continue;
        defer alloc.free(outs);

        for (ins) |i| try consumed_list.append(i);
        for (outs) |o| try produced_list.append(o);
    }

    return .{
        .consumed = try consumed_list.toOwnedSlice(),
        .produced = try produced_list.toOwnedSlice(),
        .tx_count = tx_count,
    };
}
