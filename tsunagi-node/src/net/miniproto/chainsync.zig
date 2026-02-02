const Mux = @import("../mux.zig").Mux;
const Message = @import("../protocol/message.zig").Message;
const ChainSyncMsg = @import("../protocol/message.zig").ChainSyncMsg;

pub const ChainSync = struct {
    mux: *Mux,

    pub fn attach(m: *Mux) ChainSync {
        return .{ .mux = m };
    }

    pub fn requestNext(self: *ChainSync) void {
        self.mux.route(.{ .chainsync = .request_next });
    }
};
