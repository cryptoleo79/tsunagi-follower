const std = @import("std");

pub const Cbor = struct {
    // Minimal CBOR for what we need now:
    // - unsigned ints
    // - bytes
    // - text
    // - arrays
    // - maps (length only; key/value handled by caller)

    pub fn writeUInt(w: anytype, x: u64) !void {
        try writeMajor(w, 0, x);
    }

    pub fn writeBytes(w: anytype, b: []const u8) !void {
        try writeMajor(w, 2, b.len);
        try w.writeAll(b);
    }

    pub fn writeText(w: anytype, s: []const u8) !void {
        try writeMajor(w, 3, s.len);
        try w.writeAll(s);
    }

    pub fn writeArrayLen(w: anytype, n: usize) !void {
        try writeMajor(w, 4, n);
    }

    pub fn writeMapLen(w: anytype, n: usize) !void {
        try writeMajor(w, 5, n);
    }

    fn writeMajor(w: anytype, major: u8, val: u64) !void {
        if (val <= 23) {
            const b: u8 = (@as(u8, major) << 5) | @as(u8, @intCast(val));
            try w.writeByte(b);
            return;
        }
        if (val <= 0xff) {
            try w.writeByte((@as(u8, major) << 5) | 24);
            try w.writeByte(@as(u8, @intCast(val)));
            return;
        }
        if (val <= 0xffff) {
            try w.writeByte((@as(u8, major) << 5) | 25);
            var buf: [2]u8 = undefined;
            std.mem.writeInt(u16, &buf, @as(u16, @intCast(val)), .big);
            try w.writeAll(&buf);
            return;
        }
        if (val <= 0xffff_ffff) {
            try w.writeByte((@as(u8, major) << 5) | 26);
            var buf: [4]u8 = undefined;
            std.mem.writeInt(u32, &buf, @as(u32, @intCast(val)), .big);
            try w.writeAll(&buf);
            return;
        }
        try w.writeByte((@as(u8, major) << 5) | 27);
        var buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &buf, val, .big);
        try w.writeAll(&buf);
    }
};
