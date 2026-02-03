const std = @import("std");

const memory_bt = @import("net/transport/memory_byte_transport.zig");
const mux_bearer = @import("net/muxwire/mux_bearer.zig");
const mux_header = @import("net/muxwire/mux_header.zig");

const Header = mux_header.Header;
const MiniProtocolDir = mux_header.MiniProtocolDir;

test "mux header encode golden" {
    var out: [8]u8 = undefined;
    try mux_header.encode(.{
        .tx_time = 0,
        .dir = .initiator,
        .proto = 0,
        .len = 3,
    }, &out);

    const expected = [_]u8{ 0x00, 0x00, 0x00, 0x00, 0x80, 0x00, 0x00, 0x03 };
    try std.testing.expectEqualSlices(u8, &expected, &out);
}

test "mux header roundtrip" {
    const original = Header{
        .tx_time = 1234,
        .dir = .responder,
        .proto = 14,
        .len = 9,
    };

    var out: [8]u8 = undefined;
    try mux_header.encode(original, &out);
    const decoded = try mux_header.decode(&out);

    try std.testing.expectEqual(original.tx_time, decoded.tx_time);
    try std.testing.expectEqual(original.dir, decoded.dir);
    try std.testing.expectEqual(original.proto, decoded.proto);
    try std.testing.expectEqual(original.len, decoded.len);
}

test "mux header decode rejects short buffer" {
    const too_short = [_]u8{ 0x00, 0x01, 0x02 };
    try std.testing.expectError(mux_header.Error.BufferTooSmall, mux_header.decode(&too_short));
}

test "mux header encode rejects out of range proto" {
    var out: [8]u8 = undefined;
    try std.testing.expectError(
        mux_header.Error.ProtoOutOfRange,
        mux_header.encode(.{
            .tx_time = 0,
            .dir = .responder,
            .proto = 0x8000,
            .len = 1,
        }, &out),
    );
}

test "mux bearer roundtrip send/recv" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var bt = memory_bt.init(alloc, 64);
    defer bt.deinit();

    const payload = "hello";
    try mux_bearer.sendSegment(&bt, .initiator, 14, payload);

    const res = try mux_bearer.recvSegment(alloc, &bt);
    try std.testing.expect(res != null);
    const seg = res.?;
    defer alloc.free(seg.payload);

    try std.testing.expectEqual(@as(u32, 0), seg.hdr.tx_time);
    try std.testing.expectEqual(mux_header.MiniProtocolDir.initiator, seg.hdr.dir);
    try std.testing.expectEqual(@as(u16, 14), seg.hdr.proto);
    try std.testing.expectEqual(@as(u16, payload.len), seg.hdr.len);
    try std.testing.expectEqualSlices(u8, payload, seg.payload);
}
