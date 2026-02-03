const std = @import("std");

const cbor = @import("../cbor/term.zig");
const chainsync_codec = @import("chainsync_codec.zig");
const handshake_codec = @import("../handshake/handshake_codec.zig");
const mux_bearer = @import("../muxwire/mux_bearer.zig");
const bt_boundary = @import("../transport/byte_transport.zig");
const tcp_bt = @import("../transport/tcp_byte_transport.zig");

const chainsync_proto: u16 = 2;

fn doHandshake(alloc: std.mem.Allocator, bt: *bt_boundary.ByteTransport) !bool {
    var version_items = try alloc.alloc(cbor.Term, 4);
    version_items[0] = .{ .u64 = 2 };
    version_items[1] = .{ .bool = false };
    version_items[2] = .{ .u64 = 1 };
    version_items[3] = .{ .bool = false };
    const version_data = cbor.Term{ .array = version_items };

    var entries = try alloc.alloc(cbor.MapEntry, 1);
    entries[0] = .{ .key = 14, .value = version_data };
    var propose = handshake_codec.HandshakeMsg{
        .propose = .{ .versions = .{ .map_u64 = entries } },
    };
    defer handshake_codec.free(alloc, &propose);

    var payload_list = std.ArrayList(u8).init(alloc);
    defer payload_list.deinit();
    try handshake_codec.encodeMsg(propose, payload_list.writer());
    const payload = try payload_list.toOwnedSlice();
    defer alloc.free(payload);

    try mux_bearer.sendSegment(bt, .initiator, 0, payload);

    const seg = try mux_bearer.recvSegment(alloc, bt);
    if (seg == null) return false;
    defer alloc.free(seg.?.payload);

    var fbs = std.io.fixedBufferStream(seg.?.payload);
    var msg = handshake_codec.decodeMsg(alloc, fbs.reader()) catch return false;
    defer handshake_codec.free(alloc, &msg);

    return msg == .accept;
}

pub fn run(alloc: std.mem.Allocator, host: []const u8, port: u16) !void {
    var bt = try tcp_bt.connect(alloc, host, port);
    defer bt.deinit();

    const timeout_ms: u32 = 1000;
    tcp_bt.setReadTimeout(&bt, timeout_ms) catch {};

    const accepted = try doHandshake(alloc, &bt);
    if (!accepted) {
        std.debug.print("chainsync: no response\n", .{});
        return;
    }

    const empty_points = cbor.Term{ .array = @constCast((&[_]cbor.Term{})[0..]) };
    var list = std.ArrayList(u8).init(alloc);
    defer list.deinit();
    try chainsync_codec.encodeFindIntersect(list.writer(), empty_points);
    const msg_bytes = try list.toOwnedSlice();
    defer alloc.free(msg_bytes);

    try mux_bearer.sendSegment(&bt, .initiator, chainsync_proto, msg_bytes);

    const seg = try mux_bearer.recvSegment(alloc, &bt);
    if (seg == null) {
        std.debug.print("chainsync: no response\n", .{});
        return;
    }
    defer alloc.free(seg.?.payload);

    var fbs = std.io.fixedBufferStream(seg.?.payload);
    var msg = try chainsync_codec.decodeResponse(alloc, fbs.reader());
    defer chainsync_codec.free(alloc, &msg);

    switch (msg) {
        .intersect_found => std.debug.print("chainsync: intersect found\n", .{}),
        .intersect_not_found => std.debug.print("chainsync: intersect not found\n", .{}),
        else => std.debug.print("chainsync: no response\n", .{}),
    }
}
