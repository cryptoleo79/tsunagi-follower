const Handshake = @import("handshake.zig").Handshake;

pub const Mux = struct {
    // TODO: mini-protocol multiplexing
    _hs_attached: bool = false,

    pub fn attachHandshake(h: *Handshake) Mux {
        _ = h; // unused for now
        return .{ ._hs_attached = true };
    }
};
