const std = @import("std");

const PeerManager = @import("net/peer_manager.zig").PeerManager;
const Mux = @import("net/mux.zig").Mux;
const Message = @import("net/protocol/message.zig").Message;
const ChainSync = @import("net/miniproto/chainsync.zig").ChainSync;
const BlockFetch = @import("net/miniproto/blockfetch.zig").BlockFetch;
const follower = @import("net/chainsync/follower.zig");

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
        \\  zig build run -- run [--net preview|mainnet] [--peer host:port] [--lang en|ja] [--debug]
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

fn getStateDir(alloc: std.mem.Allocator) ![]u8 {
    const env_dir = std.process.getEnvVarOwned(alloc, "TSUNAGI_HOME") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };
    if (env_dir) |dir| {
        if (dir.len > 0) return dir;
        alloc.free(dir);
    }

    const home = std.process.getEnvVarOwned(alloc, "HOME") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };
    if (home) |dir| {
        defer alloc.free(dir);
        return try std.fs.path.join(alloc, &[_][]const u8{ dir, ".tsunagi" });
    }
    return error.EnvironmentVariableNotFound;
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
            var peer_override: ?[]const u8 = null;

            while (args_it.next()) |arg| {
                if (std.mem.eql(u8, arg, "--debug")) {
                    debug = true;
                    continue;
                }
                if (std.mem.eql(u8, arg, "--peer")) {
                    peer_override = args_it.next() orelse {
                        std.debug.print("missing value for --peer\n", .{});
                        return error.InvalidArgs;
                    };
                    continue;
                }
                if (parseFlagValue(arg, "--peer")) |val| {
                    peer_override = val;
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

            var host: []const u8 = undefined;
            var port: u16 = undefined;
            var used_peer_override = false;
            var host_owned = false;

            if (peer_override) |peer| {
                const colon = std.mem.indexOfScalar(u8, peer, ':') orelse {
                    std.debug.print("invalid --peer value (expected host:port)\n", .{});
                    return error.InvalidArgs;
                };
                host = peer[0..colon];
                const port_str = peer[colon + 1 ..];
                port = std.fmt.parseUnsigned(u16, port_str, 10) catch {
                    std.debug.print("invalid --peer port\n", .{});
                    return error.InvalidArgs;
                };
                used_peer_override = true;
            } else {
                if (std.mem.eql(u8, net, "mainnet")) {
                    const timeout_ms: u32 = 3_000;
                    const peer = try follower.selectMainnetPeer(alloc, timeout_ms) orelse {
                        std.debug.print(
                            "mainnet peer selection failed; pass --peer host:port\n",
                            .{},
                        );
                        return error.InvalidArgs;
                    };
                    host = peer.host;
                    port = peer.port;
                    host_owned = true;
                } else if (std.mem.eql(u8, net, "preview")) {
                    host = "preview-node.world.dev.cardano.org";
                    port = 30002;
                } else if (std.mem.eql(u8, net, "preprod")) {
                    host = "preprod-node.world.dev.cardano.org";
                    port = 30000;
                } else {
                    std.debug.print("unknown net: {s}\n", .{net});
                    return error.InvalidArgs;
                }
            }

            pretty.printHeader(lang);
            defer if (host_owned) alloc.free(host);
            if (used_peer_override) {
                if (lang == .ja) {
                    std.debug.print("接続先指定: {s}:{d}\n", .{ host, port });
                } else {
                    std.debug.print("Peer override: {s}:{d}\n", .{ host, port });
                }
            } else {
                if (lang == .ja) {
                    std.debug.print("ネットワーク: {s} 接続先={s}:{d}\n", .{ net, host, port });
                } else {
                    std.debug.print("Network: {s} peer={s}:{d}\n", .{ net, host, port });
                }
            }
            std.debug.print("{s}\n", .{i18n.msg(lang, "running")});
            std.debug.print("{s}\n", .{i18n.msg(lang, "ctrlc_hint")});

            const is_mainnet = std.mem.eql(u8, net, "mainnet");
            try chainsync_mux_smoke.runWithOptions(alloc, host, port, lang, debug, true, is_mainnet);
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

            const state_dir = try getStateDir(alloc);
            defer alloc.free(state_dir);
            std.fs.cwd().makePath(state_dir) catch {};
            const cursor_path = try std.fs.path.join(alloc, &[_][]const u8{ state_dir, "cursor.json" });
            defer alloc.free(cursor_path);
            const journal_path = try std.fs.path.join(alloc, &[_][]const u8{ state_dir, "journal.ndjson" });
            defer alloc.free(journal_path);
            const utxo_path = try std.fs.path.join(alloc, &[_][]const u8{ state_dir, "utxo.snapshot" });
            defer alloc.free(utxo_path);

            std.debug.print("state_dir: {s}\n", .{state_dir});
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
