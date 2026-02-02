const std = @import("std");
const ByteTransport = @import("byte_transport.zig").ByteTransport;
const ByteTransportVTable = @import("byte_transport.zig").ByteTransportVTable;

const MemoryByteTransportImpl = struct {
    alloc: std.mem.Allocator,
    buf: []u8,
    r: usize,
    w: usize,

    fn capacity(self: *MemoryByteTransportImpl) usize {
        return self.buf.len;
    }

    fn availableToRead(self: *MemoryByteTransportImpl) usize {
        if (self.w >= self.r) return self.w - self.r;
        return (self.buf.len - self.r) + self.w;
    }

    fn availableToWrite(self: *MemoryByteTransportImpl) usize {
        // leave 1 byte empty to distinguish full vs empty
        return self.buf.len - 1 - self.availableToRead();
    }

    fn writeAll(ctx: *anyopaque, data: []const u8) anyerror!void {
        var self: *MemoryByteTransportImpl = @ptrCast(@alignCast(ctx));
        if (data.len > self.availableToWrite()) return error.NoSpace;

        var i: usize = 0;
        while (i < data.len) : (i += 1) {
            self.buf[self.w] = data[i];
            self.w = (self.w + 1) % self.buf.len;
        }
    }

    fn readAtMost(ctx: *anyopaque, out: []u8) anyerror!usize {
        var self: *MemoryByteTransportImpl = @ptrCast(@alignCast(ctx));
        const avail = self.availableToRead();
        if (avail == 0) return 0;

        const n = @min(avail, out.len);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            out[i] = self.buf[self.r];
            self.r = (self.r + 1) % self.buf.len;
        }
        return n;
    }

    fn deinit(ctx: *anyopaque) void {
        const self: *MemoryByteTransportImpl = @ptrCast(@alignCast(ctx));
        self.alloc.free(self.buf);
        self.alloc.destroy(self);
    }

    const vtable = ByteTransportVTable{
        .writeAll = writeAll,
        .readAtMost = readAtMost,
        .deinit = deinit,
    };
};

pub fn init(alloc: std.mem.Allocator, capacity_bytes: usize) ByteTransport {
    // +1 so we can keep one empty slot (full/empty distinction)
    const cap = if (capacity_bytes < 8) 8 else capacity_bytes;
    const backing = alloc.alloc(u8, cap + 1) catch unreachable;

    const impl = alloc.create(MemoryByteTransportImpl) catch unreachable;
    impl.* = .{
        .alloc = alloc,
        .buf = backing,
        .r = 0,
        .w = 0,
    };

    return .{
        .ctx = impl,
        .vtable = &MemoryByteTransportImpl.vtable,
    };
}
