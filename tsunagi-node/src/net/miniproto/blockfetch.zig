const Mux = @import("../mux.zig").Mux;

pub const BlockFetchState = enum {
    idle,
    range_requested,
};

pub const BlockFetch = struct {
    mux: *Mux,
    state: BlockFetchState = .idle,

    pub fn attach(m: *Mux) BlockFetch {
        return .{ .mux = m };
    }

    pub fn requestRange(self: *BlockFetch) !void {
        if (self.state != .idle) return error.InvalidState;
        try self.mux.send(.{ .blockfetch = .request_range });
        self.state = .range_requested;
    }
};
