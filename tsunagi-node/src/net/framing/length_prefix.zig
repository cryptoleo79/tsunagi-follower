const std = @import("std");

pub const FrameError = error{
    IncompleteHeader,
    IncompletePayload,
    PayloadTooLarge,
};

/// Encode a frame as: [u32 length][payload]
pub fn encode(alloc: std.mem.Allocator, payload: []const u8) ![]u8 {
    if (payload.len > std.math.maxInt(u32)) return FrameError.PayloadTooLarge;

    const total = 4 + payload.len;
    const out = try alloc.alloc(u8, total);

    std.mem.writeInt(u32, out[0..4], @intCast(payload.len), .big);
    @memcpy(out[4..], payload);
    return out;
}

/// Attempt to decode a frame from `buf`.
/// Returns `{ payload, consumed }` if a full frame is present.
/// Returns null if not enough data yet.
pub fn decode(buf: []const u8) FrameError!?struct {
    payload: []const u8,
    consumed: usize,
} {
    if (buf.len < 4) return FrameError.IncompleteHeader;

    const len = std.mem.readInt(u32, buf[0..4], .big);
    const need = 4 + @as(usize, len);

    if (buf.len < need) return FrameError.IncompletePayload;

    return .{
        .payload = buf[4..need],
        .consumed = need,
    };
}
