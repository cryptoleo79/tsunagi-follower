const std = @import("std");

pub const MapEntry = struct { key: u64, value: Term };

pub const Term = union(enum) {
    u64: u64,
    bytes: []const u8,
    text: []const u8,
    array: []Term,
    map_u64: []MapEntry,
};

pub fn encode(term: Term, writer: anytype) !void {
    switch (term) {
        .u64 => |v| try encodeUnsigned(v, writer),
        .bytes => |b| {
            try encodeTypeAndLen(2, b.len, writer);
            try writer.writeAll(b);
        },
        .text => |t| {
            try encodeTypeAndLen(3, t.len, writer);
            try writer.writeAll(t);
        },
        .array => |items| {
            try encodeTypeAndLen(4, items.len, writer);
            for (items) |item| try encode(item, writer);
        },
        .map_u64 => |entries| {
            try encodeTypeAndLen(5, entries.len, writer);
            for (entries) |e| {
                try encodeUnsigned(e.key, writer);
                try encode(e.value, writer);
            }
        },
    }
}

pub fn decode(alloc: std.mem.Allocator, reader: anytype) !Term {
    return decodeTerm(alloc, reader);
}

pub fn free(term: Term, alloc: std.mem.Allocator) void {
    switch (term) {
        .u64 => {},
        .bytes => |b| alloc.free(b),
        .text => |t| alloc.free(t),
        .array => |items| {
            for (items) |item| free(item, alloc);
            alloc.free(items);
        },
        .map_u64 => |entries| {
            for (entries) |e| free(e.value, alloc);
            alloc.free(entries);
        },
    }
}

fn encodeUnsigned(v: u64, writer: anytype) !void {
    try encodeTypeAndLen(0, v, writer);
}

fn encodeTypeAndLen(major: u8, len: u64, writer: anytype) !void {
    if (len <= 23) {
        try writer.writeByte(@as(u8, (major << 5) | @as(u8, @intCast(len))));
        return;
    }
    if (len <= 0xff) {
        try writer.writeByte(@as(u8, (major << 5) | 24));
        try writer.writeByte(@as(u8, @intCast(len)));
        return;
    }
    if (len <= 0xffff) {
        try writer.writeByte(@as(u8, (major << 5) | 25));
        var buf: [2]u8 = undefined;
        std.mem.writeInt(u16, &buf, @as(u16, @intCast(len)), .big);
        try writer.writeAll(&buf);
        return;
    }
    if (len <= 0xffff_ffff) {
        try writer.writeByte(@as(u8, (major << 5) | 26));
        var buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &buf, @as(u32, @intCast(len)), .big);
        try writer.writeAll(&buf);
        return;
    }
    try writer.writeByte(@as(u8, (major << 5) | 27));
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf, len, .big);
    try writer.writeAll(&buf);
}

fn decodeTerm(alloc: std.mem.Allocator, reader: anytype) !Term {
    const initial = try reader.readByte();
    const major = initial >> 5;
    const addl = initial & 0x1f;
    const len = try decodeLen(addl, reader);

    return switch (major) {
        0 => Term{ .u64 = len },
        2 => blk: {
            const bytes = try alloc.alloc(u8, @intCast(len));
            errdefer alloc.free(bytes);
            try reader.readNoEof(bytes);
            break :blk Term{ .bytes = bytes };
        },
        3 => blk: {
            const text = try alloc.alloc(u8, @intCast(len));
            errdefer alloc.free(text);
            try reader.readNoEof(text);
            break :blk Term{ .text = text };
        },
        4 => blk: {
            const count: usize = @intCast(len);
            const items = try alloc.alloc(Term, count);
            errdefer {
                for (items) |item| free(item, alloc);
                alloc.free(items);
            }
            var i: usize = 0;
            while (i < count) : (i += 1) {
                items[i] = try decodeTerm(alloc, reader);
            }
            break :blk Term{ .array = items };
        },
        5 => blk: {
            const count: usize = @intCast(len);
            const entries = try alloc.alloc(MapEntry, count);
            errdefer {
                for (entries) |e| free(e.value, alloc);
                alloc.free(entries);
            }
            var i: usize = 0;
            while (i < count) : (i += 1) {
                const key = try decodeUnsigned(reader);
                const value = try decodeTerm(alloc, reader);
                entries[i] = .{ .key = key, .value = value };
            }
            break :blk Term{ .map_u64 = entries };
        },
        else => return error.UnsupportedCborType,
    };
}

fn decodeUnsigned(reader: anytype) !u64 {
    const initial = try reader.readByte();
    const major = initial >> 5;
    const addl = initial & 0x1f;
    if (major != 0) return error.UnsupportedCborType;
    return decodeLen(addl, reader);
}

fn decodeLen(addl: u8, reader: anytype) !u64 {
    if (addl < 24) return addl;
    return switch (addl) {
        24 => try reader.readByte(),
        25 => blk: {
            var buf: [2]u8 = undefined;
            try reader.readNoEof(&buf);
            break :blk std.mem.readInt(u16, &buf, .big);
        },
        26 => blk: {
            var buf: [4]u8 = undefined;
            try reader.readNoEof(&buf);
            break :blk std.mem.readInt(u32, &buf, .big);
        },
        27 => blk: {
            var buf: [8]u8 = undefined;
            try reader.readNoEof(&buf);
            break :blk std.mem.readInt(u64, &buf, .big);
        },
        else => return error.UnsupportedCborType,
    };
}

fn termEqual(a: Term, b: Term) bool {
    return switch (a) {
        .u64 => |av| b == .u64 and b.u64 == av,
        .bytes => |ab| b == .bytes and std.mem.eql(u8, ab, b.bytes),
        .text => |at| b == .text and std.mem.eql(u8, at, b.text),
        .array => |aa| blk: {
            if (b != .array or b.array.len != aa.len) break :blk false;
            for (aa, 0..) |item, i| {
                if (!termEqual(item, b.array[i])) break :blk false;
            }
            break :blk true;
        },
        .map_u64 => |am| blk: {
            if (b != .map_u64 or b.map_u64.len != am.len) break :blk false;
            for (am, 0..) |e, i| {
                if (b.map_u64[i].key != e.key) break :blk false;
                if (!termEqual(e.value, b.map_u64[i].value)) break :blk false;
            }
            break :blk true;
        },
    };
}

fn encodeToBytes(alloc: std.mem.Allocator, term: Term) ![]u8 {
    var list = std.ArrayList(u8).init(alloc);
    errdefer list.deinit();
    try encode(term, list.writer());
    return list.toOwnedSlice();
}

test "cbor term encode/decode roundtrip scalars" {
    const alloc = std.testing.allocator;

    const t1 = Term{ .u64 = 42 };
    const b1 = try encodeToBytes(alloc, t1);
    defer alloc.free(b1);

    var fbs = std.io.fixedBufferStream(b1);
    const d1 = try decode(alloc, fbs.reader());
    defer free(d1, alloc);

    try std.testing.expect(termEqual(t1, d1));

    const b2 = try encodeToBytes(alloc, d1);
    defer alloc.free(b2);
    try std.testing.expect(std.mem.eql(u8, b1, b2));
}

test "cbor term encode/decode roundtrip composite" {
    const alloc = std.testing.allocator;

    const bytes = try alloc.dupe(u8, "hi");
    const text = try alloc.dupe(u8, "tsunagi");

    var arr = try alloc.alloc(Term, 3);
    arr[0] = Term{ .u64 = 1 };
    arr[1] = Term{ .bytes = bytes };
    arr[2] = Term{ .text = text };

    var map = try alloc.alloc(MapEntry, 2);
    map[0] = .{ .key = 7, .value = Term{ .array = arr } };
    map[1] = .{ .key = 9, .value = Term{ .u64 = 1234 } };

    const t = Term{ .map_u64 = map };

    const b1 = try encodeToBytes(alloc, t);
    defer alloc.free(b1);

    var fbs = std.io.fixedBufferStream(b1);
    const d1 = try decode(alloc, fbs.reader());
    defer free(d1, alloc);

    try std.testing.expect(termEqual(t, d1));

    const b2 = try encodeToBytes(alloc, d1);
    defer alloc.free(b2);
    try std.testing.expect(std.mem.eql(u8, b1, b2));

    free(t, alloc);
}
