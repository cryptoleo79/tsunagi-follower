const std = @import("std");

const cbor = @import("../cbor/term.zig");
const framing = @import("../framing/length_prefix.zig");
const handshake_codec = @import("handshake_codec.zig");
const tcp_bt = @import("../transport/tcp_byte_transport.zig");

fn printTerm(term: cbor.Term) void {
    switch (term) {
        .u64 => |v| std.debug.print("{d}", .{v}),
        .i64 => |v| std.debug.print("{d}", .{v}),
        .bool => |v| std.debug.print("{s}", .{if (v) "true" else "false"}),
        .text => |t| std.debug.print("{s}", .{t}),
        .bytes => |b| std.debug.print("0x{s}", .{std.fmt.fmtSliceHexLower(b)}),
        .array => |items| std.debug.print("<array:{d}>", .{items.len}),
        .map_u64 => |entries| std.debug.print("<map:{d}>", .{entries.len}),
    }
}

pub fn run(alloc: std.mem.Allocator, host: []const u8, port: u16) !void {
    var bt = try tcp_bt.connect(alloc, host, port);
    defer bt.deinit();
    std.debug.print("handshake-smoke: TCP connected {s}:{d}\n", .{ host, port });

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

    const frame = try framing.encode(alloc, payload);
    defer alloc.free(frame);

    try bt.writeAll(frame);
    std.debug.print("handshake-smoke: sent {d} bytes\n", .{frame.len});

    var buf: [4096]u8 = undefined;
    const n = bt.readAtMost(&buf) catch |err| switch (err) {
        error.EndOfStream,
        error.ConnectionResetByPeer,
        error.ConnectionAborted,
        error.ConnectionTimedOut,
        error.BrokenPipe,
        error.WouldBlock,
        => {
            if (err == error.ConnectionTimedOut or err == error.WouldBlock) {
                std.debug.print("handshake-smoke: timed out after {d}ms\n", .{timeout_ms});
            } else {
                std.debug.print("handshake-smoke: peer closed\n", .{});
            }
            return;
        },
        else => return err,
    };

    if (n == 0) {
        std.debug.print("handshake-smoke: peer closed\n", .{});
        return;
    }

    const res = framing.decode(buf[0..n]) catch |err| switch (err) {
        framing.FrameError.IncompleteHeader,
        framing.FrameError.IncompletePayload,
        => {
            std.debug.print("handshake-smoke: no response\n", .{});
            return;
        },
        else => return err,
    };

    if (res == null) {
        std.debug.print("handshake-smoke: no response\n", .{});
        return;
    }

    var fbs = std.io.fixedBufferStream(res.?.payload);
    var msg = handshake_codec.decodeMsg(alloc, fbs.reader()) catch |err| {
        std.debug.print("handshake-smoke: decode error: {s}\n", .{@errorName(err)});
        return;
    };
    defer handshake_codec.free(alloc, &msg);

    switch (msg) {
        .accept => |a| std.debug.print("handshake-smoke: accept version {d}\n", .{a.version}),
        .refuse => |r| {
            std.debug.print("handshake-smoke: refused: ", .{});
            printTerm(r.reason);
            std.debug.print("\n", .{});
        },
        .propose => std.debug.print("handshake-smoke: unexpected propose\n", .{}),
    }
}
