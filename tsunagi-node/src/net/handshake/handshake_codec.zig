const std = @import("std");
const cbor = @import("../cbor/term.zig");

pub const Propose = struct {
    versions: cbor.Term,
};

pub const Accept = struct {
    version: u64,
    version_data: cbor.Term,
};

pub const Refuse = struct {
    reason: cbor.Term,
};

pub const HandshakeMsg = union(enum) {
    propose: Propose,
    accept: Accept,
    refuse: Refuse,
};

pub const Error = error{
    UnsupportedTerm,
    InvalidLength,
    InvalidTag,
    InvalidType,
};

pub fn encodeMsg(msg: HandshakeMsg, writer: anytype) !void {
    var items: [3]cbor.Term = undefined;
    const term = switch (msg) {
        .propose => |p| blk: {
            items[0] = .{ .u64 = 0 };
            items[1] = p.versions;
            break :blk cbor.Term{ .array = items[0..2] };
        },
        .accept => |a| blk: {
            items[0] = .{ .u64 = 1 };
            items[1] = .{ .u64 = a.version };
            items[2] = a.version_data;
            break :blk cbor.Term{ .array = items[0..3] };
        },
        .refuse => |r| blk: {
            items[0] = .{ .u64 = 2 };
            items[1] = r.reason;
            break :blk cbor.Term{ .array = items[0..2] };
        },
    };
    try cbor.encode(term, writer);
}

pub fn decodeMsg(alloc: std.mem.Allocator, reader: anytype) !HandshakeMsg {
    const term = try cbor.decode(alloc, reader);
    defer cbor.free(term, alloc);

    if (term != .array) return Error.UnsupportedTerm;
    const items = term.array;
    if (items.len < 2) return Error.InvalidLength;
    if (items[0] != .u64) return Error.InvalidType;

    return switch (items[0].u64) {
        0 => decodePropose(alloc, items),
        1 => decodeAccept(alloc, items),
        2 => decodeRefuse(alloc, items),
        else => Error.InvalidTag,
    };
}

pub fn free(alloc: std.mem.Allocator, msg: *HandshakeMsg) void {
    switch (msg.*) {
        .propose => |*p| cbor.free(p.versions, alloc),
        .accept => |*a| cbor.free(a.version_data, alloc),
        .refuse => |*r| cbor.free(r.reason, alloc),
    }
}

fn decodePropose(alloc: std.mem.Allocator, items: []cbor.Term) !HandshakeMsg {
    if (items.len != 2) return Error.InvalidLength;
    if (items[1] != .map_u64) return Error.InvalidType;
    const versions = try cloneTerm(alloc, items[1]);
    return HandshakeMsg{ .propose = .{ .versions = versions } };
}

fn decodeAccept(alloc: std.mem.Allocator, items: []cbor.Term) !HandshakeMsg {
    if (items.len != 3) return Error.InvalidLength;
    if (items[1] != .u64) return Error.InvalidType;
    const data = try cloneTerm(alloc, items[2]);
    return HandshakeMsg{ .accept = .{ .version = items[1].u64, .version_data = data } };
}

fn decodeRefuse(alloc: std.mem.Allocator, items: []cbor.Term) !HandshakeMsg {
    if (items.len != 2) return Error.InvalidLength;
    const reason = try cloneTerm(alloc, items[1]);
    return HandshakeMsg{ .refuse = .{ .reason = reason } };
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

fn termEqual(a: cbor.Term, b: cbor.Term) bool {
    return switch (a) {
        .u64 => |av| b == .u64 and b.u64 == av,
        .i64 => |av| b == .i64 and b.i64 == av,
        .bool => |av| b == .bool and b.bool == av,
        .bytes => |ab| b == .bytes and std.mem.eql(u8, ab, b.bytes),
        .text => |at| b == .text and std.mem.eql(u8, at, b.text),
        .array => |aa| blk: {
            if (b != .array or b.array.len != aa.len) break :blk false;
            for (aa, 0..) |item, i| {
                if (!termEqual(item, b.array[i])) break :blk false;
            }
            break :blk true;
        },
        .map_u64 => |am| blk: {
            if (b != .map_u64 or b.map_u64.len != am.len) break :blk false;
            for (am, 0..) |e, i| {
                if (b.map_u64[i].key != e.key) break :blk false;
                if (!termEqual(e.value, b.map_u64[i].value)) break :blk false;
            }
            break :blk true;
        },
    };
}

fn msgEqual(a: HandshakeMsg, b: HandshakeMsg) bool {
    return switch (a) {
        .propose => |ap| b == .propose and termEqual(ap.versions, b.propose.versions),
        .accept => |aa| b == .accept and aa.version == b.accept.version and termEqual(aa.version_data, b.accept.version_data),
        .refuse => |ar| b == .refuse and termEqual(ar.reason, b.refuse.reason),
    };
}

fn encodeToBytes(alloc: std.mem.Allocator, msg: HandshakeMsg) ![]u8 {
    var list = std.ArrayList(u8).init(alloc);
    errdefer list.deinit();
    try encodeMsg(msg, list.writer());
    return list.toOwnedSlice();
}

test "handshake codec roundtrip propose/accept/refuse" {
    const alloc = std.testing.allocator;

    const vdata_bytes = try alloc.dupe(u8, "vdata");
    var versions = try alloc.alloc(cbor.MapEntry, 2);
    versions[0] = .{ .key = 1, .value = .{ .u64 = 100 } };
    versions[1] = .{ .key = 2, .value = .{ .bytes = vdata_bytes } };

    var propose_msg = HandshakeMsg{ .propose = .{ .versions = .{ .map_u64 = versions } } };
    const b1 = try encodeToBytes(alloc, propose_msg);
    defer alloc.free(b1);
    var fbs1 = std.io.fixedBufferStream(b1);
    var d1 = try decodeMsg(alloc, fbs1.reader());
    defer free(alloc, &d1);
    try std.testing.expect(msgEqual(propose_msg, d1));
    const b1b = try encodeToBytes(alloc, d1);
    defer alloc.free(b1b);
    try std.testing.expect(std.mem.eql(u8, b1, b1b));
    free(alloc, &propose_msg);

    var data_items: [1]cbor.Term = .{.{ .text = "ok" }};
    const accept_msg = HandshakeMsg{
        .accept = .{
            .version = 3,
            .version_data = .{ .array = data_items[0..] },
        },
    };
    const b2 = try encodeToBytes(alloc, accept_msg);
    defer alloc.free(b2);
    var fbs2 = std.io.fixedBufferStream(b2);
    var d2 = try decodeMsg(alloc, fbs2.reader());
    defer free(alloc, &d2);
    try std.testing.expect(msgEqual(accept_msg, d2));

    const refuse_reason = cbor.Term{ .u64 = 7 };
    const refuse_msg = HandshakeMsg{ .refuse = .{ .reason = refuse_reason } };
    const b3 = try encodeToBytes(alloc, refuse_msg);
    defer alloc.free(b3);
    var fbs3 = std.io.fixedBufferStream(b3);
    var d3 = try decodeMsg(alloc, fbs3.reader());
    defer free(alloc, &d3);
    try std.testing.expect(msgEqual(refuse_msg, d3));
}
