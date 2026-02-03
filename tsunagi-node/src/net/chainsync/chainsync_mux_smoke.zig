const std = @import("std");

const cbor = @import("../cbor/term.zig");
const chainsync_codec = @import("chainsync_codec.zig");
const handshake_codec = @import("../handshake/handshake_codec.zig");
const mux_bearer = @import("../muxwire/mux_bearer.zig");
const bt_boundary = @import("../transport/byte_transport.zig");
const tcp_bt = @import("../transport/tcp_byte_transport.zig");

const chainsync_proto: u16 = 2;

fn printPoint(term: cbor.Term) void {
    if (term == .array) {
        const items = term.array;
        if (items.len == 0) {
            std.debug.print("point: origin\n", .{});
            return;
        }
        if (items.len >= 2 and items[0] == .u64 and items[1] == .bytes) {
            const slot = items[0].u64;
            const hash = items[1].bytes;
            const end = if (hash.len < 8) hash.len else 8;
            std.debug.print(
                "point: slot={d} hash={s}\n",
                .{ slot, std.fmt.fmtSliceHexLower(hash[0..end]) },
            );
            return;
        }
    }
    std.debug.print("point: (opaque)\n", .{});
}

fn cloneTerm(alloc: std.mem.Allocator, term: cbor.Term) !cbor.Term {
    return switch (term) {
        .u64 => |v| cbor.Term{ .u64 = v },
        .i64 => |v| cbor.Term{ .i64 = v },
        .bool => |v| cbor.Term{ .bool = v },
        .bytes => |b| cbor.Term{ .bytes = try alloc.dupe(u8, b) },
        .text => |t| cbor.Term{ .text = try alloc.dupe(u8, t) },
        .array => |items| blk: {
            var out = try alloc.alloc(cbor.Term, items.len);
            errdefer {
                for (out) |item| cbor.free(item, alloc);
                alloc.free(out);
            }
            for (items, 0..) |item, i| {
                out[i] = try cloneTerm(alloc, item);
            }
            break :blk cbor.Term{ .array = out };
        },
        .map_u64 => |entries| blk: {
            var out = try alloc.alloc(cbor.MapEntry, entries.len);
            errdefer {
                for (out) |e| cbor.free(e.value, alloc);
                alloc.free(out);
            }
            for (entries, 0..) |e, i| {
                out[i] = .{ .key = e.key, .value = try cloneTerm(alloc, e.value) };
            }
            break :blk cbor.Term{ .map_u64 = out };
        },
    };
}

fn storeTip(alloc: std.mem.Allocator, last_tip: *?cbor.Term, tip: cbor.Term) !void {
    if (last_tip.*) |existing| {
        cbor.free(existing, alloc);
    }
    last_tip.* = try cloneTerm(alloc, tip);
}

fn printIndent(level: usize) void {
    var i: usize = 0;
    while (i < level) : (i += 1) {
        std.debug.print("  ", .{});
    }
}

fn printTerm(term: cbor.Term, level: usize) void {
    switch (term) {
        .u64 => |v| {
            printIndent(level);
            std.debug.print("u64 {d}\n", .{v});
        },
        .i64 => |v| {
            printIndent(level);
            std.debug.print("i64 {d}\n", .{v});
        },
        .bool => |v| {
            printIndent(level);
            std.debug.print("bool {s}\n", .{if (v) "true" else "false"});
        },
        .text => |v| {
            printIndent(level);
            std.debug.print("text \"{s}\"\n", .{v});
        },
        .bytes => |v| {
            const end = if (v.len < 8) v.len else 8;
            printIndent(level);
            std.debug.print(
                "bytes {s} len={d}\n",
                .{ std.fmt.fmtSliceHexLower(v[0..end]), v.len },
            );
        },
        .array => |items| {
            printIndent(level);
            std.debug.print("array len={d}\n", .{items.len});
            for (items) |item| {
                printTerm(item, level + 1);
            }
        },
        .map_u64 => |entries| {
            printIndent(level);
            std.debug.print("map_u64 len={d}\n", .{entries.len});
            for (entries) |entry| {
                printIndent(level + 1);
                std.debug.print("key {d}\n", .{entry.key});
                printTerm(entry.value, level + 2);
            }
        },
    }
}

fn printTipArray(items: []const cbor.Term) void {
    if (items.len == 2 and items[0] == .array and items[1] == .u64) {
        const inner = items[0].array;
        if (inner.len == 2 and inner[0] == .u64 and inner[1] == .bytes) {
            const slot = inner[0].u64;
            const hash = inner[1].bytes;
            const block_no = items[1].u64;
            const end = if (hash.len < 8) hash.len else 8;
            std.debug.print(
                "tip(from msg): slot={d} blockNo={d} hash={s}\n",
                .{ slot, block_no, std.fmt.fmtSliceHexLower(hash[0..end]) },
            );
            return;
        }
    }
    if (items.len >= 1 and items[0] == .u64) {
        if (items.len >= 3 and items[2] == .u64) {
            std.debug.print(
                "tip(from msg): slot={d} blockNo={d}\n",
                .{ items[0].u64, items[2].u64 },
            );
            return;
        }
        std.debug.print("tip(from msg): slot={d}\n", .{items[0].u64});
        return;
    }
    std.debug.print("tip(from msg): (opaque)\n", .{});
    std.debug.print("tip term:\n", .{});
    printTerm(.{ .array = @constCast(items) }, 1);
}

fn printTip(term: cbor.Term) void {
    if (term == .array) {
        const items = term.array;
        if (items.len == 1 and items[0] == .array) {
            printTipArray(items[0].array);
            return;
        }
        printTipArray(items);
        return;
    }
    std.debug.print("tip(from msg): (opaque)\n", .{});
    std.debug.print("tip term:\n", .{});
    printTerm(term, 1);
}

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
    var last_tip: ?cbor.Term = null;
    defer if (last_tip) |tip| {
        cbor.free(tip, alloc);
    };

    const timeout_ms: u32 = 10_000;
    tcp_bt.setReadTimeout(&bt, timeout_ms) catch {};

    const accepted = try doHandshake(alloc, &bt);
    if (!accepted) {
        std.debug.print("chainsync: no response\n", .{});
        return;
    }

    const origin_point = cbor.Term{ .array = @constCast((&[_]cbor.Term{})[0..]) };
    var points_items = try alloc.alloc(cbor.Term, 1);
    defer alloc.free(points_items);
    points_items[0] = origin_point;
    const points = cbor.Term{ .array = points_items };
    var list = std.ArrayList(u8).init(alloc);
    defer list.deinit();
    try chainsync_codec.encodeFindIntersect(list.writer(), points);
    const msg_bytes = try list.toOwnedSlice();
    defer alloc.free(msg_bytes);

    try mux_bearer.sendSegment(&bt, .responder, chainsync_proto, msg_bytes);
    std.debug.print("chainsync: sent FindIntersect ({d} bytes)\n", .{msg_bytes.len});

    const deadline_ms: i64 = std.time.milliTimestamp() + timeout_ms;

    while (true) {
        const now_ms = std.time.milliTimestamp();
        if (now_ms >= deadline_ms) {
            std.debug.print("chainsync: timed out after 10000ms\n", .{});
            return;
        }

        const remaining_ms: u32 = @intCast(deadline_ms - now_ms);
        tcp_bt.setReadTimeout(&bt, remaining_ms) catch {};

        const seg = mux_bearer.recvSegmentWithTimeout(alloc, &bt) catch |err| switch (err) {
            error.TimedOut => continue,
            else => return err,
        };
        if (seg == null) {
            std.debug.print("peer closed\n", .{});
            return;
        }
        defer alloc.free(seg.?.payload);

        const hdr = seg.?.hdr;
        std.debug.print(
            "mux: rx hdr dir={s} proto={d} len={d}\n",
            .{ @tagName(hdr.dir), hdr.proto, hdr.len },
        );

        if (hdr.proto == chainsync_proto) {
            var fbs = std.io.fixedBufferStream(seg.?.payload);
            var msg = try chainsync_codec.decodeResponse(alloc, fbs.reader());
            defer chainsync_codec.free(alloc, &msg);

            switch (msg) {
                .intersect_found => {
                    std.debug.print("chainsync: intersect found\n", .{});
                    printTip(msg.intersect_found.tip);
                    try storeTip(alloc, &last_tip, msg.intersect_found.tip);

                    var req_list = std.ArrayList(u8).init(alloc);
                    defer req_list.deinit();
                    try chainsync_codec.encodeRequestNext(req_list.writer());
                    const req_bytes = try req_list.toOwnedSlice();
                    defer alloc.free(req_bytes);

                    var i: u8 = 0;
                    while (i < 3) : (i += 1) {
                        try mux_bearer.sendSegment(&bt, .responder, chainsync_proto, req_bytes);

                        const req_deadline_ms: i64 = std.time.milliTimestamp() + timeout_ms;
                        var awaiting_reply = true;
                        while (awaiting_reply) {
                            const req_now_ms = std.time.milliTimestamp();
                            if (req_now_ms >= req_deadline_ms) {
                                std.debug.print("chainsync: timed out after 10000ms\n", .{});
                                return;
                            }

                            const req_remaining_ms: u32 = @intCast(req_deadline_ms - req_now_ms);
                            tcp_bt.setReadTimeout(&bt, req_remaining_ms) catch {};

                            const next_seg = mux_bearer.recvSegmentWithTimeout(alloc, &bt) catch |err| switch (err) {
                                error.TimedOut => continue,
                                else => return err,
                            };
                            if (next_seg == null) {
                                std.debug.print("peer closed\n", .{});
                                return;
                            }
                            defer alloc.free(next_seg.?.payload);

                            const next_hdr = next_seg.?.hdr;
                            std.debug.print(
                                "mux: rx hdr dir={s} proto={d} len={d}\n",
                                .{ @tagName(next_hdr.dir), next_hdr.proto, next_hdr.len },
                            );

                            if (next_hdr.proto == chainsync_proto) {
                                var next_fbs = std.io.fixedBufferStream(next_seg.?.payload);
                                var next_msg = try chainsync_codec.decodeResponse(alloc, next_fbs.reader());
                                defer chainsync_codec.free(alloc, &next_msg);

                                switch (next_msg) {
                                    .await_reply => {
                                        std.debug.print("chainsync[{d}]: await reply\n", .{i});
                                        awaiting_reply = true;
                                    },
                                    .roll_forward => {
                                        std.debug.print("chainsync[{d}]: roll forward\n", .{i});
                                        printTip(next_msg.roll_forward.tip);
                                        try storeTip(alloc, &last_tip, next_msg.roll_forward.tip);
                                        awaiting_reply = false;
                                    },
                                    .roll_backward => {
                                        std.debug.print("chainsync[{d}]: roll backward\n", .{i});
                                        printPoint(next_msg.roll_backward.point);
                                        printTip(next_msg.roll_backward.tip);
                                        try storeTip(alloc, &last_tip, next_msg.roll_backward.tip);
                                        awaiting_reply = false;
                                    },
                                    else => {
                                        std.debug.print("chainsync[{d}]: no response\n", .{i});
                                        awaiting_reply = false;
                                    },
                                }
                            } else if (next_hdr.proto == 8) {
                                std.debug.print("keepalive: rx (ignored)\n", .{});
                                continue;
                            } else {
                                std.debug.print("mux: rx unexpected proto={d}\n", .{next_hdr.proto});
                                continue;
                            }
                        }
                    }
                    return;
                },
                .intersect_not_found => {
                    std.debug.print("chainsync: intersect not found\n", .{});
                    return;
                },
                else => std.debug.print("chainsync: no response\n", .{}),
            }
            return;
        } else if (hdr.proto == 8) {
            std.debug.print("keepalive: rx (ignored)\n", .{});
            continue;
        } else {
            std.debug.print("mux: rx unexpected proto={d}\n", .{hdr.proto});
            continue;
        }
    }
}
