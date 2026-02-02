const std = @import("std");

const PeerManager = @import("net/peer_manager.zig").PeerManager;
const Mux = @import("net/mux.zig").Mux;
const Message = @import("net/protocol/message.zig").Message;
const ChainSync = @import("net/miniproto/chainsync.zig").ChainSync;
const BlockFetch = @import("net/miniproto/blockfetch.zig").BlockFetch;

const memory_transport = @import("net/transport/memory_transport.zig");

fn printMsg(msg: Message) void {
    switch (msg) {
        .chainsync => |m| std.debug.print("[peer] chainsync: {s}\n", .{@tagName(m)}),
        .blockfetch => |m| std.debug.print("[peer] blockfetch: {s}\n", .{@tagName(m)}),
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const pm = PeerManager.init();
    _ = pm;

    const t = memory_transport.init(alloc);
    var mux = Mux.init(t);
    defer mux.deinit();

    var cs = ChainSync.attach(&mux);
    var bf = BlockFetch.attach(&mux);

    try cs.findIntersect();
    try cs.requestNext();
    try bf.requestRange();

    std.debug.print("TSUNAGI Node transport boundary start (Phase D.1)\n", .{});
    while (try mux.recv()) |msg| {
        printMsg(msg);
    }
    std.debug.print("TSUNAGI Node transport boundary done (Phase D.1)\n", .{});
}
