pub const Protocol = enum {
    chainsync,
    blockfetch,
};

pub const Message = union(Protocol) {
    chainsync: ChainSyncMsg,
    blockfetch: BlockFetchMsg,
};

pub const ChainSyncMsg = enum {
    find_intersect,
    request_next,
    rollback,
    rollforward,
};

pub const BlockFetchMsg = enum {
    request_range,
    start_batch,
    block,
    batch_done,
};
