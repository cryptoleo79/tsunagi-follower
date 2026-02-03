const std = @import("std");

pub const MapEntry = struct { key: u64, value: Term };

pub const Term = union(enum) {
    u64: u64,
    i64: i64,
    bool: bool,
    bytes: []const u8,
    text: []const u8,
    array: []Term,
    map_u64: []MapEntry,
};

pub fn encode(term: Term, writer: anytype) !void {
    switch (term) {
        .u64 => |v| try encodeUnsigned(v, writer),
        .i64 => |v| {
            if (v < 0) {
                const n: u64 = @intCast(@as(i128, -1) - @as(i128, v));
                try encodeTypeAndLen(1, n, writer);
            } else {
                try encodeUnsigned(@intCast(v), writer);
            }
        },
        .bool => |v| try writer.writeByte(if (v) 0xF5 else 0xF4),
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
        .i64 => {},
        .bool => {},
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

    return switch (major) {
        0 => Term{ .u64 = try decodeLen(addl, reader) },
        1 => blk: {
            const len = try decodeLen(addl, reader);
            if (len > @as(u64, std.math.maxInt(i64))) return error.IntOutOfRange;
            const signed = @as(i64, -1) - @as(i64, @intCast(len));
            break :blk Term{ .i64 = signed };
        },
        2 => blk: {
            const len = try decodeLen(addl, reader);
            const bytes = try alloc.alloc(u8, @intCast(len));
            errdefer alloc.free(bytes);
            try reader.readNoEof(bytes);
            break :blk Term{ .bytes = bytes };
        },
        3 => blk: {
            const len = try decodeLen(addl, reader);
            const text = try alloc.alloc(u8, @intCast(len));
            errdefer alloc.free(text);
            try reader.readNoEof(text);
            break :blk Term{ .text = text };
        },
        4 => blk: {
            const len = try decodeLen(addl, reader);
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
            const len = try decodeLen(addl, reader);
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
        6 => blk: {
            const raw = try decodeUnsupportedAsBytes(alloc, reader, initial);
            break :blk Term{ .bytes = raw };
        },
        7 => switch (addl) {
            20 => Term{ .bool = false },
            21 => Term{ .bool = true },
            else => blk: {
                const raw = try decodeUnsupportedAsBytes(alloc, reader, initial);
                break :blk Term{ .bytes = raw };
            },
        },
        else => return error.UnsupportedCborType,
    };
}

fn decodeUnsupportedAsBytes(
    alloc: std.mem.Allocator,
    reader: anytype,
    initial: u8,
) anyerror![]u8 {
    var list = std.ArrayList(u8).init(alloc);
    errdefer list.deinit();
    try list.append(initial);
    try appendRawItemFromInitial(&list, reader, initial);
    return list.toOwnedSlice();
}

fn appendRawItemFromInitial(list: *std.ArrayList(u8), reader: anytype, initial: u8) anyerror!void {
    const major = initial >> 5;
    const addl = initial & 0x1f;
    switch (major) {
        0, 1 => {
            _ = try readLenWithBytes(addl, reader, list);
        },
        2, 3 => {
            const len = try readLenWithBytes(addl, reader, list);
            try readPayloadBytes(@intCast(len), reader, list);
        },
        4 => {
            const count = try readLenWithBytes(addl, reader, list);
            var i: u64 = 0;
            while (i < count) : (i += 1) {
                try appendRawItem(list, reader);
            }
        },
        5 => {
            const count = try readLenWithBytes(addl, reader, list);
            var i: u64 = 0;
            while (i < count) : (i += 1) {
                try appendRawItem(list, reader);
                try appendRawItem(list, reader);
            }
        },
        6 => {
            _ = try readLenWithBytes(addl, reader, list);
            try appendRawItem(list, reader);
        },
        7 => switch (addl) {
            24 => try readFixedBytes(1, reader, list),
            25 => try readFixedBytes(2, reader, list),
            26 => try readFixedBytes(4, reader, list),
            27 => try readFixedBytes(8, reader, list),
            else => {},
        },
        else => return error.UnsupportedCborType,
    }
}

fn appendRawItem(list: *std.ArrayList(u8), reader: anytype) anyerror!void {
    const initial = try reader.readByte();
    try list.append(initial);
    try appendRawItemFromInitial(list, reader, initial);
}

fn readLenWithBytes(addl: u8, reader: anytype, list: *std.ArrayList(u8)) anyerror!u64 {
    if (addl < 24) return addl;
    return switch (addl) {
        24 => blk: {
            const b = try reader.readByte();
            try list.append(b);
            break :blk b;
        },
        25 => blk: {
            var buf: [2]u8 = undefined;
            try reader.readNoEof(&buf);
            try list.appendSlice(&buf);
            break :blk std.mem.readInt(u16, &buf, .big);
        },
        26 => blk: {
            var buf: [4]u8 = undefined;
            try reader.readNoEof(&buf);
            try list.appendSlice(&buf);
            break :blk std.mem.readInt(u32, &buf, .big);
        },
        27 => blk: {
            var buf: [8]u8 = undefined;
            try reader.readNoEof(&buf);
            try list.appendSlice(&buf);
            break :blk std.mem.readInt(u64, &buf, .big);
        },
        else => return error.UnsupportedCborType,
    };
}

fn readFixedBytes(count: usize, reader: anytype, list: *std.ArrayList(u8)) anyerror!void {
    var buf: [8]u8 = undefined;
    var n: usize = 0;
    while (n < count) : (n += 1) {
        buf[n] = try reader.readByte();
    }
    try list.appendSlice(buf[0..count]);
}

fn readPayloadBytes(count: usize, reader: anytype, list: *std.ArrayList(u8)) anyerror!void {
    var remaining = count;
    var buf: [256]u8 = undefined;
    while (remaining > 0) {
        const chunk = @min(remaining, buf.len);
        try reader.readNoEof(buf[0..chunk]);
        try list.appendSlice(buf[0..chunk]);
        remaining -= chunk;
    }
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
        .i64 => |av| b == .i64 and b.i64 == av,
        .bool => |av| b == .bool and b.bool == av,
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

    const t2 = Term{ .i64 = -2 };
    const b3 = try encodeToBytes(alloc, t2);
    defer alloc.free(b3);

    var fbs2 = std.io.fixedBufferStream(b3);
    const d2 = try decode(alloc, fbs2.reader());
    defer free(d2, alloc);

    try std.testing.expect(termEqual(t2, d2));

    const t3 = Term{ .bool = true };
    const b4 = try encodeToBytes(alloc, t3);
    defer alloc.free(b4);

    var fbs3 = std.io.fixedBufferStream(b4);
    const d3 = try decode(alloc, fbs3.reader());
    defer free(d3, alloc);

    try std.testing.expect(termEqual(t3, d3));
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

test "cbor term decodes unsupported as bytes" {
    const alloc = std.testing.allocator;

    const input = [_]u8{ 0xC1, 0x00, 0x01 };
    var fbs = std.io.fixedBufferStream(&input);

    const t1 = try decode(alloc, fbs.reader());
    defer free(t1, alloc);
    try std.testing.expect(t1 == .bytes);
    try std.testing.expectEqualSlices(u8, input[0..2], t1.bytes);

    const t2 = try decode(alloc, fbs.reader());
    defer free(t2, alloc);
    try std.testing.expect(t2 == .u64);
    try std.testing.expectEqual(@as(u64, 1), t2.u64);
}
