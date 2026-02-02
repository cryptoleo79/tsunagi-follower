const std = @import("std");
const framing = @import("net/framing/length_prefix.zig");

test "encode/decode roundtrip" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const msg = "hello-tsunagi";
    const frame = try framing.encode(alloc, msg);
    defer alloc.free(frame);

    const res = try framing.decode(frame);
    try std.testing.expect(res != null);
    try std.testing.expectEqualStrings(msg, res.?.payload);
    try std.testing.expectEqual(frame.len, res.?.consumed);
}

test "decode handles partial header" {
    const buf = [_]u8{0x00, 0x00};
    try std.testing.expectError(framing.FrameError.IncompleteHeader, framing.decode(&buf));
}

test "decode handles partial payload" {
    // length=5 but only 2 bytes payload
    const buf = [_]u8{0,0,0,5,'h','i'};
    try std.testing.expectError(framing.FrameError.IncompletePayload, framing.decode(&buf));
}

test "decode multiple frames back-to-back" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const a = try framing.encode(alloc, "a");
    const b = try framing.encode(alloc, "bb");
    defer alloc.free(a);
    defer alloc.free(b);

    var combo = try alloc.alloc(u8, a.len + b.len);
    defer alloc.free(combo);

    @memcpy(combo[0..a.len], a);
    @memcpy(combo[a.len..], b);

    const r1 = try framing.decode(combo);
    try std.testing.expectEqualStrings("a", r1.?.payload);

    const r2 = try framing.decode(combo[r1.?.consumed..]);
    try std.testing.expectEqualStrings("bb", r2.?.payload);
}
