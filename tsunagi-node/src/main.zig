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
const chainsync_mux_smoke = @import("net/chainsync/chainsync_mux_smoke.zig");
const i18n = @import("cli/i18n.zig");
const pretty = @import("cli/pretty.zig");

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
        \\  zig build run -- run [--net preview|mainnet] [--lang en|ja] [--debug]
        \\  zig build run -- doctor [--lang en|ja]
        \\  zig build run -- tcp-smoke <host> <port>
        \\  zig build run -- tcp-framed <host> <port>
        \\  zig build run -- handshake-smoke <host> <port>
        \\  zig build run -- handshake-mux-smoke <host> <port>
        \\  zig build run -- chainsync-mux-smoke <host> <port>
        \\
        \\Default: runs in-memory framed mux demo.
        \\
    , .{});
}

fn fileExists(path: []const u8) bool {
    const f = std.fs.openFileAbsolute(path, .{}) catch return false;
    f.close();
    return true;
}

fn parseFlagValue(arg: []const u8, name: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, arg, name)) return null;
    if (arg.len == name.len) return null;
    if (arg[name.len] != '=') return null;
    return arg[name.len + 1 ..];
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
        if (std.mem.eql(u8, cmd, "run")) {
            var lang: i18n.Lang = .en;
            var debug = false;
            var net: []const u8 = "preview";

            while (args_it.next()) |arg| {
                if (std.mem.eql(u8, arg, "--debug")) {
                    debug = true;
                    continue;
                }
                if (std.mem.eql(u8, arg, "--lang")) {
                    lang = i18n.parseLang(args_it.next());
                    continue;
                }
                if (parseFlagValue(arg, "--lang")) |val| {
                    lang = i18n.parseLang(val);
                    continue;
                }
                if (std.mem.eql(u8, arg, "--net")) {
                    net = args_it.next() orelse {
                        std.debug.print("missing value for --net\n", .{});
                        return error.InvalidArgs;
                    };
                    continue;
                }
                if (parseFlagValue(arg, "--net")) |val| {
                    net = val;
                    continue;
                }
                std.debug.print("unknown flag: {s}\n", .{arg});
                return error.InvalidArgs;
            }

            const host: []const u8 = if (std.mem.eql(u8, net, "preview"))
                "preview-node.world.dev.cardano.org"
            else if (std.mem.eql(u8, net, "mainnet"))
                "node.world.dev.cardano.org"
            else {
                std.debug.print("unknown net: {s}\n", .{net});
                return error.InvalidArgs;
            };
            const port: u16 = 30002;

            pretty.printHeader(lang);
            std.debug.print("{s}\n", .{i18n.msg(lang, "running")});
            std.debug.print("{s}\n", .{i18n.msg(lang, "ctrlc_hint")});

            try chainsync_mux_smoke.runWithOptions(alloc, host, port, lang, debug, true);
            return;
        } else if (std.mem.eql(u8, cmd, "doctor")) {
            var lang: i18n.Lang = .en;
            while (args_it.next()) |arg| {
                if (std.mem.eql(u8, arg, "--lang")) {
                    lang = i18n.parseLang(args_it.next());
                    continue;
                }
                if (parseFlagValue(arg, "--lang")) |val| {
                    lang = i18n.parseLang(val);
                    continue;
                }
                std.debug.print("unknown flag: {s}\n", .{arg});
                return error.InvalidArgs;
            }

            const ok = i18n.msg(lang, "doctor_ok");
            const fail = i18n.msg(lang, "doctor_fail");

            const cursor_path = "/home/midnight/.tsunagi/cursor.json";
            const journal_path = "/home/midnight/.tsunagi/journal.ndjson";
            const utxo_path = "/home/midnight/.tsunagi/utxo.snapshot";

            const cursor_exists = fileExists(cursor_path);
            const journal_exists = fileExists(journal_path);
            const utxo_exists = fileExists(utxo_path);

            std.debug.print("cursor.json: {s}\n", .{if (cursor_exists) ok else fail});
            std.debug.print("journal.ndjson: {s}\n", .{if (journal_exists) ok else fail});
            std.debug.print("utxo.snapshot: {s}\n", .{if (utxo_exists) ok else fail});
            return;
        } else if (std.mem.eql(u8, cmd, "tcp-smoke")) {
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
        } else if (std.mem.eql(u8, cmd, "chainsync-mux-smoke")) {
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
            try chainsync_mux_smoke.run(alloc, host, port_u);
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
