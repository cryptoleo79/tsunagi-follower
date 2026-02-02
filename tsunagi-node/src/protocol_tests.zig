const std = @import("std");

const Mux = @import("net/mux.zig").Mux;
const ChainSync = @import("net/miniproto/chainsync.zig").ChainSync;
const BlockFetch = @import("net/miniproto/blockfetch.zig").BlockFetch;

const memory_transport = @import("net/transport/memory_transport.zig");

test "chainsync invalid order is rejected" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const t = memory_transport.init(alloc);
    var mux = Mux.init(t);
    defer mux.deinit();

    var cs = ChainSync.attach(&mux);

    // requestNext before findIntersect should fail
    try std.testing.expectError(error.InvalidState, cs.requestNext());
}

test "message ordering is FIFO across mux/transport" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const t = memory_transport.init(alloc);
    var mux = Mux.init(t);
    defer mux.deinit();

    var cs = ChainSync.attach(&mux);
    var bf = BlockFetch.attach(&mux);

    try cs.findIntersect();
    try cs.requestNext();
    try bf.requestRange();

    const a = try mux.recv();
    const b = try mux.recv();
    const c = try mux.recv();
    const d = try mux.recv();

    try std.testing.expect(a != null and b != null and c != null);
    try std.testing.expect(d == null);

    // Ensure ordering by tag name
    switch (a.?) {
        .chainsync => |m| try std.testing.expectEqualStrings("find_intersect", @tagName(m)),
        else => return error.TestUnexpected,
    }
    switch (b.?) {
        .chainsync => |m| try std.testing.expectEqualStrings("request_next", @tagName(m)),
        else => return error.TestUnexpected,
    }
    switch (c.?) {
        .blockfetch => |m| try std.testing.expectEqualStrings("request_range", @tagName(m)),
        else => return error.TestUnexpected,
    }
}
