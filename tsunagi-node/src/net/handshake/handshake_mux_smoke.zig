const std = @import("std");

const cbor = @import("../cbor/term.zig");
const handshake_codec = @import("handshake_codec.zig");
const mux_bearer = @import("../muxwire/mux_bearer.zig");
const mux_header = @import("../muxwire/mux_header.zig");
const tcp_bt = @import("../transport/tcp_byte_transport.zig");

fn printIndent(indent: usize) void {
    var i: usize = 0;
    while (i < indent) : (i += 1) {
        std.debug.print("  ", .{});
    }
}

fn printTermPretty(term: cbor.Term, indent: usize) void {
    switch (term) {
        .u64 => |v| std.debug.print("{d}\n", .{v}),
        .i64 => |v| std.debug.print("{d}\n", .{v}),
        .bool => |v| std.debug.print("{s}\n", .{if (v) "true" else "false"}),
        .text => |t| std.debug.print("{s}\n", .{t}),
        .bytes => |b| std.debug.print("0x{s}\n", .{std.fmt.fmtSliceHexLower(b)}),
        .array => |items| {
            std.debug.print("[\n", .{});
            for (items) |item| {
                printIndent(indent + 1);
                printTermPretty(item, indent + 1);
            }
            printIndent(indent);
            std.debug.print("]\n", .{});
        },
        .map_u64 => |entries| {
            std.debug.print("{{\n", .{});
            for (entries) |entry| {
                printIndent(indent + 1);
                std.debug.print("{d}: ", .{entry.key});
                printTermPretty(entry.value, indent + 1);
            }
            printIndent(indent);
            std.debug.print("}}\n", .{});
        },
    }
}

pub fn run(alloc: std.mem.Allocator, host: []const u8, port: u16) !void {
    var bt = try tcp_bt.connect(alloc, host, port);
    defer bt.deinit();

    const timeout_ms: u32 = 1000;
    tcp_bt.setReadTimeout(&bt, timeout_ms) catch {};

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
            std.debug.print("handshake-mux-smoke: refused:\n", .{});
            printIndent(1);
            printTermPretty(r.reason, 1);
        },
        .propose => std.debug.print("handshake-mux-smoke: unexpected propose\n", .{}),
    }
}
