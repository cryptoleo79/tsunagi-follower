const std = @import("std");

const PeerManager = @import("net/peer_manager.zig").PeerManager;
const Mux = @import("net/mux.zig").Mux;
const Message = @import("net/protocol/message.zig").Message;
const ChainSync = @import("net/miniproto/chainsync.zig").ChainSync;
const BlockFetch = @import("net/miniproto/blockfetch.zig").BlockFetch;

const memory_bt = @import("net/transport/memory_byte_transport.zig");
const tcp_smoke = @import("net/transport/tcp_smoke.zig");
const tcp_framed_mod = @import("net/transport/tcp_framed.zig");
const handshake_smoke = @import("net/handshake/handshake_smoke.zig");
const handshake_mux_smoke = @import("net/handshake/handshake_mux_smoke.zig");

fn printMsg(msg: Message) void {
    switch (msg) {
        .chainsync => |m| std.debug.print("[peer] chainsync: {s}\n", .{@tagName(m)}),
        .blockfetch => |m| std.debug.print("[peer] blockfetch: {s}\n", .{@tagName(m)}),
    }
}

fn usage() void {
    std.debug.print(
        \\TSUNAGI Node (Zig-only) — dev scaffolding
        \\
        \\Usage:
        \\  zig build run
        \\  zig build run -- tcp-smoke <host> <port>
        \\  zig build run -- tcp-framed <host> <port>
        \\  zig build run -- handshake-smoke <host> <port>
        \\  zig build run -- handshake-mux-smoke <host> <port>
        \\
        \\Default: runs in-memory framed mux demo.
        \\
    , .{});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const pm = PeerManager.init();
    _ = pm;

    var args_it = try std.process.argsWithAllocator(alloc);
    defer args_it.deinit();

    _ = args_it.next(); // argv[0]

    if (args_it.next()) |cmd| {
        if (std.mem.eql(u8, cmd, "tcp-smoke")) {
            const host = args_it.next() orelse {
                usage();
                return error.InvalidArgs;
            };
            const port_s = args_it.next() orelse {
                usage();
                return error.InvalidArgs;
            };
            const port_u = std.fmt.parseUnsigned(u16, port_s, 10) catch {
                usage();
                return error.InvalidArgs;
            };
            try tcp_smoke.run(alloc, host, port_u);
            return;
        } else if (std.mem.eql(u8, cmd, "tcp-framed")) {
            const host = args_it.next() orelse {
                usage();
                return error.InvalidArgs;
            };
            const port_s = args_it.next() orelse {
                usage();
                return error.InvalidArgs;
            };
            const port_u = std.fmt.parseUnsigned(u16, port_s, 10) catch {
                usage();
                return error.InvalidArgs;
            };
            try tcp_framed_mod.run(alloc, host, port_u);
            return;
        } else if (std.mem.eql(u8, cmd, "handshake-smoke")) {
            const host = args_it.next() orelse {
                usage();
                return error.InvalidArgs;
            };
            const port_s = args_it.next() orelse {
                usage();
                return error.InvalidArgs;
            };
            const port_u = std.fmt.parseUnsigned(u16, port_s, 10) catch {
                usage();
                return error.InvalidArgs;
            };
            try handshake_smoke.run(alloc, host, port_u);
            return;
        } else if (std.mem.eql(u8, cmd, "handshake-mux-smoke")) {
            const host = args_it.next() orelse {
                usage();
                return error.InvalidArgs;
            };
            const port_s = args_it.next() orelse {
                usage();
                return error.InvalidArgs;
            };
            const port_u = std.fmt.parseUnsigned(u16, port_s, 10) catch {
                usage();
                return error.InvalidArgs;
            };
            try handshake_mux_smoke.run(alloc, host, port_u);
            return;
        } else {
            usage();
            return error.InvalidArgs;
        }
    }

    // Default: in-memory framed mux demo
    const bt = memory_bt.init(alloc, 256);
    var mux = Mux.init(alloc, bt);
    defer mux.deinit();

    var cs = ChainSync.attach(&mux);
    var bf = BlockFetch.attach(&mux);

    try cs.findIntersect();
    try cs.requestNext();
    try bf.requestRange();

    std.debug.print("TSUNAGI Node framed mux start (D.3.3)\n", .{});
    while (try mux.recv()) |msg| {
        printMsg(msg);
    }
    std.debug.print("TSUNAGI Node framed mux done (D.3.3)\n", .{});
}
