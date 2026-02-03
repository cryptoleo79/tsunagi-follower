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

pub const RequestNext = struct {};

pub const AwaitReply = struct {};

pub const IntersectFound = struct {
    point: cbor.Term,
    tip: cbor.Term,
};

pub const IntersectNotFound = struct {
    tip: cbor.Term,
};

pub const RollForward = struct {
    block: cbor.Term,
    tip: cbor.Term,
};

pub const RollBackward = struct {
    point: cbor.Term,
    tip: cbor.Term,
};

pub const Msg = union(enum) {
    find_intersect: FindIntersect,
    request_next: RequestNext,
    await_reply: AwaitReply,
    intersect_found: IntersectFound,
    intersect_not_found: IntersectNotFound,
    roll_forward: RollForward,
    roll_backward: RollBackward,
};

pub fn encodeFindIntersect(writer: anytype, points: cbor.Term) anyerror!void {
    if (points != .array) return error.InvalidType;

    var items: [2]cbor.Term = undefined;
    items[0] = .{ .u64 = 4 };
    items[1] = points;

    const term = cbor.Term{ .array = items[0..2] };
    try cbor.encode(term, writer);
}

pub fn encodeRequestNext(writer: anytype) anyerror!void {
    var items: [1]cbor.Term = undefined;
    items[0] = .{ .u64 = 0 };
    const term = cbor.Term{ .array = items[0..1] };
    try cbor.encode(term, writer);
}

pub fn decodeResponse(alloc: std.mem.Allocator, reader: anytype) anyerror!Msg {
    const term = try cbor.decode(alloc, reader);
    defer cbor.free(term, alloc);

    if (term != .array) return error.InvalidType;
    const items = term.array;
    if (items.len == 0) return error.InvalidLength;
    if (items[0] != .u64) return error.InvalidType;

    return switch (items[0].u64) {
        1 => blk: {
            if (items.len != 1) return error.InvalidLength;
            break :blk Msg{ .await_reply = .{} };
        },
        2 => blk: {
            if (items.len != 3) return error.InvalidLength;
            const block = try cloneTerm(alloc, items[1]);
            const tip = try cloneTerm(alloc, items[2]);
            break :blk Msg{ .roll_forward = .{ .block = block, .tip = tip } };
        },
        3 => blk: {
            if (items.len != 3) return error.InvalidLength;
            const point = try cloneTerm(alloc, items[1]);
            const tip = try cloneTerm(alloc, items[2]);
            break :blk Msg{ .roll_backward = .{ .point = point, .tip = tip } };
        },
        5 => blk: {
            if (items.len != 3) return error.InvalidLength;
            const point = try cloneTerm(alloc, items[1]);
            const tip = try cloneTerm(alloc, items[2]);
            break :blk Msg{ .intersect_found = .{ .point = point, .tip = tip } };
        },
        6 => blk: {
            if (items.len != 2) return error.InvalidLength;
            const tip = try cloneTerm(alloc, items[1]);
            break :blk Msg{ .intersect_not_found = .{ .tip = tip } };
        },
        else => error.InvalidTag,
    };
}

pub fn free(alloc: std.mem.Allocator, msg: *Msg) void {
    switch (msg.*) {
        .find_intersect => |*m| cbor.free(m.points, alloc),
        .request_next => {},
        .await_reply => {},
        .intersect_found => |*m| {
            cbor.free(m.point, alloc);
            cbor.free(m.tip, alloc);
        },
        .intersect_not_found => |*m| cbor.free(m.tip, alloc),
        .roll_forward => |*m| {
            cbor.free(m.block, alloc);
            cbor.free(m.tip, alloc);
        },
        .roll_backward => |*m| {
            cbor.free(m.point, alloc);
            cbor.free(m.tip, alloc);
        },
    }
}

fn cloneTerm(alloc: std.mem.Allocator, term: cbor.Term) !cbor.Term {
    return switch (term) {
        .u64 => |v| cbor.Term{ .u64 = v },
        .i64 => |v| cbor.Term{ .i64 = v },
        .bool => |v| cbor.Term{ .bool = v },
        .null => cbor.Term{ .null = {} },
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
        .tag => |t| blk: {
            const value = try alloc.create(cbor.Term);
            errdefer alloc.destroy(value);
            value.* = try cloneTerm(alloc, t.value.*);
            break :blk cbor.Term{ .tag = .{ .tag = t.tag, .value = value } };
        },
    };
}
