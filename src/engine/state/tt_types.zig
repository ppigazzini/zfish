// Define the transposition-table POD layout types: the cluster array element and its
// entry record. worker_layout.TranspositionTable types its cluster-base pointer as
// [*]TtCluster from here; tt.zig re-exports these.

pub const cluster_size = 3;

pub const TtEntry = extern struct {
    key16: u16,
    depth8: u8,
    gen_bound8: u8,
    move16: u16,
    value16: i16,
    eval16: i16,
};

pub const TtCluster = extern struct {
    entry: [cluster_size]TtEntry,
    padding: [2]u8,
};

comptime {
    // Hold upstream's declared order and its `sizeof(Cluster) == 32` static_assert
    // (tt.cpp:161). A plain Zig struct leaves the order unspecified and this toolchain
    // DOES reorder it -- depth8/gen_bound8 land at 8/9 instead of 2/3 -- which drops the
    // probe's read order (tt.cpp:48: "these fields are in the same order as accessed by
    // TT::probe(), since memory is fastest sequentially") and would let a future Zig
    // change the cluster stride the table sizing depends on.
    const std = @import("std");
    std.debug.assert(@sizeOf(TtEntry) == 10);
    std.debug.assert(@offsetOf(TtEntry, "key16") == 0);
    std.debug.assert(@offsetOf(TtEntry, "depth8") == 2);
    std.debug.assert(@offsetOf(TtEntry, "gen_bound8") == 3);
    std.debug.assert(@offsetOf(TtEntry, "move16") == 4);
    std.debug.assert(@offsetOf(TtEntry, "value16") == 6);
    std.debug.assert(@offsetOf(TtEntry, "eval16") == 8);
    std.debug.assert(@sizeOf(TtCluster) == 32);
}

test {
    @import("std").testing.refAllDecls(@This());
}
