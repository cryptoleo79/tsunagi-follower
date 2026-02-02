const std = @import("std");
const Message = @import("../protocol/message.zig").Message;

/// Very simple codec for now:
/// encode as UTF-8 tag names.
/// This is temporary and test-only; CBOR comes later.
pub fn encode(alloc: std.mem.Allocator, msg: Message) ![]u8 {
    return switch (msg) {
        .chainsync => |m| alloc.dupe(u8, @tagName(m)),
        .blockfetch => |m| alloc.dupe(u8, @tagName(m)),
    };
}

pub fn decode(data: []const u8) !Message {
    if (std.mem.eql(u8, data, "find_intersect"))
        return .{ .chainsync = .find_intersect };
    if (std.mem.eql(u8, data, "request_next"))
        return .{ .chainsync = .request_next };
    if (std.mem.eql(u8, data, "request_range"))
        return .{ .blockfetch = .request_range };

    return error.UnknownMessage;
}
