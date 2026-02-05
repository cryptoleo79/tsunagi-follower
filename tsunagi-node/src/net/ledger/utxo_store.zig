const std = @import("std");
const utxo = @import("utxo.zig");

pub fn save(path: []const u8, state: *utxo.UTxO) !void {
    var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();

    var w = file.writer();
    try w.print("UTXO_COUNT {d}\n", .{state.map.count()});

    var it = state.map.iterator();
    while (it.next()) |entry| {
        const k = entry.key_ptr.*;
        const v = entry.value_ptr.*;
        try w.print(
            "{s}:{d} {d}\n",
            .{
                std.fmt.fmtSliceHexLower(&k.tx_hash),
                k.index,
                v.lovelace,
            },
        );
    }
}

pub fn load(alloc: std.mem.Allocator, path: []const u8) !utxo.UTxO {
    var state = utxo.UTxO.init(alloc);

    var file = std.fs.cwd().openFile(path, .{}) catch return state;
    defer file.close();

    var buf: [4096]u8 = undefined;
    var r = file.reader();

    while (try r.readUntilDelimiterOrEof(&buf, '\n')) |line| {
        if (std.mem.startsWith(u8, line, "UTXO_COUNT")) continue;

        var it = std.mem.split(u8, line, " ");
        const left = it.next() orelse continue;
        const value_str = it.next() orelse continue;
        const value = std.fmt.parseInt(u64, value_str, 10) catch continue;

        var it2 = std.mem.split(u8, left, ":");
        const hash_hex = it2.next() orelse continue;
        const index_str = it2.next() orelse continue;
        const index = std.fmt.parseInt(u32, index_str, 10) catch continue;

        if (hash_hex.len != 64) continue;
        var hash: [32]u8 = undefined;
        _ = std.fmt.hexToBytes(&hash, hash_hex) catch continue;

        state.map.put(
            .{ .tx_hash = hash, .index = index },
            .{ .address = "", .lovelace = value },
        ) catch continue;
    }

    return state;
}
