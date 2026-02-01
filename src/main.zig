const std = @import("std");
const cbor = @import("cbor.zig");

// v0.6e: Fix mux Mode bit (M): 0=initiator, 1=responder.
// This is required by the spec; wrong M commonly causes ConnectionResetByPeer. (See spec 2.1.1) :contentReference[oaicite:1]{index=1}

var g_stop = std.atomic.Value(bool).init(false);

fn onSigint(sig: c_int) callconv(.C) void {
    _ = sig;
    g_stop.store(true, .seq_cst);
}

const Lang = enum {
    jp,
    en,
};

const Subcommand = enum {
    setup,
    run,
};

const Config = struct {
    network: []const u8,
    host: []const u8,
    port: u16,
    pulse: bool,
};

pub fn main() !void {
    realMain() catch |err| switch (err) {
        error.Interrupted => return,
        else => return err,
    };
}

fn realMain() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const cfg_alloc = arena.allocator();

    // Graceful Ctrl-C termination.
    const sa = std.posix.Sigaction{
        .handler = .{ .handler = onSigint },
        .mask = std.posix.empty_sigset,
        .flags = 0,
    };
    try std.posix.sigaction(std.posix.SIG.INT, &sa, null);
    try std.posix.sigaction(std.posix.SIG.TERM, &sa, null);

    const default_host = "preview-node.world.dev.cardano.org";
    const default_port: u16 = 30002;

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    var pulse_mode = false;
    var lang: Lang = .jp;
    var subcmd: ?Subcommand = null;
    var host: ?[]const u8 = null;
    var port: ?u16 = null;

    var nonflags: [3][]const u8 = undefined;
    var nonflag_count: usize = 0;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--pulse")) {
            pulse_mode = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--lang") and i + 1 < args.len) {
            i += 1;
            const v = args[i];
            if (std.mem.eql(u8, v, "en")) lang = .en else lang = .jp;
            continue;
        }
        if (nonflag_count < nonflags.len) {
            nonflags[nonflag_count] = a;
            nonflag_count += 1;
        }
    }
    if (nonflag_count > 0) {
        if (std.mem.eql(u8, nonflags[0], "setup")) {
            subcmd = .setup;
        } else if (std.mem.eql(u8, nonflags[0], "run")) {
            subcmd = .run;
        }
    }
    var pos_idx: usize = if (subcmd != null) 1 else 0;
    if (pos_idx < nonflag_count) {
        host = nonflags[pos_idx];
        pos_idx += 1;
    }
    if (pos_idx < nonflag_count) {
        port = try std.fmt.parseInt(u16, nonflags[pos_idx], 10);
    }

    if (subcmd == .setup) {
        try ensureRepoRoot();
        const cfg = try runSetupWizard(cfg_alloc, lang, default_host, default_port);
        try writeConfigFile(cfg_alloc, cfg);
        if (lang == .jp) {
            std.debug.print("✅ tsunagi.toml を保存しました\n", .{});
        } else {
            std.debug.print("✅ saved tsunagi.toml\n", .{});
        }
        return;
    }

    var cfg = Config{
        .network = "preview",
        .host = default_host,
        .port = default_port,
        .pulse = false,
    };
    if (subcmd == .run) {
        try ensureRepoRoot();
        if (readConfigFile(cfg_alloc)) |loaded| {
            cfg = loaded;
        }
    }
    if (host) |h| cfg.host = h;
    if (port) |p| cfg.port = p;
    if (pulse_mode) cfg.pulse = true;

    std.debug.print("🌸 Tsunagi Follower v0.6e: Handshake v14 + ChainSync FindIntersect(origin) -> RequestNext\n", .{});
    std.debug.print("Target: {s}:{d}\n\n", .{ cfg.host, cfg.port });

    // ---- TCP connect ----
    const address_list = try std.net.getAddressList(alloc, cfg.host, cfg.port);
    defer address_list.deinit();

    var stream_opt: ?std.net.Stream = null;
    for (address_list.addrs) |addr| {
        std.debug.print("Try: {any}\n", .{addr});
        stream_opt = std.net.tcpConnectToAddress(addr) catch continue;
        break;
    }
    if (stream_opt == null) return error.ConnectionFailed;
    var stream = stream_opt.?;
    defer stream.close();

    // Short recv timeout so Ctrl-C can break blocking reads promptly.
    const tv = std.posix.timeval{ .tv_sec = 0, .tv_usec = 200_000 };
    try std.posix.setsockopt(
        stream.handle,
        std.posix.SOL.SOCKET,
        std.posix.SO.RCVTIMEO,
        std.mem.asBytes(&tv),
    );

    std.debug.print("✅ TCP connected\n\n", .{});

    // =========================
    // 1) Handshake (mini-proto 0)
    // =========================
    // Node-to-node handshake uses mini-protocol number 0. :contentReference[oaicite:2]{index=2}
    // ProposeVersions = [0, { 14: [2, true, 0, true] }]
    // (You already got Accept for version 14 — this stays the same.)
    const hs_payload = try buildHandshakeProposeV14(alloc);
    defer alloc.free(hs_payload);

    std.debug.print("📦 Handshake Propose payload: {d} bytes\n", .{hs_payload.len});
    hexdump(hs_payload);

    // IMPORTANT: we are the initiator => mux Mode bit must be 0. :contentReference[oaicite:3]{index=3}
    const hs_sdu = try muxEncode(alloc, true, 0, hs_payload);
    defer alloc.free(hs_sdu);

    try stream.writer().writeAll(hs_sdu);

    const hs_resp = try muxReadOne(alloc, &stream);
    defer alloc.free(hs_resp.payload);

    std.debug.print("\n📥 Handshake resp: mode(initiator?)={any} miniProto={d} len={d}\n", .{
        hs_resp.initiator_mode, hs_resp.mini_proto, hs_resp.payload_len
    });
    hexdump(hs_resp.payload);

    // Expected accept (example):
    // 83 01 0e 84 02 f4 00 f4  => [1, 14, [2, true, 0, true]]
    std.debug.print("\n🎉 Handshake stage done.\n", .{});

    // ==================================
    // 2) ChainSync (node-to-node mini-proto 2)
    // ==================================
    // Spec: ChainSync node-to-node mini-protocol number is 2. :contentReference[oaicite:4]{index=4}
    // msgFindIntersect = [4, base.points] :contentReference[oaicite:5]{index=5}
    var find_resp: MuxMsg = undefined;
    var have_find = false;
    var tip_point: ?PointInfo = null;
    var attempt: usize = 0;
    const max_attempts: usize = 5;
    while (attempt < max_attempts and !g_stop.load(.seq_cst)) : (attempt += 1) {
        var points_buf: [2]PointInfo = undefined;
        var points: []const PointInfo = undefined;
        const origin = makeOriginPoint();
        if (tip_point) |tp| {
            points_buf[0] = tp;
            points_buf[1] = origin;
            points = points_buf[0..2];
        } else {
            points_buf[0] = origin;
            points = points_buf[0..1];
        }

        const find_payload = try buildChainSyncFindIntersectWithPoints(alloc, points);
        defer alloc.free(find_payload);

        std.debug.print("\n📦 ChainSync FindIntersect payload: {d} bytes\n", .{find_payload.len});
        hexdump(find_payload);

        const find_sdu = try muxEncode(alloc, true, 2, find_payload);
        defer alloc.free(find_sdu);

        try stream.writer().writeAll(find_sdu);

        const resp = try muxReadOneChainSync(alloc, &stream);
        std.debug.print("\n📥 ChainSync resp: mode(initiator?)={any} miniProto={d} len={d}\n", .{
            resp.initiator_mode, resp.mini_proto, resp.payload_len
        });
        hexdump(resp.payload);

        // Validate ChainSync response framing and tag before requesting next.
        if (resp.mini_proto != 2 or resp.initiator_mode) {
            alloc.free(resp.payload);
            return error.UnexpectedMuxFrame;
        }
        const find_tag = readChainSyncTag(resp.payload) orelse {
            alloc.free(resp.payload);
            return error.InvalidChainSyncMessage;
        };
        if (find_tag == 5) {
            find_resp = resp;
            have_find = true;
            break;
        } else if (find_tag == 6) {
            if (parseIntersectNotFoundTipPoint(resp.payload)) |tp| {
                tip_point = tp;
        if (cfg.pulse) std.debug.print("⚠️ Intersect not found; retrying with tip point...\n", .{});
            } else {
                tip_point = null;
        if (cfg.pulse) std.debug.print("⚠️ Intersect not found; retrying...\n", .{});
            }
            alloc.free(resp.payload);
            std.time.sleep(1 * std.time.ns_per_s);
            continue;
        } else {
            alloc.free(resp.payload);
            return error.InvalidChainSyncMessage;
        }
    }
    if (!have_find) {
        std.debug.print("\n❌ Failed to find intersect after {d} attempts\n", .{max_attempts});
        return error.IntersectNotFound;
    }
    defer alloc.free(find_resp.payload);

    if (find_resp.initiator_mode) return error.UnexpectedMuxFrame;
    const find_tag = readChainSyncTag(find_resp.payload) orelse return error.InvalidChainSyncMessage;
    if (find_tag == 5) {
        // MsgIntersectFound
        if (!validateIntersectFoundPoint(find_resp.payload)) return error.InvalidChainSyncMessage;
        var iter: usize = 0;
        const max_iters: usize = 100;
        var last_roll_ms: ?i64 = null;
        var last_roll_slot: ?u64 = null;
        var await_noted = false;
        while (iter < max_iters and !g_stop.load(.seq_cst)) : (iter += 1) {
            const req_payload = try buildChainSyncRequestNext(alloc);
            defer alloc.free(req_payload);

            std.debug.print("\n📦 ChainSync RequestNext payload: {d} bytes\n", .{req_payload.len});
            hexdump(req_payload);

            const req_sdu = try muxEncode(alloc, true, 2, req_payload);
            defer alloc.free(req_sdu);

            try stream.writer().writeAll(req_sdu);

        const req_resp = try muxReadOneChainSync(alloc, &stream);
            defer alloc.free(req_resp.payload);

            std.debug.print("\n📥 RequestNext resp: mode(initiator?)={any} miniProto={d} len={d}\n", .{
                req_resp.initiator_mode, req_resp.mini_proto, req_resp.payload_len
            });
            hexdump(req_resp.payload);
            if (req_resp.mini_proto != 2 or req_resp.initiator_mode) return error.UnexpectedMuxFrame;
            var req_tag = readChainSyncTag(req_resp.payload) orelse return error.InvalidChainSyncMessage;
            var pulsed = false;
            while (req_tag == 1) {
                // MsgAwaitReply: keep waiting for RollForward/RollBackward
                if (cfg.pulse and !await_noted) {
                    std.debug.print("⏳ Awaiting next block...\n", .{});
                    await_noted = true;
                }
                const await_resp = try muxReadOneChainSync(alloc, &stream);
                std.debug.print("\n📥 RequestNext resp: mode(initiator?)={any} miniProto={d} len={d}\n", .{
                    await_resp.initiator_mode, await_resp.mini_proto, await_resp.payload_len
                });
                hexdump(await_resp.payload);
                if (await_resp.mini_proto != 2 or await_resp.initiator_mode) {
                    alloc.free(await_resp.payload);
                    return error.UnexpectedMuxFrame;
                }
                req_tag = readChainSyncTag(await_resp.payload) orelse {
                    alloc.free(await_resp.payload);
                    return error.InvalidChainSyncMessage;
                };
                if (cfg.pulse and (req_tag == 2 or req_tag == 3)) {
                    await_noted = false;
                    if (req_tag == 2) {
                        pulseRollForward(await_resp.payload, &last_roll_ms, &last_roll_slot);
                    } else {
                        pulseRollBackward(await_resp.payload, last_roll_slot);
                    }
                    pulsed = true;
                }
                alloc.free(await_resp.payload);
            }
            if (req_tag != 2 and req_tag != 3) {
                std.debug.print("\n⚠️  Unexpected ChainSync tag after RequestNext: {d}\n", .{req_tag});
                return error.InvalidChainSyncMessage;
            }
            if (cfg.pulse and !pulsed) {
                await_noted = false;
                if (req_tag == 2) {
                    pulseRollForward(req_resp.payload, &last_roll_ms, &last_roll_slot);
                } else if (req_tag == 3) {
                    pulseRollBackward(req_resp.payload, last_roll_slot);
                }
            }
        }
        if (g_stop.load(.seq_cst)) {
            std.debug.print("\n🛑 SIGINT received; stopping ChainSync loop\n", .{});
            return;
        }
    } else if (find_tag == 6) {
        return error.IntersectNotFound;
    } else {
        return error.InvalidChainSyncMessage;
    }

    std.debug.print("\n✅ Done (v0.6e)\n", .{});
}

// ===== mux =====
const MuxMsg = struct {
    // true if Mode bit was 0 (initiator), false if Mode bit was 1 (responder)
    initiator_mode: bool,
    mini_proto: u16,
    payload_len: u32,
    payload: []u8,
};

fn muxEncode(alloc: std.mem.Allocator, we_are_initiator: bool, miniProto: u16, payload: []const u8) ![]u8 {
    if (payload.len > 0xffff) return error.PayloadTooLarge;

    const micros_i64 = std.time.microTimestamp();
    const micros_u32: u32 = @truncate(@as(u64, @intCast(micros_i64)));

    // Mode bit M: 0 = initiator, 1 = responder. :contentReference[oaicite:7]{index=7}
    const mode_bit: u32 = if (we_are_initiator) 0 else 1;

    const mp: u32 = @as(u32, miniProto) & 0x7fff;
    const len: u32 = @as(u32, @intCast(payload.len)) & 0xffff;

    const word2: u32 = (mode_bit << 31) | (mp << 16) | len;

    const out = try alloc.alloc(u8, 8 + payload.len);
    std.mem.writeInt(u32, out[0..4], micros_u32, .big);
    std.mem.writeInt(u32, out[4..8], word2, .big);
    @memcpy(out[8..], payload);
    return out;
}

fn muxReadOne(alloc: std.mem.Allocator, stream: *std.net.Stream) !MuxMsg {
    var hdr: [8]u8 = undefined;
    try read_exact(stream, &hdr);

    const word2: u32 = std.mem.readInt(u32, hdr[4..8], .big);
    const mode_bit: u32 = (word2 >> 31) & 1;

    // mode_bit 0 => initiator segment; 1 => responder segment :contentReference[oaicite:8]{index=8}
    const initiator_mode = (mode_bit == 0);

    const mini_proto: u16 = @intCast((word2 >> 16) & 0x7fff);
    const payload_len: u32 = word2 & 0xffff;

    const payload = try alloc.alloc(u8, payload_len);
    errdefer alloc.free(payload);

    if (payload_len > 0) try read_exact(stream, payload);

    // Minimal logging for every received mux frame; do not affect behavior.
    if (mini_proto == 2) {
        if (readChainSyncTag(payload)) |msg_id| {
            std.debug.print("🔎 Mux recv: miniProto={d} mode={s} len={d} cbor0={d}\n", .{
                mini_proto,
                if (initiator_mode) "initiator" else "responder",
                payload_len,
                msg_id,
            });
        } else {
            std.debug.print("🔎 Mux recv: miniProto={d} mode={s} len={d} cbor0=?\n", .{
                mini_proto,
                if (initiator_mode) "initiator" else "responder",
                payload_len,
            });
        }
    } else {
        std.debug.print("🔎 Mux recv: miniProto={d} mode={s} len={d}\n", .{
            mini_proto,
            if (initiator_mode) "initiator" else "responder",
            payload_len,
        });
    }

    return .{
        .initiator_mode = initiator_mode,
        .mini_proto = mini_proto,
        .payload_len = payload_len,
        .payload = payload,
    };
}

fn muxReadOneChainSync(alloc: std.mem.Allocator, stream: *std.net.Stream) !MuxMsg {
    while (true) {
        if (g_stop.load(.seq_cst)) {
            std.debug.print("🛑 Demux interrupted by shutdown signal\n", .{});
            return error.Interrupted;
        }
        const msg = try muxReadOne(alloc, stream);
        if (msg.mini_proto == 2 and !msg.initiator_mode) return msg;
        std.debug.print("↪️  Ignored mux frame: miniProto={d} mode={s} len={d}\n", .{
            msg.mini_proto,
            if (msg.initiator_mode) "initiator" else "responder",
            msg.payload_len,
        });
        alloc.free(msg.payload);
    }
}

fn read_exact(stream: *std.net.Stream, out: []u8) !void {
    var n: usize = 0;
    while (n < out.len) {
        if (g_stop.load(.seq_cst)) return error.Interrupted;
        const got = stream.reader().read(out[n..]) catch |err| {
            switch (err) {
                error.WouldBlock => continue,
                else => return err,
            }
        };
        if (got == 0) return error.ConnectionResetByPeer;
        n += got;
    }
}

fn hexdump(bytes: []const u8) void {
    var i: usize = 0;
    while (i < bytes.len) : (i += 16) {
        const end = @min(i + 16, bytes.len);
        std.debug.print("{x:0>4}: ", .{i});
        var j: usize = i;
        while (j < end) : (j += 1) std.debug.print("{x:0>2} ", .{bytes[j]});
        std.debug.print("\n", .{});
    }
}

fn ensureRepoRoot() !void {
    std.fs.cwd().access("build.zig", .{}) catch return error.NotRepoRoot;
}

fn runSetupWizard(alloc: std.mem.Allocator, lang: Lang, default_host: []const u8, default_port: u16) !Config {
    const stdin = std.io.getStdIn().reader();
    const stdout = std.io.getStdOut().writer();

    const default_network = "preview";
    var network = default_network;
    var host = default_host;
    var port = default_port;
    var pulse = false;

    try printPrompt(stdout, lang, "ネットワーク (preview/preprod) [preview]: ", "Network (preview/preprod) [preview]: ");
    if (try readLineAlloc(alloc, stdin)) |line| {
        defer alloc.free(line);
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len > 0) {
            if (std.mem.eql(u8, trimmed, "preprod")) network = "preprod" else network = "preview";
        }
    }

    try printPrompt(stdout, lang, "ホスト [preview-node.world.dev.cardano.org]: ", "Host [preview-node.world.dev.cardano.org]: ");
    if (try readLineAlloc(alloc, stdin)) |line| {
        defer alloc.free(line);
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len > 0) host = try alloc.dupe(u8, trimmed);
    }

    try printPrompt(stdout, lang, "ポート [30002]: ", "Port [30002]: ");
    if (try readLineAlloc(alloc, stdin)) |line| {
        defer alloc.free(line);
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len > 0) port = try std.fmt.parseInt(u16, trimmed, 10);
    }

    try printPrompt(stdout, lang, "パルス表示を有効にしますか? (y/N): ", "Enable pulse output? (y/N): ");
    if (try readLineAlloc(alloc, stdin)) |line| {
        defer alloc.free(line);
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len > 0) pulse = parseBool(trimmed) orelse false;
    }

    return .{
        .network = network,
        .host = host,
        .port = port,
        .pulse = pulse,
    };
}

fn writeConfigFile(alloc: std.mem.Allocator, cfg: Config) !void {
    _ = alloc;
    var file = try std.fs.cwd().createFile("tsunagi.toml", .{ .truncate = true });
    defer file.close();
    const w = file.writer();
    try w.print("network = \"{s}\"\n", .{cfg.network});
    try w.print("host = \"{s}\"\n", .{cfg.host});
    try w.print("port = {d}\n", .{cfg.port});
    try w.print("pulse = {s}\n", .{if (cfg.pulse) "true" else "false"});
}

fn readConfigFile(alloc: std.mem.Allocator) ?Config {
    var file = std.fs.cwd().openFile("tsunagi.toml", .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return null,
    };
    defer file.close();

    const data = file.readToEndAlloc(alloc, 64 * 1024) catch return null;
    defer alloc.free(data);

    var cfg = Config{
        .network = "preview",
        .host = "preview-node.world.dev.cardano.org",
        .port = 30002,
        .pulse = false,
    };

    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r\n");
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "#")) continue;
        const eq_idx = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq_idx], " \t\r\n");
        const val_raw = std.mem.trim(u8, line[eq_idx + 1 ..], " \t\r\n");
        if (std.mem.eql(u8, key, "network")) {
            if (parseString(val_raw)) |s| cfg.network = alloc.dupe(u8, s) catch cfg.network;
        } else if (std.mem.eql(u8, key, "host")) {
            if (parseString(val_raw)) |s| cfg.host = alloc.dupe(u8, s) catch cfg.host;
        } else if (std.mem.eql(u8, key, "port")) {
            cfg.port = std.fmt.parseInt(u16, val_raw, 10) catch cfg.port;
        } else if (std.mem.eql(u8, key, "pulse")) {
            if (parseBool(val_raw)) |b| cfg.pulse = b;
        }
    }
    return cfg;
}

fn parseString(val: []const u8) ?[]const u8 {
    if (val.len >= 2 and val[0] == '"' and val[val.len - 1] == '"') {
        return val[1 .. val.len - 1];
    }
    return null;
}

fn parseBool(val: []const u8) ?bool {
    if (std.mem.eql(u8, val, "true") or std.mem.eql(u8, val, "yes") or std.mem.eql(u8, val, "y") or std.mem.eql(u8, val, "1")) return true;
    if (std.mem.eql(u8, val, "false") or std.mem.eql(u8, val, "no") or std.mem.eql(u8, val, "n") or std.mem.eql(u8, val, "0")) return false;
    return null;
}

fn printPrompt(w: anytype, lang: Lang, jp: []const u8, en: []const u8) !void {
    if (lang == .jp) {
        try w.writeAll(jp);
    } else {
        try w.writeAll(en);
    }
}

fn readLineAlloc(alloc: std.mem.Allocator, r: anytype) !?[]u8 {
    return r.readUntilDelimiterOrEofAlloc(alloc, '\n', 1024);
}

fn readFirstCborInt(payload: []const u8) ?i64 {
    if (payload.len == 0) return null;
    const b0: u8 = payload[0];
    const major: u8 = b0 >> 5;
    const addl: u8 = b0 & 0x1f;
    if (major != 0 and major != 1) return null;

    var val_u64: u64 = 0;
    if (addl < 24) {
        val_u64 = addl;
    } else if (addl == 24) {
        if (payload.len < 2) return null;
        val_u64 = payload[1];
    } else if (addl == 25) {
        if (payload.len < 3) return null;
        val_u64 = std.mem.readInt(u16, payload[1..3], .big);
    } else if (addl == 26) {
        if (payload.len < 5) return null;
        val_u64 = std.mem.readInt(u32, payload[1..5], .big);
    } else if (addl == 27) {
        if (payload.len < 9) return null;
        val_u64 = std.mem.readInt(u64, payload[1..9], .big);
    } else {
        return null;
    }

    if (major == 0) return @intCast(val_u64);
    // major 1 => negative integer: -1 - val
    return -1 - @as(i64, @intCast(val_u64));
}

fn readChainSyncTag(payload: []const u8) ?i64 {
    var idx: usize = 0;
    const top = readCborHead(payload, idx) orelse return null;
    if (top.major != 4 or top.val < 1) return null;
    idx += top.hdr_len;
    const tag_h = readCborHead(payload, idx) orelse return null;
    if (tag_h.major == 0) return @intCast(tag_h.val);
    if (tag_h.major == 1) return -1 - @as(i64, @intCast(tag_h.val));
    return null;
}

const CborHead = struct {
    major: u8,
    val: u64,
    hdr_len: usize,
};

fn readCborHead(payload: []const u8, idx: usize) ?CborHead {
    if (idx >= payload.len) return null;
    const b0: u8 = payload[idx];
    const major: u8 = b0 >> 5;
    const addl: u8 = b0 & 0x1f;
    if (addl < 24) return .{ .major = major, .val = addl, .hdr_len = 1 };
    if (addl == 24) {
        if (idx + 1 >= payload.len) return null;
        return .{ .major = major, .val = payload[idx + 1], .hdr_len = 2 };
    }
    if (addl == 25) {
        if (idx + 2 >= payload.len) return null;
        const slice = payload[idx + 1 .. idx + 3];
        const p: *const [2]u8 = @ptrCast(slice.ptr);
        const v = std.mem.readInt(u16, p, .big);
        return .{ .major = major, .val = v, .hdr_len = 3 };
    }
    if (addl == 26) {
        if (idx + 4 >= payload.len) return null;
        const slice = payload[idx + 1 .. idx + 5];
        const p: *const [4]u8 = @ptrCast(slice.ptr);
        const v = std.mem.readInt(u32, p, .big);
        return .{ .major = major, .val = v, .hdr_len = 5 };
    }
    if (addl == 27) {
        if (idx + 8 >= payload.len) return null;
        const slice = payload[idx + 1 .. idx + 9];
        const p: *const [8]u8 = @ptrCast(slice.ptr);
        const v = std.mem.readInt(u64, p, .big);
        return .{ .major = major, .val = v, .hdr_len = 9 };
    }
    return null;
}

fn validatePointAt(payload: []const u8, idx: usize) ?usize {
    const h = readCborHead(payload, idx) orelse return null;
    if (h.major != 4 or h.val != 2) return null;
    var i = idx + h.hdr_len;
    const slot_h = readCborHead(payload, i) orelse return null;
    if (slot_h.major != 0) return null;
    i += slot_h.hdr_len;
    const hash_h = readCborHead(payload, i) orelse return null;
    if (hash_h.major != 2 or hash_h.val != 32) return null;
    i += hash_h.hdr_len + 32;
    if (i > payload.len) return null;
    return i;
}

fn validateIntersectFoundPoint(payload: []const u8) bool {
    var idx: usize = 0;
    const top = readCborHead(payload, idx) orelse return false;
    if (top.major != 4 or top.val < 2) return false;
    idx += top.hdr_len;
    const tag_h = readCborHead(payload, idx) orelse return false;
    if (tag_h.major != 0 or tag_h.val != 5) return false;
    idx += tag_h.hdr_len;

    // Handle [6, point, tip] or [6, [point, tip]]
    if (top.val == 2) {
        const inner = readCborHead(payload, idx) orelse return false;
        if (inner.major != 4 or inner.val < 1) return false;
        idx += inner.hdr_len;
        return validatePointAt(payload, idx) != null;
    }
    return validatePointAt(payload, idx) != null;
}

const PointInfo = struct {
    slot: u64,
    hash: [32]u8,
};

fn makeOriginPoint() PointInfo {
    return .{ .slot = 0, .hash = [_]u8{0} ** 32 };
}

fn parseIntersectNotFoundTipPoint(payload: []const u8) ?PointInfo {
    var idx: usize = 0;
    const top = readCborHead(payload, idx) orelse return null;
    if (top.major != 4 or top.val < 2) return null;
    idx += top.hdr_len;
    const tag_h = readCborHead(payload, idx) orelse return null;
    if (tag_h.major != 0 or tag_h.val != 6) return null;
    idx += tag_h.hdr_len;

    if (parsePointAt(payload, idx)) |res| return res.point;
    const tip_h = readCborHead(payload, idx) orelse return null;
    if (tip_h.major != 4) return null;
    idx += tip_h.hdr_len;
    var n: u64 = 0;
    while (n < tip_h.val) : (n += 1) {
        if (parsePointAt(payload, idx)) |res| return res.point;
        idx = skipCborItem(payload, idx) orelse return null;
    }
    return null;
}

fn parsePointAt(payload: []const u8, idx: usize) ?struct { next: usize, point: PointInfo } {
    const h = readCborHead(payload, idx) orelse return null;
    if (h.major != 4 or h.val != 2) return null;
    var i = idx + h.hdr_len;
    const slot_h = readCborHead(payload, i) orelse return null;
    if (slot_h.major != 0) return null;
    const slot = slot_h.val;
    i += slot_h.hdr_len;
    const hash_h = readCborHead(payload, i) orelse return null;
    if (hash_h.major != 2 or hash_h.val != 32) return null;
    i += hash_h.hdr_len;
    if (i + 32 > payload.len) return null;
    var hash: [32]u8 = undefined;
    @memcpy(hash[0..], payload[i .. i + 32]);
    i += 32;
    return .{ .next = i, .point = .{ .slot = slot, .hash = hash } };
}

fn buildChainSyncFindIntersectWithPoints(alloc: std.mem.Allocator, points: []const PointInfo) ![]u8 {
    var a = std.ArrayList(u8).init(alloc);
    errdefer a.deinit();
    const w = a.writer();
    try cbor.Cbor.writeArrayLen(w, 2);
    try cbor.Cbor.writeUInt(w, 4);
    try cbor.Cbor.writeArrayLen(w, points.len);
    for (points) |p| {
        try cbor.Cbor.writeArrayLen(w, 2);
        try cbor.Cbor.writeUInt(w, p.slot);
        try cbor.Cbor.writeBytes(w, &p.hash);
    }
    return a.toOwnedSlice();
}

fn skipCborItem(payload: []const u8, idx: usize) ?usize {
    const h = readCborHead(payload, idx) orelse return null;
    var i = idx + h.hdr_len;
    switch (h.major) {
        0, 1 => return i,
        2, 3 => {
            const end = i + @as(usize, @intCast(h.val));
            if (end > payload.len) return null;
            return end;
        },
        4 => {
            var n: u64 = 0;
            while (n < h.val) : (n += 1) {
                i = skipCborItem(payload, i) orelse return null;
            }
            return i;
        },
        5 => {
            var n: u64 = 0;
            while (n < h.val * 2) : (n += 1) {
                i = skipCborItem(payload, i) orelse return null;
            }
            return i;
        },
        else => return null,
    }
}

fn scanForPoint(payload: []const u8, idx: usize) ?PointInfo {
    if (parsePointAt(payload, idx)) |res| return res.point;
    const h = readCborHead(payload, idx) orelse return null;
    var i = idx + h.hdr_len;
    switch (h.major) {
        4 => {
            var n: u64 = 0;
            while (n < h.val) : (n += 1) {
                if (scanForPoint(payload, i)) |p| return p;
                i = skipCborItem(payload, i) orelse return null;
            }
        },
        5 => {
            var n: u64 = 0;
            while (n < h.val * 2) : (n += 1) {
                if (scanForPoint(payload, i)) |p| return p;
                i = skipCborItem(payload, i) orelse return null;
            }
        },
        else => {},
    }
    return null;
}

fn hexNibble(n: u8) u8 {
    return if (n < 10) n + '0' else (n - 10) + 'a';
}

fn shortHashHex(hash: [32]u8, out: []u8) []const u8 {
    var i: usize = 0;
    var o: usize = 0;
    while (i < 6 and o + 1 < out.len) : (i += 1) {
        const b = hash[i];
        out[o] = hexNibble(b >> 4);
        out[o + 1] = hexNibble(b & 0x0f);
        o += 2;
    }
    return out[0..o];
}

fn pulseRollForward(payload: []const u8, last_roll_ms: *?i64, last_roll_slot: *?u64) void {
    const p = scanForPoint(payload, 0) orelse {
        std.debug.print("▶️ RollForward\n", .{});
        return;
    };
    var hash_buf: [12]u8 = undefined;
    const hash_short = shortHashHex(p.hash, &hash_buf);
    const now = std.time.milliTimestamp();
    if (last_roll_ms.*) |prev| {
        const delta = now - prev;
        std.debug.print("▶️ RollForward slot={d} hash={s} Δ{d}ms\n", .{ p.slot, hash_short, delta });
    } else {
        std.debug.print("▶️ RollForward slot={d} hash={s}\n", .{ p.slot, hash_short });
    }
    last_roll_ms.* = now;
    last_roll_slot.* = p.slot;
}

fn pulseRollBackward(payload: []const u8, last_roll_slot: ?u64) void {
    const p = scanForPoint(payload, 0) orelse {
        std.debug.print("⏪ RollBackward\n", .{});
        return;
    };
    if (last_roll_slot) |prev| {
        if (prev >= p.slot) {
            const depth = prev - p.slot;
            std.debug.print("⏪ RollBackward slot={d} depth={d}\n", .{ p.slot, depth });
            return;
        }
    }
    std.debug.print("⏪ RollBackward slot={d}\n", .{ p.slot });
}

// ===== minimal CBOR builders (hardcoded for now) =====
fn buildHandshakeProposeV14(alloc: std.mem.Allocator) ![]u8 {
    // [0, {14: [2, true, 0, true]}]
    var a = std.ArrayList(u8).init(alloc);
    errdefer a.deinit();
    try a.appendSlice(&.{ 0x82, 0x00, 0xA1, 0x0E, 0x84, 0x02, 0xF4, 0x00, 0xF4 });
    return a.toOwnedSlice();
}

fn buildChainSyncRequestNext(alloc: std.mem.Allocator) ![]u8 {
    // msgRequestNext = [0] :contentReference[oaicite:10]{index=10}
    var a = std.ArrayList(u8).init(alloc);
    errdefer a.deinit();
    try a.appendSlice(&.{ 0x81, 0x00 });
    return a.toOwnedSlice();
}
