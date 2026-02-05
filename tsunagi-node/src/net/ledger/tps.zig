const std = @import("std");

pub const TpsMeter = struct {
    window_start_unix: i64,
    tx_count: u64,
    last_tps_print_unix: i64,

    pub fn init(now: i64) TpsMeter {
        return .{
            .window_start_unix = now,
            .tx_count = 0,
            .last_tps_print_unix = now,
        };
    }

    pub fn addBlock(self: *TpsMeter, txs_in_block: u64, now: i64, debug: bool) void {
        if (now != self.window_start_unix) {
            const delta = now - self.window_start_unix;
            if (delta > 0) {
                const tps = @as(f64, @floatFromInt(self.tx_count)) /
                    @as(f64, @floatFromInt(delta));
                if (debug or self.tx_count > 0 or now - self.last_tps_print_unix >= 10) {
                    std.debug.print(
                        "TPS window={d}s txs={d} TPS={d:.2}\n",
                        .{ delta, self.tx_count, tps },
                    );
                    self.last_tps_print_unix = now;
                }
            }
            self.window_start_unix = now;
            self.tx_count = 0;
        }
        self.tx_count += txs_in_block;
    }
};
