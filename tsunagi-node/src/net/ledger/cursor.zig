const std = @import("std");

pub const Cursor = struct {
    slot: u64,
    block_no: u64,
    tip_hash_hex: [64]u8,
    header_hash_hex: [64]u8,
    roll_forward_count: u64,
    roll_backward_count: u64,
    updated_unix: i64,
};

const CursorJson = struct {
    slot: ?u64 = null,
    block_no: ?u64 = null,
    tip_hash_hex: ?[]const u8 = null,
    header_hash_hex: ?[]const u8 = null,
    roll_forward_count: ?u64 = null,
    roll_backward_count: ?u64 = null,
    updated_unix: ?i64 = null,
};

fn copyHex(dest: *[64]u8, src: []const u8) !void {
    if (src.len != dest.len) return error.InvalidCursor;
    std.mem.copyForwards(u8, dest[0..], src);
}

fn zeroCursor() Cursor {
    var cursor = std.mem.zeroes(Cursor);
    @memset(cursor.tip_hash_hex[0..], '0');
    @memset(cursor.header_hash_hex[0..], '0');
    return cursor;
}

pub fn loadOrInit(alloc: std.mem.Allocator, path: []const u8) !Cursor {
    var file = std.fs.openFileAbsolute(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return zeroCursor(),
        else => return err,
    };
    defer file.close();

    const data = try file.readToEndAlloc(alloc, 1024 * 1024);
    defer alloc.free(data);

    var parsed = try std.json.parseFromSlice(CursorJson, alloc, data, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    var cursor = zeroCursor();
    const value = parsed.value;
    if (value.slot) |slot| cursor.slot = slot;
    if (value.block_no) |block_no| cursor.block_no = block_no;
    if (value.tip_hash_hex) |hex| try copyHex(&cursor.tip_hash_hex, hex);
    if (value.header_hash_hex) |hex| try copyHex(&cursor.header_hash_hex, hex);
    if (value.roll_forward_count) |count| cursor.roll_forward_count = count;
    if (value.roll_backward_count) |count| cursor.roll_backward_count = count;
    if (value.updated_unix) |ts| cursor.updated_unix = ts;

    return cursor;
}

pub fn save(cursor: Cursor, path: []const u8) !void {
    var file = try std.fs.createFileAbsolute(path, .{ .truncate = true });
    defer file.close();

    const out = CursorJson{
        .slot = cursor.slot,
        .block_no = cursor.block_no,
        .tip_hash_hex = cursor.tip_hash_hex[0..],
        .header_hash_hex = cursor.header_hash_hex[0..],
        .roll_forward_count = cursor.roll_forward_count,
        .roll_backward_count = cursor.roll_backward_count,
        .updated_unix = cursor.updated_unix,
    };

    try std.json.stringify(out, .{ .whitespace = .indent_2 }, file.writer());
    try file.writer().writeByte('\n');
}
