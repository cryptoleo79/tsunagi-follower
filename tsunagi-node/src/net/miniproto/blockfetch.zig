const Mux = @import("../mux.zig").Mux;
const Message = @import("../protocol/message.zig").Message;
const BlockFetchMsg = @import("../protocol/message.zig").BlockFetchMsg;

pub const BlockFetch = struct {
    mux: *Mux,

    pub fn attach(m: *Mux) BlockFetch {
        return .{ .mux = m };
    }

    pub fn requestRange(self: *BlockFetch) void {
        self.mux.route(.{ .blockfetch = .request_range });
    }
};
