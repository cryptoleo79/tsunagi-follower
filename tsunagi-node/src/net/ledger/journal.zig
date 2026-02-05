const std = @import("std");

fn openAppend(path: []const u8) !std.fs.File {
    const dir = std.fs.path.dirname(path) orelse return error.InvalidPath;
    try std.fs.cwd().makePath(dir);

    var file = std.fs.openFileAbsolute(path, .{ .mode = .read_write }) catch |err| switch (err) {
        error.FileNotFound => try std.fs.createFileAbsolute(
            path,
            .{ .read = true, .truncate = false },
        ),
        else => return err,
    };
    try file.seekFromEnd(0);
    return file;
}

pub fn appendRollForward(
    path: []const u8,
    ts: i64,
    slot: u64,
    block_no: u64,
    tip_hash_hex: []const u8,
    header_hash_hex: []const u8,
    tx_count: u64,
    utxo_count: u64,
) !void {
    var file = try openAppend(path);
    defer file.close();

    const writer = file.writer();
    try writer.print(
        "{{\"type\":\"roll_forward\",\"ts\":{d},\"slot\":{d},\"block_no\":{d},\"tip_hash_hex\":\"{s}\",\"header_hash_hex\":\"{s}\",\"tx_count\":{d},\"utxo_count\":{d}}}\n",
        .{ ts, slot, block_no, tip_hash_hex, header_hash_hex, tx_count, utxo_count },
    );
}

pub fn appendRollBackward(
    path: []const u8,
    ts: i64,
    slot: u64,
    block_no: u64,
    tip_hash_hex: []const u8,
) !void {
    var file = try openAppend(path);
    defer file.close();

    const writer = file.writer();
    try writer.print(
        "{{\"type\":\"roll_backward\",\"ts\":{d},\"slot\":{d},\"block_no\":{d},\"tip_hash_hex\":\"{s}\"}}\n",
        .{ ts, slot, block_no, tip_hash_hex },
    );
}
