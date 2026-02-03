const std = @import("std");

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
