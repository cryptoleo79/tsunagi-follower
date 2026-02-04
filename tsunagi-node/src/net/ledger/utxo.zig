const std = @import("std");

pub const TxIn = struct {
    tx_hash: [32]u8,
    index: u32,
};

pub const TxOut = struct {
    // For now we keep address as raw bytes (CBOR bytes or bech32 later).
    address: []const u8,
    lovelace: u64,
};

pub const UndoEntry = union(enum) {
    // We inserted a new UTxO in this block; rollback should remove it.
    inserted: TxIn,
    // We removed a spent UTxO in this block; rollback should restore it.
    removed: struct { input: TxIn, output: TxOut },
};

pub const Undo = struct {
    entries: std.ArrayList(UndoEntry),

    pub fn init(alloc: std.mem.Allocator) Undo {
        return .{ .entries = std.ArrayList(UndoEntry).init(alloc) };
    }

    pub fn deinit(self: *Undo) void {
        self.entries.deinit();
    }
};

pub const UTxO = struct {
    alloc: std.mem.Allocator,
    map: std.AutoHashMap(TxIn, TxOut),

    pub fn init(alloc: std.mem.Allocator) UTxO {
        return .{ .alloc = alloc, .map = std.AutoHashMap(TxIn, TxOut).init(alloc) };
    }

    pub fn deinit(self: *UTxO) void {
        // NOTE: address slices are owned by us (dupes), free them.
        var it = self.map.iterator();
        while (it.next()) |kv| {
            self.alloc.free(kv.value_ptr.address);
        }
        self.map.deinit();
    }

    fn dupeOut(self: *UTxO, out: TxOut) !TxOut {
        return .{
            .address = try self.alloc.dupe(u8, out.address),
            .lovelace = out.lovelace,
        };
    }

    /// Apply a "delta" of consumed inputs and produced outputs.
    /// This returns an Undo log that can revert this delta exactly.
    pub fn applyDelta(
        self: *UTxO,
        consumed: []const TxIn,
        produced: []const struct { input: TxIn, output: TxOut },
    ) !Undo {
        var undo = Undo.init(self.alloc);
        errdefer undo.deinit();

        // 1) Consume inputs (remove from UTxO)
        for (consumed) |input| {
            if (self.map.fetchRemove(input)) |removed| {
                // Save removed output for rollback.
                const saved = try self.dupeOut(removed.value);
                try undo.entries.append(.{ .removed = .{ .input = input, .output = saved } });
                // Free stored output address from map removal result.
                self.alloc.free(removed.value.address);
            } else {
                // Input not found — for now we treat as non-fatal in this phase.
                // Later, ledger validation decides if this is invalid.
            }
        }

        // 2) Produce new outputs (insert into UTxO)
        for (produced) |p| {
            const out_copy = try self.dupeOut(p.output);

            // Insert; if existing, free old and overwrite.
            if (try self.map.fetchPut(p.input, out_copy)) |old| {
                self.alloc.free(old.value.address);
            }

            // Mark insertion for rollback.
            try undo.entries.append(.{ .inserted = p.input });
        }

        return undo;
    }

    /// Roll back a previously applied delta using its Undo log.
    pub fn rollbackDelta(self: *UTxO, undo: *Undo) void {
        // Reverse order to undo correctly.
        var i: usize = undo.entries.items.len;
        while (i > 0) {
            i -= 1;
            const e = undo.entries.items[i];
            switch (e) {
                .inserted => |input| {
                    if (self.map.fetchRemove(input)) |removed| {
                        self.alloc.free(removed.value.address);
                    }
                },
                .removed => |r| {
                    // Restore removed output.
                    // If something exists there already, free and overwrite.
                    const restored = TxOut{
                        .address = self.alloc.dupe(u8, r.output.address) catch r.output.address,
                        .lovelace = r.output.lovelace,
                    };
                    if (self.map.fetchPut(r.input, restored) catch null) |old| {
                        self.alloc.free(old.value.address);
                    }
                },
            }
        }
    }

    pub fn count(self: *UTxO) usize {
        return self.map.count();
    }
};

// ------------------
// Unit tests (local)
// ------------------

test "utxo applyDelta + rollbackDelta roundtrip" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var utxo = UTxO.init(alloc);
    defer utxo.deinit();

    const txh1 = [_]u8{1} ** 32;
    const txh2 = [_]u8{2} ** 32;

    const in1 = TxIn{ .tx_hash = txh1, .index = 0 };
    const in2 = TxIn{ .tx_hash = txh2, .index = 1 };

    // Produce two outputs
    var produced = [_]struct { input: TxIn, output: TxOut }{
        .{ .input = in1, .output = .{ .address = "addr1", .lovelace = 100 } },
        .{ .input = in2, .output = .{ .address = "addr2", .lovelace = 200 } },
    };

    var undo1 = try utxo.applyDelta(&[_]TxIn{}, &produced);
    defer undo1.deinit();

    try std.testing.expectEqual(@as(usize, 2), utxo.count());

    // Consume one and produce one new
    const txh3 = [_]u8{3} ** 32;
    const in3 = TxIn{ .tx_hash = txh3, .index = 0 };

    const consumed = [_]TxIn{in1};
    var produced2 = [_]struct { input: TxIn, output: TxOut }{
        .{ .input = in3, .output = .{ .address = "addr3", .lovelace = 300 } },
    };

    var undo2 = try utxo.applyDelta(&consumed, &produced2);
    defer undo2.deinit();

    try std.testing.expectEqual(@as(usize, 2), utxo.count());

    // Roll back second delta
    utxo.rollbackDelta(&undo2);
    try std.testing.expectEqual(@as(usize, 2), utxo.count());

    // Roll back first delta
    utxo.rollbackDelta(&undo1);
    try std.testing.expectEqual(@as(usize, 0), utxo.count());
}
