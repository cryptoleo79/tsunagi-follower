const std = @import("std");
const tcp_bt = @import("tcp_byte_transport.zig");

pub fn run(alloc: std.mem.Allocator, host: []const u8, port: u16) !void {
    var t = try tcp_bt.connect(alloc, host, port);
    defer t.deinit();

    std.debug.print("✅ TCP connected: {s}:{d}\n", .{ host, port });

    // Smoke test only: connect + clean close.
    // No protocol frames yet (that comes next).
}
