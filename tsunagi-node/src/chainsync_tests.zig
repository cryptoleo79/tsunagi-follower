const std = @import("std");

const cbor = @import("net/cbor/term.zig");
const chainsync_codec = @import("net/chainsync/chainsync_codec.zig");

fn encodeToBytes(alloc: std.mem.Allocator, term: cbor.Term) ![]u8 {
    var list = std.ArrayList(u8).init(alloc);
    errdefer list.deinit();
    try cbor.encode(term, list.writer());
    return list.toOwnedSlice();
}

test "chainsync find intersect encode golden" {
    const alloc = std.testing.allocator;

    const empty_points = cbor.Term{ .array = @constCast((&[_]cbor.Term{})[0..]) };

    var list = std.ArrayList(u8).init(alloc);
    defer list.deinit();
    try chainsync_codec.encodeFindIntersect(list.writer(), empty_points);
    const bytes = try list.toOwnedSlice();
    defer alloc.free(bytes);

    const expected = [_]u8{ 0x82, 0x04, 0x80 };
    try std.testing.expectEqualSlices(u8, &expected, bytes);
}

test "chainsync decode intersect responses" {
    const alloc = std.testing.allocator;

    const found_term = cbor.Term{ .array = @constCast((&[_]cbor.Term{ .{ .u64 = 5 }, .{ .u64 = 42 } })[0..]) };
    const not_found_term = cbor.Term{ .array = @constCast((&[_]cbor.Term{ .{ .u64 = 6 }, .{ .text = @constCast("nope") } })[0..]) };

    const found_bytes = try encodeToBytes(alloc, found_term);
    defer alloc.free(found_bytes);
    var fbs1 = std.io.fixedBufferStream(found_bytes);
    var msg1 = try chainsync_codec.decodeResponse(alloc, fbs1.reader());
    defer chainsync_codec.free(alloc, &msg1);

    try std.testing.expect(msg1 == .intersect_found);
    try std.testing.expect(msg1.intersect_found.payload == .u64);
    try std.testing.expectEqual(@as(u64, 42), msg1.intersect_found.payload.u64);

    const not_found_bytes = try encodeToBytes(alloc, not_found_term);
    defer alloc.free(not_found_bytes);
    var fbs2 = std.io.fixedBufferStream(not_found_bytes);
    var msg2 = try chainsync_codec.decodeResponse(alloc, fbs2.reader());
    defer chainsync_codec.free(alloc, &msg2);

    try std.testing.expect(msg2 == .intersect_not_found);
    try std.testing.expect(msg2.intersect_not_found.payload == .text);
    try std.testing.expect(std.mem.eql(u8, "nope", msg2.intersect_not_found.payload.text));
}
