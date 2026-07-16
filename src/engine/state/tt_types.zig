// Define the transposition-table POD layout types: the cluster array element and its
// entry record. worker_layout.TranspositionTable types its cluster-base pointer as
// [*]TtCluster from here; tt.zig re-exports these.

pub const cluster_size = 3;

pub const TtEntry = struct {
    key16: u16,
    depth8: u8,
    gen_bound8: u8,
    move16: u16,
    value16: i16,
    eval16: i16,
};

pub const TtCluster = struct {
    entry: [cluster_size]TtEntry,
    padding: [2]u8,
};

test {
    @import("std").testing.refAllDecls(@This());
}
