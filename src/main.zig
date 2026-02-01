const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const default_host = "preview-node.world.dev.cardano.org";
    const default_port: u16 = 30002;

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    const host = if (args.len >= 2) args[1] else default_host;
    const port: u16 = if (args.len >= 3) try std.fmt.parseInt(u16, args[2], 10) else default_port;

    std.debug.print("🌸 Tsunagi Follower v0.5b: Handshake v14 (real mux header)\n", .{});
    std.debug.print("接続先: {s}:{d}\n\n", .{ host, port });

    const address_list = try std.net.getAddressList(alloc, host, port);
    defer address_list.deinit();

    var stream_opt: ?std.net.Stream = null;
    for (address_list.addrs) |addr| {
        std.debug.print("試行: {any}\n", .{addr});
        stream_opt = std.net.tcpConnectToAddress(addr) catch continue;
        break;
    }
    if (stream_opt == null) return error.ConnectionFailed;

    var stream = stream_opt.?;
    defer stream.close();

    std.debug.print("✅ TCP 接続成功\n", .{});

    // Build CBOR: [0, { 14: [magic, diffusion, peerSharing, query] }]
    // preview magic = 2
    const version: u32 = 14;

    var payload = std.ArrayList(u8).init(alloc);
    defer payload.deinit();

    try cbor_array_start(&payload, 2);
    try cbor_uint(&payload, 0);
    try cbor_map_start(&payload, 1);
    try cbor_uint(&payload, version);
    try cbor_array_start(&payload, 4);
    try cbor_uint(&payload, 2);        // networkMagic preview
    try cbor_bool(&payload, false);    // diffusionMode
    try cbor_uint(&payload, 0);        // peerSharing off
    try cbor_bool(&payload, false);    // query false

    std.debug.print("\n📦 ProposeVersions payload: {d} bytes\n", .{payload.items.len});
    hex_dump(payload.items);

    // Wrap using real mux codec header (8 bytes):
    // u32 timestamp + u32 (dir|miniProto|len) big-endian
    const sdu = try muxEncode(alloc, true, 0, payload.items);
    defer alloc.free(sdu);

    std.debug.print("\n📨 mux SDU送信: {d} bytes (header+payload)\n", .{sdu.len});
    hex_dump(sdu[0..@min(sdu.len, 64)]);

    try stream.writer().writeAll(sdu);
    std.debug.print("✅ 送信完了\n", .{});

    // Read response mux header (8 bytes)
    var hdr: [8]u8 = undefined;
    try read_exact(&stream, &hdr);

    const mh = muxDecodeHeader(hdr);
    std.debug.print("\n📥 mux header: initiator={s} miniProto={d} payloadLen={d}\n",
        .{ if (mh.initiator) "true" else "false", mh.mini_proto, mh.payload_len });

    const resp_payload = try alloc.alloc(u8, mh.payload_len);
    defer alloc.free(resp_payload);
    try read_exact(&stream, resp_payload);

    std.debug.print("\n📥 payload: {d} bytes\n", .{resp_payload.len});
    hex_dump(resp_payload);

    // Quick decode: [tag, ...]
    var it = CborIter{ .buf = resp_payload, .i = 0 };
    _ = try it.readArrayLen();
    const tag = try it.readUint();

    if (tag == 1) {
        const acc_ver = try it.readUint();
        std.debug.print("\n🎉 Handshake ACCEPT! version={d}\n", .{acc_ver});
    } else if (tag == 2) {
        std.debug.print("\n🙏 Handshake REFUSE\n", .{});
        // If it's VersionMismatch, peer usually returns [2, [0, [..versions..]]]
        const rr_len = try it.readArrayLen();
        if (rr_len >= 2) {
            const reason_tag = try it.readUint();
            if (reason_tag == 0) {
                const list_len = try it.readArrayLen();
                std.debug.print("  理由: VersionMismatch / 相手versions({d}): ", .{list_len});
                var k: usize = 0;
                while (k < list_len) : (k += 1) {
                    const v = try it.readUint();
                    if (k + 1 == list_len) std.debug.print("{d}\n", .{v}) else std.debug.print("{d}, ", .{v});
                }
            }
        }
    } else {
        std.debug.print("\n⚠️ 不明メッセージ tag={d}\n", .{tag});
    }
}

// -------- real mux codec header (the one you had working in v0.4) --------
const MuxHeader = struct {
    initiator: bool,
    mini_proto: u16,
    payload_len: u32,
};

fn muxEncode(alloc: std.mem.Allocator, initiator: bool, miniProto: u16, payload: []const u8) ![]u8 {
    if (payload.len > 0xffff) return error.PayloadTooLarge;

    const micros_i64 = std.time.microTimestamp();
    const micros_u32: u32 = @truncate(@as(u64, @intCast(micros_i64)));

    const dir_bit: u32 = if (initiator) 1 else 0;     // 1=initiator
    const mp: u32 = @as(u32, miniProto) & 0x7fff;     // 15-bit
    const len: u32 = @as(u32, @intCast(payload.len)) & 0xffff; // 16-bit

    const word2: u32 = (dir_bit << 31) | (mp << 16) | len;

    var out = try alloc.alloc(u8, 8 + payload.len);
    std.mem.writeInt(u32, out[0..4], micros_u32, .big);
    std.mem.writeInt(u32, out[4..8], word2, .big);
    @memcpy(out[8..], payload);

    return out;
}

fn muxDecodeHeader(hdr: [8]u8) MuxHeader {
    const word2: u32 = std.mem.readInt(u32, hdr[4..8], .big);
    const initiator = ((word2 >> 31) & 1) == 1;
    const mini_proto: u16 = @intCast((word2 >> 16) & 0x7fff);
    const payload_len: u32 = word2 & 0xffff;
    return .{ .initiator = initiator, .mini_proto = mini_proto, .payload_len = payload_len };
}

// -------- IO --------
fn read_exact(stream: *std.net.Stream, out: []u8) !void {
    var n: usize = 0;
    while (n < out.len) {
        const got = try stream.reader().read(out[n..]);
        if (got == 0) return error.ConnectionResetByPeer;
        n += got;
    }
}

fn hex_dump(bytes: []const u8) void {
    var i: usize = 0;
    while (i < bytes.len) : (i += 16) {
        const line = bytes[i..@min(i + 16, bytes.len)];
        std.debug.print("{x:0>4}: ", .{i});
        for (line) |b| std.debug.print("{x:0>2} ", .{b});
        std.debug.print("\n", .{});
    }
}

// -------- tiny CBOR encoder (enough for our handshake messages) --------
fn cbor_uint(out: *std.ArrayList(u8), v: anytype) !void {
    const x: u64 = @intCast(v);
    if (x <= 23) {
        try out.append(@intCast(0x00 | x));
    } else if (x <= 0xff) {
        try out.append(0x18);
        try out.append(@intCast(x));
    } else if (x <= 0xffff) {
        try out.append(0x19);
        try out.append(@intCast((x >> 8) & 0xff));
        try out.append(@intCast(x & 0xff));
    } else if (x <= 0xffff_ffff) {
        try out.append(0x1a);
        try out.append(@intCast((x >> 24) & 0xff));
        try out.append(@intCast((x >> 16) & 0xff));
        try out.append(@intCast((x >> 8) & 0xff));
        try out.append(@intCast(x & 0xff));
    } else return error.CborTooLarge;
}

fn cbor_bool(out: *std.ArrayList(u8), b: bool) !void {
    try out.append(if (b) 0xf5 else 0xf4);
}

fn cbor_array_start(out: *std.ArrayList(u8), len: usize) !void {
    if (len > 23) return error.CborTooLarge;
    try out.append(@intCast(0x80 | len));
}

fn cbor_map_start(out: *std.ArrayList(u8), len: usize) !void {
    if (len > 23) return error.CborTooLarge;
    try out.append(@intCast(0xa0 | len));
}

// -------- tiny CBOR decoder (enough for accept/refuse) --------
const CborIter = struct {
    buf: []const u8,
    i: usize,

    fn need(self: *CborIter, n: usize) !void {
        if (self.i + n > self.buf.len) return error.CborEof;
    }

    fn readByte(self: *CborIter) !u8 {
        try self.need(1);
        const b = self.buf[self.i];
        self.i += 1;
        return b;
    }

    fn readUint(self: *CborIter) !u64 {
        const b0 = try self.readByte();
        const major = b0 >> 5;
        const ai = b0 & 0x1f;
        if (major != 0) return error.CborExpectedUint;

        return switch (ai) {
            0...23 => ai,
            24 => blk: { const b = try self.readByte(); break :blk b; },
            25 => blk: {
                try self.need(2);
                const v = (@as(u64, self.buf[self.i]) << 8) | @as(u64, self.buf[self.i + 1]);
                self.i += 2;
                break :blk v;
            },
            26 => blk: {
                try self.need(4);
                const v =
                    (@as(u64, self.buf[self.i]) << 24) |
                    (@as(u64, self.buf[self.i + 1]) << 16) |
                    (@as(u64, self.buf[self.i + 2]) << 8) |
                    (@as(u64, self.buf[self.i + 3]) << 0);
                self.i += 4;
                break :blk v;
            },
            else => return error.CborUnsupportedUint,
        };
    }

    fn readArrayLen(self: *CborIter) !usize {
        const b0 = try self.readByte();
        const major = b0 >> 5;
        const ai = b0 & 0x1f;
        if (major != 4) return error.CborExpectedArray;
        if (ai > 23) return error.CborUnsupportedArray;
        return @intCast(ai);
    }
};
