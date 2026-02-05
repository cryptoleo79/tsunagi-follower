const std = @import("std");

pub const Lang = enum { en, ja };

pub fn parseLang(s: ?[]const u8) Lang {
    if (s) |val| {
        if (std.mem.eql(u8, val, "ja")) return .ja;
        if (std.mem.eql(u8, val, "en")) return .en;
    }
    return .en;
}

pub fn msg(lang: Lang, key: []const u8) []const u8 {
    return switch (lang) {
        .en => if (std.mem.eql(u8, key, "app_title")) "Tsunagi (Cardano light node)" else if (std.mem.eql(u8, key, "running")) "Running" else if (std.mem.eql(u8, key, "resuming")) "Resuming from disk" else if (std.mem.eql(u8, key, "status")) "Status" else if (std.mem.eql(u8, key, "cursor_loaded")) "Cursor loaded" else if (std.mem.eql(u8, key, "snapshot_loaded")) "UTxO snapshot loaded" else if (std.mem.eql(u8, key, "snapshot_ready")) "UTxO snapshot ready" else if (std.mem.eql(u8, key, "ctrlc_hint")) "Press Ctrl+C to stop" else if (std.mem.eql(u8, key, "doctor_ok")) "OK" else if (std.mem.eql(u8, key, "doctor_fail")) "FAIL" else if (std.mem.eql(u8, key, "network")) "Network" else "",
        .ja => if (std.mem.eql(u8, key, "app_title")) "Tsunagi (Cardano 軽量ノード)" else if (std.mem.eql(u8, key, "running")) "実行中" else if (std.mem.eql(u8, key, "resuming")) "ディスクから再開" else if (std.mem.eql(u8, key, "status")) "状態" else if (std.mem.eql(u8, key, "cursor_loaded")) "カーソル読み込み済み" else if (std.mem.eql(u8, key, "snapshot_loaded")) "UTxO スナップショット読み込み済み" else if (std.mem.eql(u8, key, "snapshot_ready")) "UTxO スナップショット準備完了" else if (std.mem.eql(u8, key, "ctrlc_hint")) "Ctrl+Cで停止" else if (std.mem.eql(u8, key, "doctor_ok")) "OK" else if (std.mem.eql(u8, key, "doctor_fail")) "失敗" else if (std.mem.eql(u8, key, "network")) "ネットワーク" else "",
    };
}
