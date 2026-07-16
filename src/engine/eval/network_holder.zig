// Hold the engine's `network` member, modeling
// LazyNumaReplicated<Network> (src/numa.h). The upstream holder is a NumaReplicatedBase
// (a polymorphic base: vtable + NumaReplicationContext* context) followed by
//   an `instances` vector of owning pointers to Network (one replica per NUMA node)
//   and a `mutex`.
// `instances` is sized to num_numa_nodes() at construction (node 0 eager, the rest
// lazily replicated off the search path). On the single-node target there is exactly
// one replica.
//
// Provide (a) NetworkHolder — the structural replacement
// (the per-NUMA replica pointers; the Network instances + the 106 MB .nnue parse
// are owned elsewhere), and (b) a replica-count reader that reads a
// LazyNumaReplicated holder's replica count through the documented member offset
// and asserts it equals the holder's own configured node count.

const std = @import("std");

// Map the LazyNumaReplicatedSystemWide<Network> member offsets (System V x86-64, libstdc++).
// The engine's `network` is the SystemWide variant (declared in src/engine.h);
// its polymorphic base (NumaReplicatedBase) puts the vtable at 0 and context at 8, and
// the `instances` vector follows at 16 as libstdc++'s {begin, end, cap_end} pointers.
// Its element count is (end - begin) / sizeof(element) — but the element here is NOT a
// pointer, it is a vector of SystemWideSharedConstant<Network>, a fat value type. So the
// element stride is supplied by the caller (sizeof, passed in) rather than assumed.
// An 8-byte pointer assumption would misread the count (18 replicas for a 1-node
// holder), so the element stride must be the real fat-value size, not 8.
const instances_begin_off: usize = 16;
const instances_end_off: usize = 24;

/// Read a LazyNumaReplicated holder's replica count (instances.size()), given the
/// element stride sizeof(SystemWideSharedConstant<Network>).
pub fn replicaCountOf(lazy_ptr: *const anyopaque, elem_size: usize) usize {
    const base: [*]const u8 = @ptrCast(lazy_ptr);
    const begin = @as(*const usize, @ptrCast(@alignCast(base + instances_begin_off))).*;
    const end = @as(*const usize, @ptrCast(@alignCast(base + instances_end_off))).*;
    return (end - begin) / elem_size;
}

/// Check: the holder's replica count matches the expected node count
/// (network.get_numa_config().num_numa_nodes(), supplied by the caller).
pub fn verifyReplicaCount(lazy_ptr: *const anyopaque, elem_size: usize, expected_nodes: usize) bool {
    return replicaCountOf(lazy_ptr, elem_size) == expected_nodes;
}

/// Hold the per-NUMA replica pointers. Index
/// 0 is always present; higher indices are null until lazily replicated. The Network
/// objects themselves are owned/built elsewhere.
pub const NetworkHolder = struct {
    instances: []?*anyopaque,

    pub fn replicaCount(self: NetworkHolder) usize {
        return self.instances.len;
    }
    /// Return the replica for a NUMA index (null if not yet built).
    pub fn at(self: NetworkHolder, idx: usize) ?*anyopaque {
        return self.instances[idx];
    }
    /// Return node 0's replica — always present.
    pub fn primary(self: NetworkHolder) ?*anyopaque {
        return self.instances[0];
    }
};

// ---- tests ------------------------------------------------------------------

const testing = std.testing;

test "replicaCountOf reads instances.size() from the holder layout for a given stride" {
    // Synthesize the holder object prefix: [vtable][context][vec.begin][vec.end][vec.cap].
    // Use a 48-byte element stride to model the fat SystemWideSharedConstant element;
    // a 3-element span is 144 bytes, so size() == 3.
    const stride: usize = 48;
    var backing: [3 * stride]u8 = undefined;
    const begin = @intFromPtr(&backing);
    var obj: [5]usize = .{
        0xDEAD, // vtable
        0xBEEF, // context
        begin, // instances.begin
        begin + 3 * stride, // instances.end (3 elements)
        begin + 3 * stride, // instances.cap
    };
    try testing.expectEqual(@as(usize, 3), replicaCountOf(@ptrCast(&obj), stride));
    try testing.expect(verifyReplicaCount(@ptrCast(&obj), stride, 3));
    try testing.expect(!verifyReplicaCount(@ptrCast(&obj), stride, 1));

    // Cover the single-node case (the gate target): one element → size 1.
    obj[3] = begin + 1 * stride;
    try testing.expectEqual(@as(usize, 1), replicaCountOf(@ptrCast(&obj), stride));
}

test "NetworkHolder exposes per-NUMA replicas with node 0 primary" {
    var net0: u32 = 0;
    var net1: u32 = 0;
    var slots = [_]?*anyopaque{ &net0, &net1 };
    const holder = NetworkHolder{ .instances = &slots };
    try testing.expectEqual(@as(usize, 2), holder.replicaCount());
    try testing.expectEqual(@as(?*anyopaque, &net0), holder.primary());
    try testing.expectEqual(@as(?*anyopaque, &net1), holder.at(1));

    var single = [_]?*anyopaque{&net0};
    const one = NetworkHolder{ .instances = &single };
    try testing.expectEqual(@as(usize, 1), one.replicaCount());
    try testing.expectEqual(@as(?*anyopaque, &net0), one.primary());
}
