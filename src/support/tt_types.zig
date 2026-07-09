// Transposition-table POD layout types (M18.7 — split out of tt.zig). The cluster
// array element and its entry record, factored into a std-only leaf so the graph
// side (graph_layout.TranspositionTable) can type its cluster-base pointer as
// [*]TtCluster without importing tt.zig (which imports graph_layout — a cycle).
// tt.zig re-exports these, so its internal + external users are unchanged.

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
