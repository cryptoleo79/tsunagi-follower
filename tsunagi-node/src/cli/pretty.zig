const std = @import("std");
const i18n = @import("i18n.zig");

pub fn printHeader(lang: i18n.Lang) void {
    std.debug.print("{s}\n", .{i18n.msg(lang, "app_title")});
}

pub fn printStatusLine(
    lang: i18n.Lang,
    slot: u64,
    block_no: u64,
    tps: f64,
    utxo_count: usize,
    fwd: u64,
    back: u64,
    tip_prefix8: []const u8,
) void {
    const label = i18n.msg(lang, "status");
    std.debug.print(
        "{s}: slot={d} block={d} TPS={d:.2} UTxO={d} fwd={d} back={d} tip={s}\n",
        .{ label, slot, block_no, tps, utxo_count, fwd, back, tip_prefix8 },
    );
}
