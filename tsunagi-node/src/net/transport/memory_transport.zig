const std = @import("std");
const Message = @import("../protocol/message.zig").Message;
const Queue = @import("../runtime/queue.zig").Queue;
const Transport = @import("transport.zig").Transport;
const TransportVTable = @import("transport.zig").TransportVTable;

const MemoryTransportImpl = struct {
    alloc: std.mem.Allocator,
    inbox: Queue(Message),

    fn send(ctx: *anyopaque, msg: Message) anyerror!void {
        const self: *MemoryTransportImpl = @ptrCast(@alignCast(ctx));
        try self.inbox.push(msg);
    }

    fn recv(ctx: *anyopaque) anyerror!?Message {
        const self: *MemoryTransportImpl = @ptrCast(@alignCast(ctx));
        return self.inbox.pop();
    }

    fn deinit(ctx: *anyopaque) void {
        const self: *MemoryTransportImpl = @ptrCast(@alignCast(ctx));
        self.inbox.deinit();
        self.alloc.destroy(self);
    }

    const vtable = TransportVTable{
        .send = send,
        .recv = recv,
        .deinit = deinit,
    };
};

pub fn init(alloc: std.mem.Allocator) Transport {
    const impl = alloc.create(MemoryTransportImpl) catch unreachable;
    impl.* = .{
        .alloc = alloc,
        .inbox = Queue(Message).init(alloc),
    };

    return .{
        .ctx = impl,
        .vtable = &MemoryTransportImpl.vtable,
    };
}
