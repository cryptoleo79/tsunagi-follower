const std = @import("std");

const journal_dir = "/home/midnight/.tsunagi";

fn openAppend() !std.fs.File {
    var home = try std.fs.openDirAbsolute("/home/midnight", .{});
    defer home.close();
    try home.makePath(".tsunagi");

    var file = home.openFile(".tsunagi/journal.ndjson", .{ .mode = .read_write }) catch |err| switch (err) {
        error.FileNotFound => try home.createFile(
            ".tsunagi/journal.ndjson",
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
) !void {
    _ = path;
    var file = try openAppend();
    defer file.close();

    const writer = file.writer();
    try writer.print(
        "{{\"type\":\"roll_forward\",\"ts\":{d},\"slot\":{d},\"block_no\":{d},\"tip_hash_hex\":\"{s}\",\"header_hash_hex\":\"{s}\"}}\n",
        .{ ts, slot, block_no, tip_hash_hex, header_hash_hex },
    );
}

pub fn appendRollBackward(
    path: []const u8,
    ts: i64,
    slot: u64,
    block_no: u64,
    tip_hash_hex: []const u8,
) !void {
    _ = path;
    var file = try openAppend();
    defer file.close();

    const writer = file.writer();
    try writer.print(
        "{{\"type\":\"roll_backward\",\"ts\":{d},\"slot\":{d},\"block_no\":{d},\"tip_hash_hex\":\"{s}\"}}\n",
        .{ ts, slot, block_no, tip_hash_hex },
    );
}
