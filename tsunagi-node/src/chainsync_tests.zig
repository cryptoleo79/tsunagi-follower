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

test "chainsync request next encode golden" {
    const alloc = std.testing.allocator;

    var list = std.ArrayList(u8).init(alloc);
    defer list.deinit();
    try chainsync_codec.encodeRequestNext(list.writer());
    const bytes = try list.toOwnedSlice();
    defer alloc.free(bytes);

    const expected = [_]u8{ 0x81, 0x00 };
    try std.testing.expectEqualSlices(u8, &expected, bytes);
}

test "chainsync decode intersect responses" {
    const alloc = std.testing.allocator;

    const found_term = cbor.Term{
        .array = @constCast((&[_]cbor.Term{
            .{ .u64 = 5 },
            .{ .u64 = 42 },
            .{ .text = @constCast("tip") },
        })[0..]),
    };
    const not_found_term = cbor.Term{ .array = @constCast((&[_]cbor.Term{ .{ .u64 = 6 }, .{ .text = @constCast("nope") } })[0..]) };

    const found_bytes = try encodeToBytes(alloc, found_term);
    defer alloc.free(found_bytes);
    var fbs1 = std.io.fixedBufferStream(found_bytes);
    var msg1 = try chainsync_codec.decodeResponse(alloc, fbs1.reader());
    defer chainsync_codec.free(alloc, &msg1);

    try std.testing.expect(msg1 == .intersect_found);
    try std.testing.expect(msg1.intersect_found.point == .u64);
    try std.testing.expectEqual(@as(u64, 42), msg1.intersect_found.point.u64);
    try std.testing.expect(msg1.intersect_found.tip == .text);
    try std.testing.expect(std.mem.eql(u8, "tip", msg1.intersect_found.tip.text));

    const not_found_bytes = try encodeToBytes(alloc, not_found_term);
    defer alloc.free(not_found_bytes);
    var fbs2 = std.io.fixedBufferStream(not_found_bytes);
    var msg2 = try chainsync_codec.decodeResponse(alloc, fbs2.reader());
    defer chainsync_codec.free(alloc, &msg2);

    try std.testing.expect(msg2 == .intersect_not_found);
    try std.testing.expect(msg2.intersect_not_found.tip == .text);
    try std.testing.expect(std.mem.eql(u8, "nope", msg2.intersect_not_found.tip.text));
}

test "chainsync decode roll forward/backward responses" {
    const alloc = std.testing.allocator;

    const roll_forward_term = cbor.Term{ .array = @constCast((&[_]cbor.Term{ .{ .u64 = 2 }, .{ .u64 = 7 }, .{ .u64 = 8 } })[0..]) };
    const roll_backward_term = cbor.Term{ .array = @constCast((&[_]cbor.Term{ .{ .u64 = 3 }, .{ .text = @constCast("rewind") }, .{ .u64 = 9 } })[0..]) };

    const forward_bytes = try encodeToBytes(alloc, roll_forward_term);
    defer alloc.free(forward_bytes);
    var fbs1 = std.io.fixedBufferStream(forward_bytes);
    var msg1 = try chainsync_codec.decodeResponse(alloc, fbs1.reader());
    defer chainsync_codec.free(alloc, &msg1);

    try std.testing.expect(msg1 == .roll_forward);
    try std.testing.expect(msg1.roll_forward.block == .u64);
    try std.testing.expectEqual(@as(u64, 7), msg1.roll_forward.block.u64);
    try std.testing.expect(msg1.roll_forward.tip == .u64);
    try std.testing.expectEqual(@as(u64, 8), msg1.roll_forward.tip.u64);

    const backward_bytes = try encodeToBytes(alloc, roll_backward_term);
    defer alloc.free(backward_bytes);
    var fbs2 = std.io.fixedBufferStream(backward_bytes);
    var msg2 = try chainsync_codec.decodeResponse(alloc, fbs2.reader());
    defer chainsync_codec.free(alloc, &msg2);

    try std.testing.expect(msg2 == .roll_backward);
    try std.testing.expect(msg2.roll_backward.point == .text);
    try std.testing.expect(std.mem.eql(u8, "rewind", msg2.roll_backward.point.text));
    try std.testing.expect(msg2.roll_backward.tip == .u64);
    try std.testing.expectEqual(@as(u64, 9), msg2.roll_backward.tip.u64);
}

test "chainsync decode await reply response" {
    const alloc = std.testing.allocator;

    const await_term = cbor.Term{ .array = @constCast((&[_]cbor.Term{.{ .u64 = 1 }})[0..]) };
    const await_bytes = try encodeToBytes(alloc, await_term);
    defer alloc.free(await_bytes);

    var fbs = std.io.fixedBufferStream(await_bytes);
    var msg = try chainsync_codec.decodeResponse(alloc, fbs.reader());
    defer chainsync_codec.free(alloc, &msg);

    try std.testing.expect(msg == .await_reply);
}

test "chainsync decode roll forward/backward placeholders" {
    const alloc = std.testing.allocator;

    const roll_forward_term = cbor.Term{ .array = @constCast((&[_]cbor.Term{ .{ .u64 = 2 }, .{ .u64 = 0 }, .{ .u64 = 0 } })[0..]) };
    const roll_backward_term = cbor.Term{ .array = @constCast((&[_]cbor.Term{ .{ .u64 = 3 }, .{ .u64 = 0 }, .{ .u64 = 0 } })[0..]) };

    const forward_bytes = try encodeToBytes(alloc, roll_forward_term);
    defer alloc.free(forward_bytes);
    var fbs1 = std.io.fixedBufferStream(forward_bytes);
    var msg1 = try chainsync_codec.decodeResponse(alloc, fbs1.reader());
    defer chainsync_codec.free(alloc, &msg1);

    try std.testing.expect(msg1 == .roll_forward);
    try std.testing.expect(msg1.roll_forward.block == .u64);
    try std.testing.expectEqual(@as(u64, 0), msg1.roll_forward.block.u64);
    try std.testing.expect(msg1.roll_forward.tip == .u64);
    try std.testing.expectEqual(@as(u64, 0), msg1.roll_forward.tip.u64);

    const backward_bytes = try encodeToBytes(alloc, roll_backward_term);
    defer alloc.free(backward_bytes);
    var fbs2 = std.io.fixedBufferStream(backward_bytes);
    var msg2 = try chainsync_codec.decodeResponse(alloc, fbs2.reader());
    defer chainsync_codec.free(alloc, &msg2);

    try std.testing.expect(msg2 == .roll_backward);
    try std.testing.expect(msg2.roll_backward.point == .u64);
    try std.testing.expectEqual(@as(u64, 0), msg2.roll_backward.point.u64);
    try std.testing.expect(msg2.roll_backward.tip == .u64);
    try std.testing.expectEqual(@as(u64, 0), msg2.roll_backward.tip.u64);
}
