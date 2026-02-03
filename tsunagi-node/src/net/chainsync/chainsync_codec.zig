const std = @import("std");
const cbor = @import("../cbor/term.zig");

pub const Error = error{
    InvalidType,
    InvalidLength,
    InvalidTag,
};

pub const FindIntersect = struct {
    points: cbor.Term,
};

pub const IntersectFound = struct {
    payload: cbor.Term,
};

pub const IntersectNotFound = struct {
    payload: cbor.Term,
};

pub const Msg = union(enum) {
    find_intersect: FindIntersect,
    intersect_found: IntersectFound,
    intersect_not_found: IntersectNotFound,
};

pub fn encodeFindIntersect(writer: anytype, points: cbor.Term) anyerror!void {
    if (points != .array) return error.InvalidType;

    var items: [2]cbor.Term = undefined;
    items[0] = .{ .u64 = 0 };
    items[1] = points;

    const term = cbor.Term{ .array = items[0..2] };
    try cbor.encode(term, writer);
}

pub fn decodeResponse(alloc: std.mem.Allocator, reader: anytype) anyerror!Msg {
    const term = try cbor.decode(alloc, reader);
    defer cbor.free(term, alloc);

    if (term != .array) return error.InvalidType;
    const items = term.array;
    if (items.len < 1) return error.InvalidLength;
    if (items[0] != .u64) return error.InvalidType;

    return switch (items[0].u64) {
        1 => blk: {
            if (items.len < 2) return error.InvalidLength;
            const payload = try cloneTerm(alloc, items[1]);
            break :blk Msg{ .intersect_found = .{ .payload = payload } };
        },
        2 => blk: {
            if (items.len < 2) return error.InvalidLength;
            const payload = try cloneTerm(alloc, items[1]);
            break :blk Msg{ .intersect_not_found = .{ .payload = payload } };
        },
        else => error.InvalidTag,
    };
}

pub fn free(alloc: std.mem.Allocator, msg: *Msg) void {
    switch (msg.*) {
        .find_intersect => |*m| cbor.free(m.points, alloc),
        .intersect_found => |*m| cbor.free(m.payload, alloc),
        .intersect_not_found => |*m| cbor.free(m.payload, alloc),
    }
}

fn cloneTerm(alloc: std.mem.Allocator, term: cbor.Term) !cbor.Term {
    return switch (term) {
        .u64 => |v| cbor.Term{ .u64 = v },
        .i64 => |v| cbor.Term{ .i64 = v },
        .bool => |v| cbor.Term{ .bool = v },
        .bytes => |b| cbor.Term{ .bytes = try alloc.dupe(u8, b) },
        .text => |t| cbor.Term{ .text = try alloc.dupe(u8, t) },
        .array => |items| blk: {
            var out = try alloc.alloc(cbor.Term, items.len);
            errdefer {
                for (out) |item| cbor.free(item, alloc);
                alloc.free(out);
            }
            for (items, 0..) |item, i| {
                out[i] = try cloneTerm(alloc, item);
            }
            break :blk cbor.Term{ .array = out };
        },
        .map_u64 => |entries| blk: {
            var out = try alloc.alloc(cbor.MapEntry, entries.len);
            errdefer {
                for (out) |e| cbor.free(e.value, alloc);
                alloc.free(out);
            }
            for (entries, 0..) |e, i| {
                out[i] = .{ .key = e.key, .value = try cloneTerm(alloc, e.value) };
            }
            break :blk cbor.Term{ .map_u64 = out };
        },
    };
}
