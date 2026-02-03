const std = @import("std");

pub const MiniProtocolDir = enum(u1) {
    responder = 0,
    initiator = 1,
};

pub const Header = struct {
    tx_time: u32,
    dir: MiniProtocolDir,
    proto: u16,
    len: u16,
};

pub const Error = error{
    BufferTooSmall,
    ProtoOutOfRange,
};

pub fn encode(h: Header, out: *[8]u8) Error!void {
    if (h.proto > 0x7FFF) return error.ProtoOutOfRange;

    const proto_field: u16 = (@as(u16, @intFromEnum(h.dir)) << 15) | h.proto;

    std.mem.writeInt(u32, out[0..4], h.tx_time, .big);
    std.mem.writeInt(u16, out[4..6], proto_field, .big);
    std.mem.writeInt(u16, out[6..8], h.len, .big);
}

pub fn decode(buf: []const u8) Error!Header {
    if (buf.len < 8) return error.BufferTooSmall;

    const tx_time = std.mem.readInt(u32, buf[0..4], .big);
    const proto_field = std.mem.readInt(u16, buf[4..6], .big);
    const len = std.mem.readInt(u16, buf[6..8], .big);

    const dir = @as(MiniProtocolDir, @enumFromInt(@as(u1, @intCast(proto_field >> 15))));
    const proto: u16 = proto_field & 0x7FFF;

    return .{ .tx_time = tx_time, .dir = dir, .proto = proto, .len = len };
}
