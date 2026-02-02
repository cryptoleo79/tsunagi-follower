const std = @import("std");

const PeerManager = @import("net/peer_manager.zig").PeerManager;
const Mux = @import("net/mux.zig").Mux;
const ChainSync = @import("net/miniproto/chainsync.zig").ChainSync;
const BlockFetch = @import("net/miniproto/blockfetch.zig").BlockFetch;

pub fn main() void {
    const pm = PeerManager.init();
    _ = pm;

    var mux = Mux.attachHandshake();

    var cs = ChainSync.attach(&mux);
    var bf = BlockFetch.attach(&mux);

    cs.requestNext();
    bf.requestRange();

    std.debug.print("TSUNAGI Node protocol harness executed (Phase C.2)\n", .{});
}
