const std = @import("std");
const cbor = @import("net/cbor/term.zig");
const hs = @import("net/handshake/handshake_codec.zig");

fn encodeMsgToBytes(alloc: std.mem.Allocator, msg: hs.HandshakeMsg) ![]u8 {
    var list = std.ArrayList(u8).init(alloc);
    errdefer list.deinit();
    try hs.encodeMsg(msg, list.writer());
    return list.toOwnedSlice();
}

test "handshake codec roundtrip bytes equality propose/accept/refuse" {
    const alloc = std.testing.allocator;

    var map_entries = try alloc.alloc(cbor.MapEntry, 1);
    map_entries[0] = .{ .key = 14, .value = .{ .u64 = 0 } };
    var propose_msg = hs.HandshakeMsg{ .propose = .{ .versions = .{ .map_u64 = map_entries } } };

    const b1 = try encodeMsgToBytes(alloc, propose_msg);
    defer alloc.free(b1);
    var fbs1 = std.io.fixedBufferStream(b1);
    var d1 = try hs.decodeMsg(alloc, fbs1.reader());
    defer hs.free(alloc, &d1);
    const b1b = try encodeMsgToBytes(alloc, d1);
    defer alloc.free(b1b);
    try std.testing.expect(std.mem.eql(u8, b1, b1b));
    hs.free(alloc, &propose_msg);

    const accept_msg = hs.HandshakeMsg{
        .accept = .{
            .version = 14,
            .version_data = .{ .u64 = 0 },
        },
    };
    const b2 = try encodeMsgToBytes(alloc, accept_msg);
    defer alloc.free(b2);
    var fbs2 = std.io.fixedBufferStream(b2);
    var d2 = try hs.decodeMsg(alloc, fbs2.reader());
    defer hs.free(alloc, &d2);
    const b2b = try encodeMsgToBytes(alloc, d2);
    defer alloc.free(b2b);
    try std.testing.expect(std.mem.eql(u8, b2, b2b));

    const refuse_msg = hs.HandshakeMsg{ .refuse = .{ .reason = .{ .u64 = 0 } } };
    const b3 = try encodeMsgToBytes(alloc, refuse_msg);
    defer alloc.free(b3);
    var fbs3 = std.io.fixedBufferStream(b3);
    var d3 = try hs.decodeMsg(alloc, fbs3.reader());
    defer hs.free(alloc, &d3);
    const b3b = try encodeMsgToBytes(alloc, d3);
    defer alloc.free(b3b);
    try std.testing.expect(std.mem.eql(u8, b3, b3b));
}

test "handshake codec decode rejects wrong tag" {
    const alloc = std.testing.allocator;

    const bad = cbor.Term{ .array = @constCast((&[_]cbor.Term{ .{ .u64 = 9 }, .{ .u64 = 0 } })[0..]) };
    var list = std.ArrayList(u8).init(alloc);
    errdefer list.deinit();
    try cbor.encode(bad, list.writer());
    const bytes = try list.toOwnedSlice();
    defer alloc.free(bytes);

    var fbs = std.io.fixedBufferStream(bytes);
    try std.testing.expectError(hs.Error.InvalidTag, hs.decodeMsg(alloc, fbs.reader()));
}

test "handshake codec decode rejects wrong length" {
    const alloc = std.testing.allocator;

    const bad = cbor.Term{ .array = @constCast((&[_]cbor.Term{ .{ .u64 = 1 }, .{ .u64 = 14 } })[0..]) };
    var list = std.ArrayList(u8).init(alloc);
    errdefer list.deinit();
    try cbor.encode(bad, list.writer());
    const bytes = try list.toOwnedSlice();
    defer alloc.free(bytes);

    var fbs = std.io.fixedBufferStream(bytes);
    try std.testing.expectError(hs.Error.InvalidLength, hs.decodeMsg(alloc, fbs.reader()));
}

test "handshake codec decode rejects wrong type" {
    const alloc = std.testing.allocator;

    const bad = cbor.Term{ .array = @constCast((&[_]cbor.Term{ .{ .u64 = 0 }, .{ .u64 = 1 } })[0..]) };
    var list = std.ArrayList(u8).init(alloc);
    errdefer list.deinit();
    try cbor.encode(bad, list.writer());
    const bytes = try list.toOwnedSlice();
    defer alloc.free(bytes);

    var fbs = std.io.fixedBufferStream(bytes);
    try std.testing.expectError(hs.Error.InvalidType, hs.decodeMsg(alloc, fbs.reader()));
}
