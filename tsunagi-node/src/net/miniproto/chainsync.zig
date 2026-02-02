const Mux = @import("../mux.zig").Mux;

pub const ChainSync = struct {
    // TODO: chainsync message flow
    _attached: bool = false,

    pub fn attach(m: *Mux) ChainSync {
        _ = m; // unused for now
        return .{ ._attached = true };
    }
};
