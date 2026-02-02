const std = @import("std");

pub const ByteTransportVTable = struct {
    writeAll: *const fn (ctx: *anyopaque, data: []const u8) anyerror!void,
    readAtMost: *const fn (ctx: *anyopaque, buf: []u8) anyerror!usize,
    deinit: *const fn (ctx: *anyopaque) void,
};

pub const ByteTransport = struct {
    ctx: *anyopaque,
    vtable: *const ByteTransportVTable,

    pub fn writeAll(self: *ByteTransport, data: []const u8) !void {
        try self.vtable.writeAll(self.ctx, data);
    }

    /// Reads up to buf.len bytes. Returns number of bytes read.
    /// 0 means EOF / nothing available (depending on impl).
    pub fn readAtMost(self: *ByteTransport, buf: []u8) !usize {
        return try self.vtable.readAtMost(self.ctx, buf);
    }

    pub fn deinit(self: *ByteTransport) void {
        self.vtable.deinit(self.ctx);
    }
};
