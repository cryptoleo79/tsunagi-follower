const std = @import("std");

const Mux = @import("net/mux.zig").Mux;
const ChainSync = @import("net/miniproto/chainsync.zig").ChainSync;
const BlockFetch = @import("net/miniproto/blockfetch.zig").BlockFetch;
const memory_bt = @import("net/transport/memory_byte_transport.zig");

test "mux sends and receives framed messages in order" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const bt = memory_bt.init(alloc, 256);
    var mux = Mux.init(alloc, bt);
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
}
