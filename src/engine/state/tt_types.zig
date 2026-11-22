// Define the transposition-table POD layout types: the cluster array element and its
// entry record. worker_layout.TranspositionTable types its cluster-base pointer as
// [*]TtCluster from here; tt.zig re-exports these.

pub const cluster_size = 3;

/// Keep this many low bits of the position key as each entry's tag (upstream ff3a6c508).
/// The cluster is found by the HIGH bits, so these are what tells its three entries apart.
pub const key_bits = 21;

pub const TtEntry = extern struct {
    depth8: u8,
    gen_bound8: u8,
    move16: u16,
    value16: i16,
    eval16: i16,
};

/// Hold the three entries' tags packed into one word, 21 bits each from bit 0, ahead of the
/// entries. Align the cluster to its own size: tt.entrySave recovers the cluster and the slot
/// from an entry's address, which keeps the probe's writer one pointer wide.
pub const TtCluster = extern struct {
    keys: u64 align(32),
    entry: [cluster_size]TtEntry,
};

comptime {
    // Hold upstream's declared order and its `sizeof(Cluster) == 32` static_assert
    // (tt.cpp). A plain Zig struct leaves the order unspecified and this toolchain DOES
    // reorder it, which drops the probe's read order (tt.cpp: "these fields are in the same
    // order as accessed by TT::probe(), since memory is fastest sequentially") and would let
    // a future Zig change the cluster stride the table sizing depends on.
    const std = @import("std");
    std.debug.assert(@sizeOf(TtEntry) == 8);
    std.debug.assert(@offsetOf(TtEntry, "depth8") == 0);
    std.debug.assert(@offsetOf(TtEntry, "gen_bound8") == 1);
    std.debug.assert(@offsetOf(TtEntry, "move16") == 2);
    std.debug.assert(@offsetOf(TtEntry, "value16") == 4);
    std.debug.assert(@offsetOf(TtEntry, "eval16") == 6);
    std.debug.assert(@offsetOf(TtCluster, "keys") == 0);
    std.debug.assert(@offsetOf(TtCluster, "entry") == 8);
    std.debug.assert(@sizeOf(TtCluster) == 32);
    std.debug.assert(@alignOf(TtCluster) == 32);
    std.debug.assert(cluster_size * key_bits <= 64);
}

test {
    @import("std").testing.refAllDecls(@This());
}
