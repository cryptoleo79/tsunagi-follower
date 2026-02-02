const Mux = @import("../mux.zig").Mux;
const Message = @import("../protocol/message.zig").Message;

pub const ChainSync = struct {
    mux: *Mux,

    pub fn attach(m: *Mux) ChainSync {
        return .{ .mux = m };
    }

    pub fn findIntersect(self: *ChainSync) !void {
        try self.mux.send(.{ .chainsync = .find_intersect });
    }

    pub fn requestNext(self: *ChainSync) !void {
        try self.mux.send(.{ .chainsync = .request_next });
    }
};
