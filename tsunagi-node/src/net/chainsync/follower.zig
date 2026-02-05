const std = @import("std");

const cbor = @import("../cbor/term.zig");
const chainsync_codec = @import("chainsync_codec.zig");
const handshake_codec = @import("../handshake/handshake_codec.zig");
const mux_bearer = @import("../muxwire/mux_bearer.zig");
const bt_boundary = @import("../transport/byte_transport.zig");
const tcp_bt = @import("../transport/tcp_byte_transport.zig");
const header_raw = @import("../ledger/header_raw.zig");
const cursor_store = @import("../ledger/cursor.zig");
const tps = @import("../ledger/tps.zig");
const tx_decode = @import("../ledger/tx_decode.zig");
const utxo_mod = @import("../ledger/utxo.zig");

const chainsync_proto: u16 = 2;
const keepalive_proto: u16 = 8;

pub const Context = struct {
    cursor: cursor_store.Cursor,
    current_tip: ?cbor.Term = null,
    current_block: ?cbor.Term = null,
    current_point: ?cbor.Term = null,
    roll_forward_count: u64 = 0,
    debug_verbose: bool = false,
    utxo: ?*utxo_mod.UTxO = null,
    undo_stack: ?*std.ArrayList(utxo_mod.Undo) = null,
    preview_utxo: bool = false,
    network_magic: u64 = 2,
    peer_sharing: bool = true,
};

pub const Callbacks = struct {
    on_roll_forward: fn (
        ctx: *anyopaque,
        tip_slot: u64,
        tip_block: u64,
        tip_hash32: [32]u8,
        header_hash32: [32]u8,
        tx_count: u64,
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

pub const SelectedPeer = struct {
    host: []u8,
    port: u16,
};

fn connectWithTimeout(addr: std.net.Address, timeout_ms: u32) bool {
    const sock_flags = std.posix.SOCK.STREAM | std.posix.SOCK.NONBLOCK | std.posix.SOCK.CLOEXEC;
    const sockfd = std.posix.socket(addr.any.family, sock_flags, std.posix.IPPROTO.TCP) catch return false;
    defer std.posix.close(sockfd);

    if (std.posix.connect(sockfd, &addr.any, addr.getOsSockLen())) |_| {
        return true;
    } else |err| switch (err) {
        error.WouldBlock, error.ConnectionPending => {},
        else => return false,
    }

    var fds = [_]std.posix.pollfd{.{ .fd = sockfd, .events = std.posix.POLL.OUT, .revents = 0 }};
    const poll_rc = std.posix.poll(fds[0..], @intCast(timeout_ms)) catch return false;
    if (poll_rc == 0) return false;

    std.posix.getsockoptError(sockfd) catch return false;
    return true;
}

fn formatIpv4Host(alloc: std.mem.Allocator, addr: std.net.Ip4Address) ![]u8 {
    var buf: [15]u8 = undefined;
    const bytes = @as(*const [4]u8, @ptrCast(&addr.sa.addr));
    const ip = try std.fmt.bufPrint(&buf, "{}.{}.{}.{}", .{
        bytes[0],
        bytes[1],
        bytes[2],
        bytes[3],
    });
    return alloc.dupe(u8, ip);
}

pub fn selectReachableIpv4(
    alloc: std.mem.Allocator,
    hostname: []const u8,
    port: u16,
    timeout_ms: u32,
) !?SelectedPeer {
    var list = try std.net.getAddressList(alloc, hostname, port);
    defer list.deinit();

    for (list.addrs) |addr| {
        if (addr.any.family != std.posix.AF.INET) continue;
        if (connectWithTimeout(addr, timeout_ms)) {
            const host = try formatIpv4Host(alloc, addr.in);
            return .{ .host = host, .port = port };
        }
    }
    return null;
}

pub fn selectMainnetPeer(alloc: std.mem.Allocator, timeout_ms: u32) !?SelectedPeer {
    const candidates = [_][]const u8{
        "backbone.cardano.iog.io",
        "backbone.mainnet.cardanofoundation.org",
        "backbone.mainnet.emurgornd.com",
    };

    for (candidates) |hostname| {
        if (try selectReachableIpv4(alloc, hostname, 3001, timeout_ms)) |peer| {
            return peer;
        }
    }
    return null;
}

fn vprint(debug_verbose: bool, comptime fmt: []const u8, args: anytype) void {
    if (debug_verbose) std.debug.print(fmt, args);
}

fn termKindName(term: cbor.Term) []const u8 {
    return switch (term) {
        .u64 => "u64",
        .i64 => "i64",
        .bool => "bool",
        .null => "null",
        .bytes => "bytes",
        .text => "text",
        .array => "array",
        .map_u64 => "map",
        .tag => "tag",
    };
}

fn logBlockShape(block: cbor.Term, tip_hash32: [32]u8) void {
    var tip_prefix: [8]u8 = [_]u8{'?'} ** 8;
    _ = std.fmt.bufPrint(
        &tip_prefix,
        "{s}",
        .{std.fmt.fmtSliceHexLower(tip_hash32[0..4])},
    ) catch {};

    switch (block) {
        .array => |items| {
            const count = items.len;
            const first = @min(@as(usize, 3), count);
            std.debug.print("mainnet block shape tip={s} array len={d} first=[", .{ tip_prefix[0..], count });
            var i: usize = 0;
            while (i < first) : (i += 1) {
                if (i > 0) std.debug.print(",", .{});
                std.debug.print("{s}", .{termKindName(items[i])});
            }
            std.debug.print("]\n", .{});
        },
        .map_u64 => |entries| {
            std.debug.print("mainnet block shape tip={s} map len={d}\n", .{ tip_prefix[0..], entries.len });
        },
        .bytes => |b| {
            std.debug.print("mainnet block shape tip={s} bytes len={d}\n", .{ tip_prefix[0..], b.len });
        },
        .tag => |t| {
            switch (t.value.*) {
                .bytes => |b| {
                    std.debug.print(
                        "mainnet block shape tip={s} tag={d} bytes len={d}\n",
                        .{ tip_prefix[0..], t.tag, b.len },
                    );
                },
                else => {
                    std.debug.print(
                        "mainnet block shape tip={s} tag={d} inner={s}\n",
                        .{ tip_prefix[0..], t.tag, termKindName(t.value.*) },
                    );
                },
            }
        },
        else => {
            std.debug.print("mainnet block shape tip={s} {s}\n", .{ tip_prefix[0..], termKindName(block) });
        },
    }
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

fn buildV14VersionData(
    alloc: std.mem.Allocator,
    network_magic: u64,
    peer_sharing: bool,
) !cbor.Term {
    var version_items = try alloc.alloc(cbor.Term, 4);
    version_items[0] = .{ .u64 = network_magic };
    version_items[1] = .{ .bool = false };
    version_items[2] = .{ .u64 = if (peer_sharing) 1 else 0 };
    version_items[3] = .{ .bool = false };
    return cbor.Term{ .array = version_items };
}

fn doHandshake(
    alloc: std.mem.Allocator,
    bt: *bt_boundary.ByteTransport,
    network_magic: u64,
    peer_sharing: bool,
) !bool {
    const version_data = try buildV14VersionData(alloc, network_magic, peer_sharing);

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

const HeaderHashError = error{
    InvalidBlock,
    InvalidHeader,
};

fn computeHeaderHash32(alloc: std.mem.Allocator, header_cbor_bytes: []const u8) ?[32]u8 {
    var fbs = std.io.fixedBufferStream(header_cbor_bytes);
    const top = cbor.decode(alloc, fbs.reader()) catch return null;
    defer cbor.free(top, alloc);

    if (top != .array) return null;
    const top_items = top.array;
    if (top_items.len == 0) return null;
    if (top_items[0] != .array) return null;

    // Cardano header body is usually 15 items, but NOT guaranteed
    if (top_items[0].array.len < 10) {
        // too small to be a valid header body
        return null;
    }

    var digest: [32]u8 = undefined;
    std.crypto.hash.blake2.Blake2b256.hash(header_cbor_bytes, &digest, .{});
    return digest;
}

fn readHead(bytes: []const u8, idx: *usize) ?struct { major: u8, ai: u8 } {
    if (idx.* >= bytes.len) return null;
    const b = bytes[idx.*];
    idx.* += 1;
    return .{ .major = b >> 5, .ai = b & 0x1f };
}

fn readLen(bytes: []const u8, idx: *usize, ai: u8) ?usize {
    switch (ai) {
        0...23 => return ai,
        24 => {
            if (idx.* + 1 > bytes.len) return null;
            const v = bytes[idx.*];
            idx.* += 1;
            return v;
        },
        25 => {
            if (idx.* + 2 > bytes.len) return null;
            const v = (@as(usize, bytes[idx.*]) << 8) | bytes[idx.* + 1];
            idx.* += 2;
            return v;
        },
        26 => {
            if (idx.* + 4 > bytes.len) return null;
            const v = (@as(usize, bytes[idx.*]) << 24) |
                (@as(usize, bytes[idx.* + 1]) << 16) |
                (@as(usize, bytes[idx.* + 2]) << 8) |
                bytes[idx.* + 3];
            idx.* += 4;
            return v;
        },
        27 => {
            if (idx.* + 8 > bytes.len) return null;
            var v: usize = 0;
            var i: usize = 0;
            while (i < 8) : (i += 1) {
                v = (v << 8) | bytes[idx.* + i];
            }
            idx.* += 8;
            return v;
        },
        31 => return null,
        else => return null,
    }
}

fn peekMajor(bytes: []const u8, idx: usize) ?u8 {
    if (idx >= bytes.len) return null;
    return bytes[idx] >> 5;
}

fn skipItem(bytes: []const u8, idx: *usize) bool {
    const head = readHead(bytes, idx) orelse return false;
    const major = head.major;
    const ai = head.ai;

    switch (major) {
        0, 1 => {
            _ = readLen(bytes, idx, ai) orelse return false;
            return true;
        },
        2, 3 => {
            const len = readLen(bytes, idx, ai) orelse return false;
            if (idx.* + len > bytes.len) return false;
            idx.* += len;
            return true;
        },
        4 => {
            const len = readLen(bytes, idx, ai) orelse return false;
            var i: usize = 0;
            while (i < len) : (i += 1) {
                if (!skipItem(bytes, idx)) return false;
            }
            return true;
        },
        5 => {
            const len = readLen(bytes, idx, ai) orelse return false;
            var i: usize = 0;
            while (i < len) : (i += 1) {
                if (!skipItem(bytes, idx)) return false;
                if (!skipItem(bytes, idx)) return false;
            }
            return true;
        },
        6 => {
            _ = readLen(bytes, idx, ai) orelse return false;
            return skipItem(bytes, idx);
        },
        7 => return true,
        else => return false,
    }
}

fn scanTxBodiesCount(body_bytes: []const u8) u64 {
    var idx: usize = 0;
    while (idx < body_bytes.len) {
        const start = idx;
        const head = readHead(body_bytes, &idx) orelse return 0;
        if (head.major == 4) {
            const len = readLen(body_bytes, &idx, head.ai) orelse return 0;
            if (idx >= body_bytes.len) return 0;
            const first_major = peekMajor(body_bytes, idx) orelse return 0;
            if (first_major == 5) {
                return @as(u64, @intCast(len));
            }
            if (first_major == 6) {
                var tag_idx = idx;
                const tag_head = readHead(body_bytes, &tag_idx) orelse return 0;
                if (tag_head.major == 6) {
                    _ = readLen(body_bytes, &tag_idx, tag_head.ai) orelse return 0;
                    const next_major = peekMajor(body_bytes, tag_idx) orelse return 0;
                    if (next_major == 5) {
                        return @as(u64, @intCast(len));
                    }
                }
            }
        }
        idx = start;
        if (!skipItem(body_bytes, &idx)) return 0;
    }
    return 0;
}

fn extractTxCount(block_body_bytes: []const u8, alloc: std.mem.Allocator, debug: bool) u64 {
    const DEBUG_TX_DISCOVERY = true;

    var outer_fbs = std.io.fixedBufferStream(block_body_bytes);
    const outer = cbor.decode(alloc, outer_fbs.reader()) catch {
        if (debug and DEBUG_TX_DISCOVERY) {
            std.debug.print("TX_DISCOVERY: outer_decode=fail\n", .{});
        }
        return 0;
    };
    defer cbor.free(outer, alloc);

    if (outer != .array) {
        if (debug and DEBUG_TX_DISCOVERY) {
            std.debug.print("TX_DISCOVERY: outer_not_array\n", .{});
        }
        return 0;
    }
    const outer_items = outer.array;
    if (outer_items.len < 2) {
        if (debug and DEBUG_TX_DISCOVERY) {
            std.debug.print("TX_DISCOVERY: outer_len_lt_2\n", .{});
        }
        return 0;
    }
    if (outer_items[1] != .bytes) {
        if (debug and DEBUG_TX_DISCOVERY) {
            std.debug.print("TX_DISCOVERY: outer_body_not_bytes kind=", .{});
            switch (outer_items[1]) {
                .u64 => std.debug.print("u64\n", .{}),
                .i64 => std.debug.print("i64\n", .{}),
                .bool => std.debug.print("bool\n", .{}),
                .null => std.debug.print("null\n", .{}),
                .bytes => std.debug.print("bytes\n", .{}),
                .text => std.debug.print("text\n", .{}),
                .array => |arr| std.debug.print("array({d})\n", .{arr.len}),
                .map_u64 => |m| std.debug.print("map({d})\n", .{m.len}),
                .tag => |t| std.debug.print("tag({d})\n", .{t.tag}),
            }
        }
        if (debug) {
            std.debug.print("BODY_BYTES missing\n", .{});
        }
        return 0;
    }

    const body_bytes = outer_items[1].bytes;
    if (debug) {
        std.debug.print("BODY_BYTES len={d}\n", .{body_bytes.len});
    }
    const count = scanTxBodiesCount(body_bytes);
    if (debug and DEBUG_TX_DISCOVERY) {
        std.debug.print(
            "TX_DISCOVERY: scan body_bytes=len{d} found={s} count={d}\n",
            .{ body_bytes.len, if (count > 0) "yes" else "no", count },
        );
    }
    return count;
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

fn applyPreviewUtxo(ctx: *Context, alloc: std.mem.Allocator, deltas: tx_decode.TxDeltas) void {
    if (!ctx.preview_utxo) return;
    const utxo = ctx.utxo orelse return;
    const undo_stack = ctx.undo_stack orelse return;
    if (deltas.consumed.len == 0 and deltas.produced.len == 0) return;

    var undo = utxo.applyDelta(deltas.consumed, deltas.produced) catch |err| {
        std.debug.print("UTXO applyDelta failed: {s}\n", .{@errorName(err)});
        var empty_undo = utxo_mod.Undo.init(alloc);
        undo_stack.append(empty_undo) catch {
            empty_undo.deinit();
        };
        return;
    };
    undo_stack.append(undo) catch |err| {
        std.debug.print("UTXO undo append failed: {s}\n", .{@errorName(err)});
        undo.deinit();
    };
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

    var tps_meter = tps.TpsMeter.init(std.time.timestamp());
    var last_body_debug_prefix: ?[8]u8 = null;
    var force_debug_rollforwards: u8 = 2;

    var last_tip: ?cbor.Term = null;
    defer if (last_tip) |tip| {
        cbor.free(tip, alloc);
    };

    const ctx = @as(*Context, @ptrCast(@alignCast(ctx_any)));

    const timeout_ms: u32 = 10_000;
    tcp_bt.setReadTimeout(&bt, timeout_ms) catch {};

    const accepted = try doHandshake(alloc, &bt, ctx.network_magic, ctx.peer_sharing);
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
    const trace_enabled = ctx.debug_verbose or (std.process.hasEnvVar(alloc, "TSUNAGI_TRACE") catch false);
    var last_trace_tip: ?[32]u8 = null;

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
            continue :outer;
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
                                continue :outer;
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
                                        var has_tip_hash = false;
                                        if (tipHash32(next_msg.roll_forward.tip)) |hash| {
                                            tip_hash32_value = hash;
                                            has_tip_hash = true;
                                        }

                                        const inner_bytes = blk: {
                                            const block = next_msg.roll_forward.block;
                                            if (block != .array) break :blk &[_]u8{};
                                            const items = block.array;
                                            if (items.len < 2) break :blk &[_]u8{};

                                            const block_bytes = blk_bytes: {
                                                if (items[1] == .bytes) break :blk_bytes items[1].bytes;
                                                if (items[1] == .tag and
                                                    items[1].tag.tag == 24 and
                                                    items[1].tag.value.* == .bytes)
                                                {
                                                    break :blk_bytes items[1].tag.value.*.bytes;
                                                }
                                                break :blk &[_]u8{};
                                            };

                                            break :blk header_raw.getTag24InnerBytes(block_bytes) orelse block_bytes;
                                        };
                                        const header_hash32_value =
                                            computeHeaderHash32(alloc, inner_bytes) orelse std.mem.zeroes([32]u8);
                                        if (trace_enabled and has_tip_hash) {
                                            if (last_trace_tip == null or
                                                !std.mem.eql(u8, last_trace_tip.?[0..], tip_hash32_value[0..]))
                                            {
                                                logBlockShape(next_msg.roll_forward.block, tip_hash32_value);
                                                last_trace_tip = tip_hash32_value;
                                            }
                                        }
                                        var debug_body = false;
                                        var tip_prefix: [8]u8 = [_]u8{'?'} ** 8;
                                        _ = try std.fmt.bufPrint(
                                            &tip_prefix,
                                            "{s}",
                                            .{std.fmt.fmtSliceHexLower(tip_hash32_value[0..4])},
                                        );
                                        if (last_body_debug_prefix) |last| {
                                            if (!std.mem.eql(u8, last[0..], tip_prefix[0..])) {
                                                debug_body = true;
                                            }
                                        } else {
                                            debug_body = true;
                                        }
                                        if (debug_body and ctx.debug_verbose) {
                                            last_body_debug_prefix = tip_prefix;
                                        } else if (!ctx.debug_verbose) {
                                            debug_body = false;
                                        }
                                        const force_debug = force_debug_rollforwards > 0;
                                        const effective_debug = debug_body or force_debug;
                                        var block_body_bytes_opt: ?[]const u8 = null;
                                        var body_top: ?cbor.Term = null;
                                        var body_fbs = std.io.fixedBufferStream(inner_bytes);
                                        if (cbor.decode(alloc, body_fbs.reader())) |decoded| {
                                            body_top = decoded;
                                            if (body_top.? == .array and body_top.?.array.len >= 2) {
                                                const body_term = body_top.?.array[1];
                                                block_body_bytes_opt = switch (body_term) {
                                                    .bytes => |b| b,
                                                    .tag => |t| blk: {
                                                        if (t.tag == 24 and t.value.* == .bytes) {
                                                            break :blk t.value.*.bytes;
                                                        }
                                                        break :blk null;
                                                    },
                                                    else => null,
                                                };
                                            }
                                        } else |_| {
                                            if (ctx.debug_verbose) {
                                                std.debug.print("TX_BODY decode failed (inner_bytes)\n", .{});
                                            }
                                        }
                                        defer if (body_top) |t| cbor.free(t, alloc);

                                        var tx_count: u64 = 0;
                                        var deltas = tx_decode.TxDeltas{
                                            .consumed = &[_]utxo_mod.TxIn{},
                                            .produced = &[_]utxo_mod.Produced{},
                                            .tx_count = 0,
                                        };
                                        if (block_body_bytes_opt) |block_body_bytes| {
                                            var tx_list: ?[]cbor.Term = null;
                                            var tx_list_kind: []const u8 = "unknown";
                                            var body_term: ?cbor.Term = null;
                                            var tx_body_fbs = std.io.fixedBufferStream(block_body_bytes);
                                            if (cbor.decode(alloc, tx_body_fbs.reader())) |decoded| {
                                                body_term = decoded;
                                                if (body_term.? == .array) {
                                                    const items = body_term.?.array;
                                                    if (items.len > 0 and items[0] == .array) {
                                                        tx_list = items[0].array;
                                                    } else {
                                                        for (items) |item| {
                                                            if (item != .array or item.array.len == 0) continue;
                                                            const first = item.array[0];
                                                            if (first == .bytes or
                                                                (first == .tag and
                                                                first.tag.tag == 24 and
                                                                first.tag.value.* == .bytes) or
                                                                first == .map_u64)
                                                            {
                                                                tx_list = item.array;
                                                                break;
                                                            }
                                                        }
                                                    }
                                                }
                                            } else |_| {}
                                            defer if (body_term) |t| cbor.free(t, alloc);

                                            if (tx_list) |list| {
                                                tx_count = @intCast(list.len);
                                                if (list.len > 0) {
                                                    const first = list[0];
                                                    tx_list_kind = if (first == .bytes)
                                                        "bytes"
                                                    else if (first == .tag and
                                                        first.tag.tag == 24 and
                                                        first.tag.value.* == .bytes)
                                                        "tag24"
                                                    else if (first == .map_u64)
                                                        "map"
                                                    else
                                                        "unknown";
                                                }
                                                if (ctx.debug_verbose) {
                                                    std.debug.print(
                                                        "tx_list_kind={s} tx_count={d}\n",
                                                        .{ tx_list_kind, tx_count },
                                                    );
                                                }
                                                if (list.len > 0) {
                                                    deltas = tx_decode.extractTxDeltas(alloc, list, debug_body) catch deltas;
                                                    if (ctx.debug_verbose and tx_count > 0 and
                                                        deltas.consumed.len == 0 and deltas.produced.len == 0)
                                                    {
                                                        std.debug.print("tx_count>0 but deltas empty\n", .{});
                                                    }
                                                    defer tx_decode.freeTxDeltas(alloc, deltas);
                                                    applyPreviewUtxo(ctx, alloc, deltas);
                                                }
                                            }
                                        }
                                        if (force_debug_rollforwards > 0) force_debug_rollforwards -= 1;

                                        if (ctx.debug_verbose) {
                                            var header_prefix: [8]u8 = [_]u8{'?'} ** 8;
                                            _ = try std.fmt.bufPrint(
                                                &header_prefix,
                                                "{s}",
                                                .{std.fmt.fmtSliceHexLower(header_hash32_value[0..4])},
                                            );
                                            std.debug.print(
                                                "engine header_hash_prefix={s}\n",
                                                .{header_prefix[0..]},
                                            );
                                        }

                                        const now = std.time.timestamp();
                                        tps_meter.addBlock(tx_count, now, ctx.debug_verbose);
                                        ctx.roll_forward_count += 1;
                                        ctx.current_tip = next_msg.roll_forward.tip;
                                        ctx.current_block = next_msg.roll_forward.block;
                                        try callbacks.on_roll_forward(
                                            ctx_any,
                                            tip_slot,
                                            tip_block,
                                            tip_hash32_value,
                                            header_hash32_value,
                                            tx_count,
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
