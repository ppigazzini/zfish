//! Expose the NUMA topology surface. zfish runs single-node: binding is
//! a no-op, every thread maps to node 0, and execute-on-node runs the callback inline. Keep as a
//! real module so the engine/thread paths call it as ordinary Zig instead of main.zig C-ABI glue.

const std = @import("std");

// Own the NUMA config + replication types this surface exposes (platform/numa/). Serve
// as the face for the directory; callers reach the types as numa.NumaConfig.
pub const NumaConfig = @import("numa/config.zig").NumaConfig;
pub const NumaReplicationContext = @import("numa/replication.zig").NumaReplicationContext;
pub const NumaReplicatedBase = @import("numa/replication.zig").NumaReplicatedBase;
const numa_policy = @import("numa/policy.zig");

// Replace the context's topology when NumaPolicy changes. setNumaConfig also notifies the
// replicated objects (replication.zig:68) so they re-replicate onto the new node set.
pub fn contextSetSystem(numa_context: *NumaReplicationContext) void {
    const ctx = numa_context;
    const cfg = NumaConfig.fromSystem(std.heap.c_allocator) catch return;
    ctx.setNumaConfig(cfg);
}

// `hardware` aliases `system`: fromSystem enumerates every online CPU onto a single node
// rather than reading the host's real multi-node topology (upstream numa.h's from_system
// reads /sys/devices/system/node). On a single-socket host the two agree; on a multi-node
// host this reports one node where upstream reports several. The gap is topology
// DISCOVERY, not this wiring.
pub fn contextSetHardware(numa_context: *NumaReplicationContext) void {
    contextSetSystem(numa_context);
}

pub fn contextSetNone(numa_context: *NumaReplicationContext) void {
    const ctx = numa_context;
    // "none" means one node holding every processor: bind nothing, replicate from node 0.
    const cfg = NumaConfig.fromSystem(std.heap.c_allocator) catch return;
    ctx.setNumaConfig(cfg);
}

// Ask the real NumaConfig model (numa/config.zig), which mirrors upstream numa.h:756,
// whether to bind. `NumaPolicy auto` (the default) binds exactly when the config's rule
// fires, so this must consult the model rather than answer a constant.
pub fn suggestsBindingThreads(numa_context: *const NumaReplicationContext, num_threads: usize) bool {
    return numa_context.config.suggestsBindingThreads(num_threads);
}

// Distribute the requested threads across the real nodes (upstream
// NumaConfig::distribute_threads_among_numa_nodes); return the node count used.
pub fn distributeThreadsAmongNodes(numa_context: *const NumaReplicationContext, requested: usize, out_nodes: [*]usize) usize {
    const cfg = &numa_context.config;
    const ns = cfg.distributeThreads(std.heap.c_allocator, requested) catch {
        // Degrade to node 0 rather than abort a search on OOM.
        var i: usize = 0;
        while (i < requested) : (i += 1) out_nodes[i] = 0;
        return @max(cfg.nodes.items.len, 1);
    };
    defer std.heap.c_allocator.free(ns);
    @memcpy(out_nodes[0..requested], ns);
    return @max(cfg.nodes.items.len, 1);
}

pub fn executeOnNode(
    _: *const anyopaque,
    _: usize,
    callback: *const fn (?*anyopaque) void,
    context: ?*anyopaque,
) void {
    callback(context);
}

// Report the node count from the real topology (upstream NumaConfig::num_numa_nodes).
pub fn configNodeCount(numa_context: *const NumaReplicationContext) usize {
    return numa_context.config.nodes.items.len;
}

// Implement NumaReplicationContext's get_numa_config().num_numa_nodes() — config is the
// context's first member, so delegate to configNodeCount.
/// Render the context's live topology, the string the engine reports as "Available
/// processors". Read the CONFIG, not the process affinity mask: once a "NumaPolicy"
/// string installs a topology, the mask no longer describes what the engine is using.
pub fn contextConfigString(
    numa_context: *const NumaReplicationContext,
    gpa: std.mem.Allocator,
) ?[]u8 {
    return numa_context.getNumaConfig().toString(gpa) catch null;
}

pub fn contextNodeCount(numa_context: *const NumaReplicationContext) usize {
    return configNodeCount(numa_context);
}

// Return num_cpus_in_numa_node(node) from the real topology -- the node's CPU count, which
// feeds the `info string ... NUMA node thread binding` line. An out-of-range node -> 0.
pub fn contextCpusInNode(numa_context: *const NumaReplicationContext, node: usize) usize {
    const cfg = &numa_context.config;
    if (node >= cfg.nodes.items.len) return 0;
    return cfg.nodes.items[node].items.len;
}

// Parse an explicit "NumaPolicy" topology ("0-3,8:4-7") and install it; return whether it
// parsed. On a bad string upstream's from_string returns nullopt and the caller REFUSES
// the option (engine.cpp:236-237), leaving the previous config in place, so return false
// rather than install a partial config that numaPolicyMode() would then bind from.
// fromString sets custom_affinity, which upstream honours by always binding (numa.h:768).
pub fn setFromString(numa_context: *NumaReplicationContext, ptr: [*]const u8, len: usize) bool {
    const ctx = numa_context;
    const cfg = numa_policy.parse(std.heap.c_allocator, ptr[0..len]) catch return false;
    ctx.setNumaConfig(cfg);
    return true;
}

test {
    @import("std").testing.refAllDecls(@This());
}
