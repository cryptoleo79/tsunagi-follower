const std = @import("std");

const cbor = @import("../cbor/term.zig");
const handshake_codec = @import("handshake_codec.zig");
const mux_bearer = @import("../muxwire/mux_bearer.zig");
const mux_header = @import("../muxwire/mux_header.zig");
const tcp_bt = @import("../transport/tcp_byte_transport.zig");

fn printTerm(term: cbor.Term) void {
    switch (term) {
        .u64 => |v| std.debug.print("{d}", .{v}),
        .text => |t| std.debug.print("{s}", .{t}),
        .bytes => |b| std.debug.print("0x{s}", .{std.fmt.fmtSliceHexLower(b)}),
        .array => |items| std.debug.print("<array:{d}>", .{items.len}),
        .map_u64 => |entries| std.debug.print("<map:{d}>", .{entries.len}),
    }
}

pub fn run(alloc: std.mem.Allocator, host: []const u8, port: u16) !void {
    var bt = try tcp_bt.connect(alloc, host, port);
    defer bt.deinit();

    const timeout_ms: u32 = 1000;
    tcp_bt.setReadTimeout(&bt, timeout_ms) catch {};

    var entries = try alloc.alloc(cbor.MapEntry, 1);
    entries[0] = .{ .key = 14, .value = .{ .u64 = 0 } };
    var propose = handshake_codec.HandshakeMsg{
        .propose = .{ .versions = .{ .map_u64 = entries } },
    };
    defer handshake_codec.free(alloc, &propose);

    var payload_list = std.ArrayList(u8).init(alloc);
    defer payload_list.deinit();
    try handshake_codec.encodeMsg(propose, payload_list.writer());
    const payload = try payload_list.toOwnedSlice();
    defer alloc.free(payload);

    try mux_bearer.sendSegment(&bt, .initiator, 0, payload);

    const seg = try mux_bearer.recvSegment(alloc, &bt);
    if (seg == null) {
        std.debug.print("handshake-mux-smoke: no response\n", .{});
        return;
    }
    defer alloc.free(seg.?.payload);

    const hdr = seg.?.hdr;
    std.debug.print(
        "handshake-mux-smoke: hdr dir={s} proto={d} len={d}\n",
        .{ @tagName(hdr.dir), hdr.proto, hdr.len },
    );

    var fbs = std.io.fixedBufferStream(seg.?.payload);
    var msg = handshake_codec.decodeMsg(alloc, fbs.reader()) catch |err| {
        std.debug.print("handshake-mux-smoke: decode error: {s}\n", .{@errorName(err)});
        return;
    };
    defer handshake_codec.free(alloc, &msg);

    switch (msg) {
        .accept => |a| std.debug.print("handshake-mux-smoke: accept version {d}\n", .{a.version}),
        .refuse => |r| {
            std.debug.print("handshake-mux-smoke: refused: ", .{});
            printTerm(r.reason);
            std.debug.print("\n", .{});
        },
        .propose => std.debug.print("handshake-mux-smoke: unexpected propose\n", .{}),
    }
}
