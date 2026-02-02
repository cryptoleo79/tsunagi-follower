const Mux = @import("../mux.zig").Mux;

pub const BlockFetch = struct {
    // TODO: blockfetch message flow
    _attached: bool = false,

    pub fn attach(m: *Mux) BlockFetch {
        _ = m; // unused for now
        return .{ ._attached = true };
    }
};
