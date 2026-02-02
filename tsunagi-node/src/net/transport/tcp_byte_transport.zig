const std = @import("std");
const ByteTransport = @import("byte_transport.zig").ByteTransport;
const ByteTransportVTable = @import("byte_transport.zig").ByteTransportVTable;

const TcpByteTransportImpl = struct {
    alloc: std.mem.Allocator,
    stream: std.net.Stream,

    fn writeAll(ctx: *anyopaque, data: []const u8) anyerror!void {
        const self: *TcpByteTransportImpl = @ptrCast(@alignCast(ctx));
        try self.stream.writer().writeAll(data);
    }

    fn readAtMost(ctx: *anyopaque, out: []u8) anyerror!usize {
        const self: *TcpByteTransportImpl = @ptrCast(@alignCast(ctx));
        return try self.stream.reader().read(out);
    }

    fn deinit(ctx: *anyopaque) void {
        const self: *TcpByteTransportImpl = @ptrCast(@alignCast(ctx));
        self.stream.close();
        self.alloc.destroy(self);
    }

    const vtable = ByteTransportVTable{
        .writeAll = writeAll,
        .readAtMost = readAtMost,
        .deinit = deinit,
    };
};

pub fn connect(alloc: std.mem.Allocator, host: []const u8, port: u16) !ByteTransport {
    var list = try std.net.getAddressList(alloc, host, port);
    defer list.deinit();

    // Try each resolved address until one connects.
    var last_err: anyerror = error.ConnectionRefused;
    for (list.addrs) |addr| {
        const stream = std.net.tcpConnectToAddress(addr) catch |e| {
            last_err = e;
            continue;
        };

        const impl = try alloc.create(TcpByteTransportImpl);
        impl.* = .{ .alloc = alloc, .stream = stream };

        return .{
            .ctx = impl,
            .vtable = &TcpByteTransportImpl.vtable,
        };
    }
    return last_err;
}

pub fn setReadTimeout(bt: *ByteTransport, timeout_ms: u32) !void {
    const impl: *TcpByteTransportImpl = @ptrCast(@alignCast(bt.ctx));
    var tv = std.posix.timeval{
        .tv_sec = @intCast(timeout_ms / 1000),
        .tv_usec = @intCast((timeout_ms % 1000) * 1000),
    };
    try std.posix.setsockopt(
        impl.stream.handle,
        std.posix.SOL.SOCKET,
        std.posix.SO.RCVTIMEO,
        std.mem.asBytes(&tv),
    );
}
