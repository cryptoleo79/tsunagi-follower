const Mux = @import("../mux.zig").Mux;

pub const ChainSyncState = enum {
    idle,
    intersect_sent,
    request_next_sent,
};

pub const ChainSync = struct {
    mux: *Mux,
    state: ChainSyncState = .idle,

    pub fn attach(m: *Mux) ChainSync {
        return .{ .mux = m };
    }

    pub fn findIntersect(self: *ChainSync) !void {
        if (self.state != .idle) return error.InvalidState;
        try self.mux.send(.{ .chainsync = .find_intersect });
        self.state = .intersect_sent;
    }

    pub fn requestNext(self: *ChainSync) !void {
        if (self.state == .idle) return error.InvalidState;
        try self.mux.send(.{ .chainsync = .request_next });
        self.state = .request_next_sent;
    }
};
