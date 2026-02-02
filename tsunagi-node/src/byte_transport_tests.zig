const std = @import("std");
const mem_bt = @import("net/transport/memory_byte_transport.zig");
const ByteTransport = @import("net/transport/byte_transport.zig").ByteTransport;

test "memory byte transport roundtrip" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var t: ByteTransport = mem_bt.init(alloc, 64);
    defer t.deinit();

    const msg = "hello-tsunagi";
    try t.writeAll(msg);

    var buf: [32]u8 = undefined;
    const n = try t.readAtMost(&buf);

    try std.testing.expectEqual(@as(usize, msg.len), n);
    try std.testing.expectEqualStrings(msg, buf[0..n]);
}

test "memory byte transport enforces capacity" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var t: ByteTransport = mem_bt.init(alloc, 8);
    defer t.deinit();

    // try to overflow
    const big = "0123456789abcdef";
    try std.testing.expectError(error.NoSpace, t.writeAll(big));
}
