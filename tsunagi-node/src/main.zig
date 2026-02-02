const std = @import("std");

const PeerManager = @import("net/peer_manager.zig").PeerManager;
const Mux = @import("net/mux.zig").Mux;
const Message = @import("net/protocol/message.zig").Message;
const ChainSync = @import("net/miniproto/chainsync.zig").ChainSync;
const BlockFetch = @import("net/miniproto/blockfetch.zig").BlockFetch;

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

    var mux = Mux.init(alloc);
    defer mux.deinit();

    var cs = ChainSync.attach(&mux);
    var bf = BlockFetch.attach(&mux);

    // Phase C.3: enqueue a tiny scripted flow
    try cs.findIntersect();
    try cs.requestNext();
    try bf.requestRange();

    // Fake peer loop: drain queue deterministically
    std.debug.print("TSUNAGI Node fake peer loop start (Phase C.3)\n", .{});
    while (mux.recv()) |msg| {
        printMsg(msg);
    }
    std.debug.print("TSUNAGI Node fake peer loop done (Phase C.3)\n", .{});
}
