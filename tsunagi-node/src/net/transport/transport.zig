const std = @import("std");
const Message = @import("../protocol/message.zig").Message;

/// Transport is the boundary between "protocol logic" and "how bytes/messages move".
/// Phase D.1: message-level transport only (no bytes yet).
pub const TransportVTable = struct {
    send: *const fn (ctx: *anyopaque, msg: Message) anyerror!void,
    recv: *const fn (ctx: *anyopaque) anyerror!?Message,
    deinit: *const fn (ctx: *anyopaque) void,
};

pub const Transport = struct {
    ctx: *anyopaque,
    vtable: *const TransportVTable,

    pub fn send(self: *Transport, msg: Message) !void {
        try self.vtable.send(self.ctx, msg);
    }

    pub fn recv(self: *Transport) !?Message {
        return try self.vtable.recv(self.ctx);
    }

    pub fn deinit(self: *Transport) void {
        self.vtable.deinit(self.ctx);
    }
};
