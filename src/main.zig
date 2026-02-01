const std = @import("std");

// v0.6e: Fix mux Mode bit (M): 0=initiator, 1=responder.
// This is required by the spec; wrong M commonly causes ConnectionResetByPeer. (See spec 2.1.1) :contentReference[oaicite:1]{index=1}

var g_stop = std.atomic.Value(bool).init(false);

fn onSigint(sig: c_int) callconv(.C) void {
    _ = sig;
    g_stop.store(true, .seq_cst);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

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

    const host = if (args.len >= 2) args[1] else default_host;
    const port: u16 = if (args.len >= 3) try std.fmt.parseInt(u16, args[2], 10) else default_port;

    std.debug.print("🌸 Tsunagi Follower v0.6e: Handshake v14 + ChainSync FindIntersect(origin) -> RequestNext\n", .{});
    std.debug.print("Target: {s}:{d}\n\n", .{ host, port });

    // ---- TCP connect ----
    const address_list = try std.net.getAddressList(alloc, host, port);
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
    // We'll send points=[null] meaning "origin" (genesis).
    const find_payload = try buildChainSyncFindIntersectOrigin(alloc);
    defer alloc.free(find_payload);

    std.debug.print("\n📦 ChainSync FindIntersect payload: {d} bytes\n", .{find_payload.len});
    hexdump(find_payload);

    const find_sdu = try muxEncode(alloc, true, 2, find_payload);
    defer alloc.free(find_sdu);

    try stream.writer().writeAll(find_sdu);

    const find_resp = try muxReadOneChainSync(alloc, &stream);
    defer alloc.free(find_resp.payload);

    std.debug.print("\n📥 ChainSync resp: mode(initiator?)={any} miniProto={d} len={d}\n", .{
        find_resp.initiator_mode, find_resp.mini_proto, find_resp.payload_len
    });
    hexdump(find_resp.payload);

    // Validate ChainSync response framing and tag before requesting next.
    if (find_resp.mini_proto != 2 or find_resp.initiator_mode) return error.UnexpectedMuxFrame;
    const find_tag = readChainSyncTag(find_resp.payload) orelse return error.InvalidChainSyncMessage;
    if (find_tag == 6) {
        // MsgIntersectFound
        if (!validateIntersectFoundPoint(find_resp.payload)) return error.InvalidChainSyncMessage;
        var iter: usize = 0;
        const max_iters: usize = 100;
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
            const req_tag = readChainSyncTag(req_resp.payload) orelse return error.InvalidChainSyncMessage;
            if (req_tag != 3 and req_tag != 4) {
                std.debug.print("\n⚠️  Unexpected ChainSync tag after RequestNext: {d}\n", .{req_tag});
                return error.InvalidChainSyncMessage;
            }
        }
        if (g_stop.load(.seq_cst)) {
            std.debug.print("\n🛑 SIGINT received; stopping ChainSync loop\n", .{});
            return;
        }
    } else if (find_tag == 7) {
        // MsgIntersectNotFound
        std.debug.print("\n⚠️  Intersect not found; skipping RequestNext\n", .{});
        return;
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
        const got = try stream.reader().read(out[n..]);
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
    if (tag_h.major != 0 or tag_h.val != 6) return false;
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

// ===== minimal CBOR builders (hardcoded for now) =====
fn buildHandshakeProposeV14(alloc: std.mem.Allocator) ![]u8 {
    // [0, {14: [2, true, 0, true]}]
    var a = std.ArrayList(u8).init(alloc);
    errdefer a.deinit();
    try a.appendSlice(&.{ 0x82, 0x00, 0xA1, 0x0E, 0x84, 0x02, 0xF4, 0x00, 0xF4 });
    return a.toOwnedSlice();
}

fn buildChainSyncFindIntersectOrigin(alloc: std.mem.Allocator) ![]u8 {
    // msgFindIntersect = [4, base.points] :contentReference[oaicite:9]{index=9}
    // points = [[slot, hash]] with slot=0 and 32-byte header hash
    var a = std.ArrayList(u8).init(alloc);
    errdefer a.deinit();
    try a.appendSlice(&.{
        0x82, 0x04, // [4, ...]
        0x81, // points list (len=1)
        0x82, // point array (len=2)
        0x00, // slot = 0
        0x58, 0x20, // bytes (32)
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    }); // [4, [[0, h32]]]
    return a.toOwnedSlice();
}

fn buildChainSyncRequestNext(alloc: std.mem.Allocator) ![]u8 {
    // msgRequestNext = [0] :contentReference[oaicite:10]{index=10}
    var a = std.ArrayList(u8).init(alloc);
    errdefer a.deinit();
    try a.appendSlice(&.{ 0x81, 0x00 });
    return a.toOwnedSlice();
}
