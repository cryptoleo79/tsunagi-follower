const std = @import("std");

const cbor = @import("../cbor/term.zig");
const chainsync_codec = @import("chainsync_codec.zig");
const handshake_codec = @import("../handshake/handshake_codec.zig");
const mux_bearer = @import("../muxwire/mux_bearer.zig");
const bt_boundary = @import("../transport/byte_transport.zig");
const tcp_bt = @import("../transport/tcp_byte_transport.zig");
const header_raw = @import("../ledger/header_raw.zig");
const cursor_store = @import("../ledger/cursor.zig");

const chainsync_proto: u16 = 2;
const keepalive_proto: u16 = 8;

pub const Context = struct {
    cursor: cursor_store.Cursor,
    current_tip: ?cbor.Term = null,
    current_block: ?cbor.Term = null,
    current_point: ?cbor.Term = null,
    roll_forward_count: u64 = 0,
    debug_verbose: bool = false,
};

pub const Callbacks = struct {
    on_roll_forward: fn (
        ctx: *anyopaque,
        tip_slot: u64,
        tip_block: u64,
        tip_hash32: [32]u8,
        header_hash32: [32]u8,
    ) anyerror!void,
    on_roll_backward: fn (
        ctx: *anyopaque,
        tip_slot: u64,
        tip_block: u64,
        tip_hash32: [32]u8,
    ) anyerror!void,
    on_status: fn (
        ctx: *anyopaque,
        slot: u64,
        block: u64,
        fwd: u64,
        back: u64,
        tip_prefix8: [8]u8,
    ) void,
    on_shutdown: fn (ctx: *anyopaque) void,
};

pub const HeaderCborInfo = struct {
    cbor_bytes: []u8,
    prev_hash: ?[32]u8,
};

var g_should_stop: ?*bool = null;
var g_signal_received: bool = false;

fn vprint(debug_verbose: bool, comptime fmt: []const u8, args: anytype) void {
    if (debug_verbose) std.debug.print(fmt, args);
}

fn hexHasValue(hex: []const u8) bool {
    for (hex) |b| {
        if (b != '0') return true;
    }
    return false;
}

fn handleSignal(sig: c_int) callconv(.C) void {
    _ = sig;
    if (g_should_stop) |ptr| {
        ptr.* = true;
    }
    g_signal_received = true;
}

fn installSignalHandlers(should_stop: *bool) !void {
    g_should_stop = should_stop;
    var action = std.posix.Sigaction{
        .handler = .{ .handler = handleSignal },
        .mask = std.posix.empty_sigset,
        .flags = 0,
    };
    try std.posix.sigaction(std.posix.SIG.INT, &action, null);
    try std.posix.sigaction(std.posix.SIG.TERM, &action, null);
}

fn checkStop(should_stop: *bool) bool {
    if (g_signal_received) {
        g_signal_received = false;
        std.debug.print("Signal received, shutting down...\n", .{});
    }
    return should_stop.*;
}

fn maybePrintStatus(
    last_status_unix: *i64,
    callbacks: Callbacks,
    ctx_any: *anyopaque,
    cursor: *const cursor_store.Cursor,
) void {
    const now = std.time.timestamp();
    if (now - last_status_unix.* >= 10) {
        last_status_unix.* = now;
        var tip_prefix8: [8]u8 = undefined;
        std.mem.copyForwards(u8, tip_prefix8[0..], cursor.tip_hash_hex[0..8]);
        callbacks.on_status(
            ctx_any,
            cursor.slot,
            cursor.block_no,
            cursor.roll_forward_count,
            cursor.roll_backward_count,
            tip_prefix8,
        );
    }
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

const TipSlotBlock = struct {
    slot: u64,
    block_no: u64,
};

fn getTipHash(term: cbor.Term) ?[]const u8 {
    if (term != .array) return null;
    const items = term.array;
    const inner = blk: {
        if (items.len == 1 and items[0] == .array) break :blk items[0].array;
        break :blk items;
    };
    if (inner.len != 2) return null;
    if (inner[0] != .array or inner[1] != .u64) return null;
    const point = inner[0].array;
    if (point.len != 2) return null;
    if (point[0] != .u64 or point[1] != .bytes) return null;
    if (point[1].bytes.len != 32) return null;
    return point[1].bytes;
}

fn getTipSlotBlock(term: cbor.Term) ?TipSlotBlock {
    if (term != .array) return null;
    const items = term.array;
    const inner = blk: {
        if (items.len == 1 and items[0] == .array) break :blk items[0].array;
        break :blk items;
    };
    if (inner.len == 2 and inner[0] == .array and inner[1] == .u64) {
        const point = inner[0].array;
        if (point.len == 2 and point[0] == .u64 and point[1] == .bytes) {
            return .{ .slot = point[0].u64, .block_no = inner[1].u64 };
        }
    }
    if (inner.len >= 3 and inner[0] == .u64 and inner[2] == .u64) {
        return .{ .slot = inner[0].u64, .block_no = inner[2].u64 };
    }
    return null;
}

pub fn headerHashBlake2b256(header_cbor_bytes: []const u8) [32]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.blake2.Blake2b256.hash(header_cbor_bytes, &digest, .{});
    return digest;
}

pub fn extractHeaderCborInfo(alloc: std.mem.Allocator, block: cbor.Term) ?HeaderCborInfo {
    if (block != .array) return null;
    const items = block.array;
    if (items.len < 2) return null;

    const block_bytes = blk: {
        if (items[1] == .bytes) break :blk items[1].bytes;
        if (items[1] == .tag and items[1].tag.tag == 24 and items[1].tag.value.* == .bytes) {
            break :blk items[1].tag.value.*.bytes;
        }
        return null;
    };

    const inner_bytes = header_raw.getTag24InnerBytes(block_bytes) orelse block_bytes;
    var fbs = std.io.fixedBufferStream(inner_bytes);
    const top = cbor.decode(alloc, fbs.reader()) catch return null;
    defer cbor.free(top, alloc);

    if (top != .array) return null;
    const top_items = top.array;
    if (top_items.len == 0 or top_items[0] != .array) return null;
    if (top_items[0].array.len != 15) return null;

    var list = std.ArrayList(u8).init(alloc);
    errdefer list.deinit();
    cbor.encode(top_items[0], list.writer()) catch {
        list.deinit();
        return null;
    };
    const cbor_bytes = list.toOwnedSlice() catch {
        list.deinit();
        return null;
    };

    var prev_hash: ?[32]u8 = null;
    const header_items = top_items[0].array;
    if (header_items[8] == .bytes and header_items[8].bytes.len == 32) {
        var bytes32: [32]u8 = undefined;
        std.mem.copyForwards(u8, bytes32[0..], header_items[8].bytes);
        prev_hash = bytes32;
    }

    return HeaderCborInfo{
        .cbor_bytes = cbor_bytes,
        .prev_hash = prev_hash,
    };
}

fn cloneTerm(alloc: std.mem.Allocator, term: cbor.Term) !cbor.Term {
    return switch (term) {
        .u64 => |v| cbor.Term{ .u64 = v },
        .i64 => |v| cbor.Term{ .i64 = v },
        .bool => |v| cbor.Term{ .bool = v },
        .null => cbor.Term{ .null = {} },
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
        .tag => |t| blk: {
            const value = try alloc.create(cbor.Term);
            errdefer alloc.destroy(value);
            value.* = try cloneTerm(alloc, t.value.*);
            break :blk cbor.Term{ .tag = .{ .tag = t.tag, .value = value } };
        },
    };
}

fn storeTip(alloc: std.mem.Allocator, last_tip: *?cbor.Term, tip: cbor.Term) !void {
    if (last_tip.*) |existing| {
        cbor.free(existing, alloc);
    }
    last_tip.* = try cloneTerm(alloc, tip);
}

fn tipHash32(term: cbor.Term) ?[32]u8 {
    const bytes = getTipHash(term) orelse return null;
    var out: [32]u8 = undefined;
    std.mem.copyForwards(u8, out[0..], bytes);
    return out;
}

fn headerHash32(alloc: std.mem.Allocator, block: cbor.Term) ?[32]u8 {
    const header_info = extractHeaderCborInfo(alloc, block) orelse return null;
    defer alloc.free(header_info.cbor_bytes);
    return headerHashBlake2b256(header_info.cbor_bytes);
}

pub fn run(
    alloc: std.mem.Allocator,
    host: []const u8,
    port: u16,
    callbacks: Callbacks,
    ctx_any: *anyopaque,
) !void {
    var bt = try tcp_bt.connect(alloc, host, port);
    defer bt.deinit();

    var should_stop = false;
    try installSignalHandlers(&should_stop);

    var last_tip: ?cbor.Term = null;
    defer if (last_tip) |tip| {
        cbor.free(tip, alloc);
    };

    const ctx = @as(*Context, @ptrCast(@alignCast(ctx_any)));

    const timeout_ms: u32 = 10_000;
    tcp_bt.setReadTimeout(&bt, timeout_ms) catch {};

    const accepted = try doHandshake(alloc, &bt);
    if (!accepted) {
        vprint(ctx.debug_verbose, "chainsync: no response\n", .{});
        return;
    }

    var point_items: ?[]cbor.Term = null;
    var point_hash_bytes: ?[]u8 = null;
    defer if (point_items) |items| alloc.free(items);
    defer if (point_hash_bytes) |bytes| alloc.free(bytes);

    const use_cursor = ctx.cursor.slot > 0 and hexHasValue(ctx.cursor.tip_hash_hex[0..]);
    var used_cursor_point = false;
    const point = blk: {
        if (!use_cursor) break :blk cbor.Term{ .array = @constCast((&[_]cbor.Term{})[0..]) };

        var hash_bytes: [32]u8 = undefined;
        _ = std.fmt.hexToBytes(&hash_bytes, ctx.cursor.tip_hash_hex[0..]) catch break :blk cbor.Term{
            .array = @constCast((&[_]cbor.Term{})[0..]),
        };

        const hash_copy = try alloc.dupe(u8, hash_bytes[0..]);
        point_hash_bytes = hash_copy;
        const items = try alloc.alloc(cbor.Term, 2);
        point_items = items;
        items[0] = .{ .u64 = ctx.cursor.slot };
        items[1] = .{ .bytes = hash_copy };
        used_cursor_point = true;
        break :blk cbor.Term{ .array = items };
    };

    if (used_cursor_point and point.array.len == 2 and point.array[1] == .bytes) {
        const hash = point.array[1].bytes;
        std.debug.print(
            "FindIntersect using cursor point: slot={d} hash={s}\n",
            .{ ctx.cursor.slot, std.fmt.fmtSliceHexLower(hash[0..4]) },
        );
    } else {
        std.debug.print("FindIntersect using origin (no cursor point)\n", .{});
    }

    var points_items = try alloc.alloc(cbor.Term, 1);
    defer alloc.free(points_items);
    points_items[0] = point;
    const points = cbor.Term{ .array = points_items };
    var list = std.ArrayList(u8).init(alloc);
    defer list.deinit();
    try chainsync_codec.encodeFindIntersect(list.writer(), points);
    const msg_bytes = try list.toOwnedSlice();
    defer alloc.free(msg_bytes);

    try mux_bearer.sendSegment(&bt, .responder, chainsync_proto, msg_bytes);
    vprint(ctx.debug_verbose, "chainsync: sent FindIntersect ({d} bytes)\n", .{msg_bytes.len});

    var last_status_unix: i64 = std.time.timestamp();
    var shutdown_requested = false;

    outer: while (true) {
        if (checkStop(&should_stop)) {
            shutdown_requested = true;
            break :outer;
        }
        maybePrintStatus(&last_status_unix, callbacks, ctx_any, &ctx.cursor);
        tcp_bt.setReadTimeout(&bt, timeout_ms) catch {};

        const seg = mux_bearer.recvSegmentWithTimeout(alloc, &bt) catch |err| switch (err) {
            error.TimedOut => continue,
            else => return err,
        };
        if (seg == null) {
            vprint(ctx.debug_verbose, "peer closed\n", .{});
            return;
        }
        defer alloc.free(seg.?.payload);

        const hdr = seg.?.hdr;
        vprint(
            ctx.debug_verbose,
            "mux: rx hdr dir={s} proto={d} len={d}\n",
            .{ @tagName(hdr.dir), hdr.proto, hdr.len },
        );

        if (hdr.proto == chainsync_proto) {
            var fbs = std.io.fixedBufferStream(seg.?.payload);
            var msg = try chainsync_codec.decodeResponse(alloc, fbs.reader());
            defer chainsync_codec.free(alloc, &msg);

            switch (msg) {
                .intersect_found => {
                    vprint(ctx.debug_verbose, "chainsync: intersect found\n", .{});
                    try storeTip(alloc, &last_tip, msg.intersect_found.tip);

                    var req_list = std.ArrayList(u8).init(alloc);
                    defer req_list.deinit();
                    try chainsync_codec.encodeRequestNext(req_list.writer());
                    const req_bytes = try req_list.toOwnedSlice();
                    defer alloc.free(req_bytes);

                    var steps: u64 = 0;
                    ctx.roll_forward_count = 0;
                    while (true) : (steps += 1) {
                        if (checkStop(&should_stop)) {
                            shutdown_requested = true;
                            break :outer;
                        }
                        maybePrintStatus(&last_status_unix, callbacks, ctx_any, &ctx.cursor);
                        try mux_bearer.sendSegment(&bt, .responder, chainsync_proto, req_bytes);

                        var awaiting_reply = true;
                        while (awaiting_reply) {
                            if (checkStop(&should_stop)) {
                                shutdown_requested = true;
                                break :outer;
                            }
                            maybePrintStatus(&last_status_unix, callbacks, ctx_any, &ctx.cursor);
                            tcp_bt.setReadTimeout(&bt, timeout_ms) catch {};

                            const next_seg = mux_bearer.recvSegmentWithTimeout(alloc, &bt) catch |err| switch (err) {
                                error.TimedOut => continue,
                                else => return err,
                            };
                            if (next_seg == null) {
                                vprint(ctx.debug_verbose, "peer closed\n", .{});
                                return;
                            }
                            defer alloc.free(next_seg.?.payload);

                            const next_hdr = next_seg.?.hdr;
                            vprint(
                                ctx.debug_verbose,
                                "mux: rx hdr dir={s} proto={d} len={d}\n",
                                .{ @tagName(next_hdr.dir), next_hdr.proto, next_hdr.len },
                            );

                            if (next_hdr.proto == chainsync_proto) {
                                var next_fbs = std.io.fixedBufferStream(next_seg.?.payload);
                                var next_msg = try chainsync_codec.decodeResponse(alloc, next_fbs.reader());
                                defer chainsync_codec.free(alloc, &next_msg);

                                switch (next_msg) {
                                    .await_reply => {
                                        vprint(ctx.debug_verbose, "chainsync[{d}]: await reply\n", .{steps});
                                        awaiting_reply = true;
                                    },
                                    .roll_forward => {
                                        vprint(ctx.debug_verbose, "chainsync[{d}]: roll forward\n", .{steps});
                                        try storeTip(alloc, &last_tip, next_msg.roll_forward.tip);

                                        const tip_info = getTipSlotBlock(next_msg.roll_forward.tip);
                                        const tip_slot: u64 = if (tip_info) |info| info.slot else 0;
                                        const tip_block: u64 = if (tip_info) |info| info.block_no else 0;

                                        var tip_hash32_value: [32]u8 = std.mem.zeroes([32]u8);
                                        if (tipHash32(next_msg.roll_forward.tip)) |hash| {
                                            tip_hash32_value = hash;
                                        }

                                        var header_hash32_value: [32]u8 = std.mem.zeroes([32]u8);
                                        if (headerHash32(alloc, next_msg.roll_forward.block)) |hash| {
                                            header_hash32_value = hash;
                                        }

                                        ctx.roll_forward_count += 1;
                                        ctx.current_tip = next_msg.roll_forward.tip;
                                        ctx.current_block = next_msg.roll_forward.block;
                                        try callbacks.on_roll_forward(
                                            ctx_any,
                                            tip_slot,
                                            tip_block,
                                            tip_hash32_value,
                                            header_hash32_value,
                                        );
                                        ctx.current_tip = null;
                                        ctx.current_block = null;
                                        awaiting_reply = false;
                                    },
                                    .roll_backward => {
                                        vprint(ctx.debug_verbose, "chainsync[{d}]: roll backward\n", .{steps});
                                        try storeTip(alloc, &last_tip, next_msg.roll_backward.tip);

                                        const tip_info = getTipSlotBlock(next_msg.roll_backward.tip);
                                        const tip_slot: u64 = if (tip_info) |info| info.slot else 0;
                                        const tip_block: u64 = if (tip_info) |info| info.block_no else 0;

                                        var tip_hash32_value: [32]u8 = std.mem.zeroes([32]u8);
                                        if (tipHash32(next_msg.roll_backward.tip)) |hash| {
                                            tip_hash32_value = hash;
                                        }

                                        ctx.current_tip = next_msg.roll_backward.tip;
                                        ctx.current_block = null;
                                        ctx.current_point = next_msg.roll_backward.point;
                                        try callbacks.on_roll_backward(
                                            ctx_any,
                                            tip_slot,
                                            tip_block,
                                            tip_hash32_value,
                                        );
                                        ctx.current_tip = null;
                                        ctx.current_point = null;
                                        awaiting_reply = false;
                                    },
                                    else => {
                                        vprint(ctx.debug_verbose, "chainsync[{d}]: no response\n", .{steps});
                                        awaiting_reply = false;
                                    },
                                }
                            } else if (next_hdr.proto == keepalive_proto) {
                                vprint(ctx.debug_verbose, "keepalive: rx (ignored)\n", .{});
                                continue;
                            } else {
                                vprint(ctx.debug_verbose, "mux: rx unexpected proto={d}\n", .{next_hdr.proto});
                                continue;
                            }
                        }
                    }
                    return;
                },
                .intersect_not_found => {
                    vprint(ctx.debug_verbose, "chainsync: intersect not found\n", .{});
                    continue :outer;
                },
                else => {
                    vprint(ctx.debug_verbose, "chainsync: no response\n", .{});
                    continue :outer;
                },
            }
            continue;
        } else if (hdr.proto == keepalive_proto) {
            vprint(ctx.debug_verbose, "keepalive: rx (ignored)\n", .{});
            continue;
        } else {
            vprint(ctx.debug_verbose, "mux: rx unexpected proto={d}\n", .{hdr.proto});
            continue;
        }
    }

    if (shutdown_requested) {
        callbacks.on_shutdown(ctx_any);
    }
}
