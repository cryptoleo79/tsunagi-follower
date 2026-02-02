const std = @import("std");

pub const PeerState = enum {
    cold,
    warm,
    hot,
};

pub const Peer = struct {
    id: u64,
    address: []const u8,
    state: PeerState,
};

pub const PeerManager = struct {
    // TODO: peer selection, promotion/demotion, limits

    pub fn init() PeerManager {
        return .{};
    }
};
