const std = @import("std");

const PeerManager = @import("net/peer_manager.zig").PeerManager;
const Handshake = @import("net/handshake.zig").Handshake;
const Mux = @import("net/mux.zig").Mux;
const ChainSync = @import("net/miniproto/chainsync.zig").ChainSync;
const BlockFetch = @import("net/miniproto/blockfetch.zig").BlockFetch;

pub fn main() void {
    // Phase C.1: types + wiring only (no real networking)
    const pm = PeerManager.init();
    _ = pm;

    var hs = Handshake.init();
    var mux = Mux.attachHandshake(&hs);

    const cs = ChainSync.attach(&mux);
    _ = cs;

    const bf = BlockFetch.attach(&mux);
    _ = bf;

    std.debug.print("TSUNAGI Node network skeleton initialized\n", .{});
}
