const Transport = @import("transport/transport.zig").Transport;
const Message = @import("protocol/message.zig").Message;

pub const Mux = struct {
    transport: Transport,

    pub fn init(transport: Transport) Mux {
        return .{ .transport = transport };
    }

    pub fn deinit(self: *Mux) void {
        self.transport.deinit();
    }

    pub fn send(self: *Mux, msg: Message) !void {
        try self.transport.send(msg);
    }

    pub fn recv(self: *Mux) !?Message {
        return try self.transport.recv();
    }
};
