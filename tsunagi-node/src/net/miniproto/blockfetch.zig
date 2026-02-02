const Mux = @import("../mux.zig").Mux;
const Message = @import("../protocol/message.zig").Message;

pub const BlockFetch = struct {
    mux: *Mux,

    pub fn attach(m: *Mux) BlockFetch {
        return .{ .mux = m };
    }

    pub fn requestRange(self: *BlockFetch) !void {
        try self.mux.send(.{ .blockfetch = .request_range });
    }
};
