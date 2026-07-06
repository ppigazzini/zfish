// Native holder for the engine's `network` member — the post-src/ replacement for
// LazyNumaReplicated<Network> (src/numa.h). The C++ holder is a NumaReplicatedBase
// (a polymorphic base: vtable + NumaReplicationContext* context) followed by a
//   mutable std::vector<std::unique_ptr<Network>> instances;  // one replica per NUMA node
//   mutable std::mutex                            mutex;
// `instances` is sized to num_numa_nodes() at construction (node 0 eager, the rest
// lazily replicated off the search path). On the single-node target there is exactly
// one replica.
//
// This module provides (a) NetworkHolder — the native structural replacement
// (the per-NUMA replica pointers; the Network instances + the 106 MB .nnue parse
// remain native-elsewhere giants), and (b) a replica-count reader that reads a
// LazyNumaReplicated holder's replica count through the documented member offset
// and asserts it equals the holder's own configured node count.

const std = @import("std");

// LazyNumaReplicatedSystemWide<Network> member offsets (System V x86-64, libstdc++).
// The engine's `network` is the SystemWide variant (Engine::network in src/engine.h);
// its polymorphic base (NumaReplicatedBase) puts the vtable at 0 and context at 8, and
// the `instances` std::vector follows at 16 as {begin, end, cap_end}. std::vector::
// size() is (end - begin) / sizeof(element) — but the element here is NOT a pointer,
// it is std::vector<SystemWideSharedConstant<Network>>, a fat value type. So the
// element stride is supplied by the caller (sizeof, passed in) rather than assumed.
// The shadow verifier caught exactly this (an 8-byte assumption read 18 replicas for a
// 1-node holder) — proof the element stride must be the real fat-value size, not 8.
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

/// Native structural replacement for the holder: the per-NUMA replica pointers. Index
/// 0 is always present; higher indices are null until lazily replicated. The Network
/// objects themselves are owned/built elsewhere (native eval; net parse is phase B).
pub const NetworkHolder = struct {
    instances: []?*anyopaque,

    pub fn replicaCount(self: NetworkHolder) usize {
        return self.instances.len;
    }
    /// The replica for a NUMA index (null if not yet built).
    pub fn at(self: NetworkHolder, idx: usize) ?*anyopaque {
        return self.instances[idx];
    }
    /// Node 0's replica — always present (operator* / operator-> in C++).
    pub fn primary(self: NetworkHolder) ?*anyopaque {
        return self.instances[0];
    }
};

// ---- tests ------------------------------------------------------------------

const testing = std.testing;

test "replicaCountOf reads instances.size() from the holder layout for a given stride" {
    // Synthesize the C++ object prefix: [vtable][context][vec.begin][vec.end][vec.cap].
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

    // Single-node case (the gate target): one element → size 1.
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
