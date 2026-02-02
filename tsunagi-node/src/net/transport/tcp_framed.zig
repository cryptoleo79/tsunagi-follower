const std = @import("std");

const Mux = @import("../mux.zig").Mux;
const Message = @import("../protocol/message.zig").Message;
const ChainSync = @import("../miniproto/chainsync.zig").ChainSync;
const BlockFetch = @import("../miniproto/blockfetch.zig").BlockFetch;

const tcp_bt = @import("tcp_byte_transport.zig");

fn printMsg(msg: Message) void {
    switch (msg) {
        .chainsync => |m| std.debug.print("[peer] chainsync: {s}\n", .{@tagName(m)}),
        .blockfetch => |m| std.debug.print("[peer] blockfetch: {s}\n", .{@tagName(m)}),
    }
}

pub fn run(alloc: std.mem.Allocator, host: []const u8, port: u16) !void {
    const bt = try tcp_bt.connect(alloc, host, port);
    var mux = Mux.init(alloc, bt);
    defer mux.deinit();

    var cs = ChainSync.attach(&mux);
    var bf = BlockFetch.attach(&mux);

    // Toy messages: exercises framing+codec path over TCP.
    try cs.findIntersect();
    try cs.requestNext();
    try bf.requestRange();

    std.debug.print("tcp-framed: sent toy framed messages to {s}:{d}\n", .{ host, port });

    // Best-effort: try a few recv cycles, then exit.
    var spins: usize = 0;
    while (spins < 10) : (spins += 1) {
        if (try mux.recv()) |msg| {
            printMsg(msg);
        } else {
            std.time.sleep(50 * std.time.ns_per_ms);
        }
    }

    std.debug.print("tcp-framed: done\n", .{});
}
