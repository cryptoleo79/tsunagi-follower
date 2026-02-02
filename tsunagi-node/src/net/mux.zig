const std = @import("std");
const Message = @import("protocol/message.zig").Message;
const Queue = @import("runtime/queue.zig").Queue;

pub const Mux = struct {
    alloc: std.mem.Allocator,
    inbox: Queue(Message),

    pub fn init(alloc: std.mem.Allocator) Mux {
        return .{
            .alloc = alloc,
            .inbox = Queue(Message).init(alloc),
        };
    }

    pub fn deinit(self: *Mux) void {
        self.inbox.deinit();
    }

    pub fn send(self: *Mux, msg: Message) !void {
        try self.inbox.push(msg);
    }

    pub fn recv(self: *Mux) ?Message {
        return self.inbox.pop();
    }
};
