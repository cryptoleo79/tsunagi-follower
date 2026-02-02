const Message = @import("protocol/message.zig").Message;

pub const Mux = struct {
    // TODO: real channel routing later

    pub fn attachHandshake() Mux {
        return .{};
    }

    pub fn route(self: *Mux, msg: Message) void {
        _ = self;
        _ = msg;
        // Phase C.2: routing is a no-op
    }
};
