//! Expose the NUMA topology surface. zfish runs single-node: binding is
//! a no-op, every thread maps to node 0, and execute-on-node runs the callback inline. Keep as a
//! real module so the engine/thread paths call it as ordinary Zig instead of main.zig C-ABI glue.

const std = @import("std");
const builtin = @import("builtin");

// Own the NUMA config + replication types this surface exposes (platform/numa/). Serve
// as the face for the directory; callers reach the types as numa.NumaConfig.
pub const NumaConfig = @import("numa/config.zig").NumaConfig;
pub const NumaReplicationContext = @import("numa/replication.zig").NumaReplicationContext;
pub const NumaReplicatedBase = @import("numa/replication.zig").NumaReplicatedBase;

/// Return the affinity CPU-range string (e.g. "0-15"), malloc'd + NUL-terminated (caller frees). On
/// Linux render the process's sched_getaffinity mask as comma-joined ranges; elsewhere
/// return the full "0-{ncpu-1}" range.
pub fn configString() ?[*:0]u8 {
    const a = std.heap.c_allocator;

    if (builtin.os.tag != .linux) {
        const n = std.Thread.getCpuCount() catch 1;
        const owned = if (n <= 1)
            std.fmt.allocPrintSentinel(a, "0", .{}, 0) catch return null
        else
            std.fmt.allocPrintSentinel(a, "0-{d}", .{n - 1}, 0) catch return null;
        return owned.ptr;
    }

    const linux = std.os.linux;
    var set: linux.cpu_set_t = undefined;
    @memset(std.mem.asBytes(&set), 0);
    _ = linux.sched_getaffinity(0, @sizeOf(linux.cpu_set_t), &set);

    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(a);

    const bits = @bitSizeOf(usize);
    const total = set.len * bits;
    var i: usize = 0;
    var first = true;
    while (i < total) {
        if ((set[i / bits] >> @as(u6, @intCast(i % bits))) & 1 == 0) {
            i += 1;
            continue;
        }
        const start = i;
        var j = i;
        while (j + 1 < total and (set[(j + 1) / bits] >> @as(u6, @intCast((j + 1) % bits))) & 1 != 0) : (j += 1) {}
        if (!first) buf.append(a, ',') catch return null;
        first = false;
        var nb: [40]u8 = undefined;
        const seg = if (j == start)
            std.fmt.bufPrint(&nb, "{d}", .{start}) catch return null
        else
            std.fmt.bufPrint(&nb, "{d}-{d}", .{ start, j }) catch return null;
        buf.appendSlice(a, seg) catch return null;
        i = j + 1;
    }

    const owned = a.allocSentinel(u8, buf.items.len, 0) catch return null;
    @memcpy(owned[0..buf.items.len], buf.items);
    return owned.ptr;
}

// Replace the context's topology when NumaPolicy changes. All three were empty, so the
// option was accepted and then ignored: `system`, `hardware` and `none` all left whatever
// config the engine started with. setNumaConfig also notifies the replicated objects
// (replication.zig:68), which the stubs skipped entirely.
pub fn contextSetSystem(numa_context: *NumaReplicationContext) void {
    const ctx = numa_context;
    const cfg = NumaConfig.fromSystem(std.heap.c_allocator) catch return;
    ctx.setNumaConfig(cfg);
}

// NOTE: fromSystem enumerates CPUs onto a single node -- it does not read the host's real
// NUMA topology, so `hardware` cannot yet differ from `system` here. Upstream reports
// 1/16 on this host where we report 1/1: the remaining gap is topology DISCOVERY
// (numa.h's from_system reading /sys/devices/system/node), not this wiring. Left explicit
// rather than silently aliased.
pub fn contextSetHardware(numa_context: *NumaReplicationContext) void {
    contextSetSystem(numa_context);
}

pub fn contextSetNone(numa_context: *NumaReplicationContext) void {
    const ctx = numa_context;
    // "none" means one node holding every processor: bind nothing, replicate from node 0.
    const cfg = NumaConfig.fromSystem(std.heap.c_allocator) catch return;
    ctx.setNumaConfig(cfg);
}

/// Return the NumaConfig for a context — identity here (the context is its own config).
// Resolve the erased engine handle to the context that owns the topology. The handle used
// to be the address of a module-static byte ("never dereferenced"), which is why every
// function here was forced to answer a constant. It is a real NumaReplicationContext now.
// Ask the real model (numa/config.zig), which mirrors upstream numa.h:756. Answering
// `false` unconditionally made `NumaPolicy auto` -- the DEFAULT -- never bind on any host.
pub fn suggestsBindingThreads(numa_context: *const NumaReplicationContext, num_threads: usize) bool {
    return numa_context.config.suggestsBindingThreads(num_threads);
}

/// Assign every requested thread to node 0; return the node count used (1).
// Distribute the threads across the real nodes (upstream
// NumaConfig::distribute_threads_among_numa_nodes). This pinned every thread to node 0 and
// reported one node, so even an explicit `NumaPolicy system` bound the whole pool to node
// 0 -- the exact outcome upstream's binding exists to avoid.
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

// Return num_numa_nodes() — single-node runtime, always 1; the config/context
// pointers are the single-node stubs.
// Report the real node count (upstream NumaConfig::num_numa_nodes). This answered a
// hard-coded 1, so every caller believed the host was single-node regardless of topology.
pub fn configNodeCount(numa_context: *const NumaReplicationContext) usize {
    return numa_context.config.nodes.items.len;
}

// Implement NumaReplicationContext's get_numa_config().num_numa_nodes() — config is the
// context's first member, so delegate to configNodeCount.
pub fn contextNodeCount(numa_context: *const NumaReplicationContext) usize {
    return configNodeCount(numa_context);
}

// Return num_cpus_in_numa_node(node) from the real topology. This answered a hard-coded 1,
// so the `info string ... NUMA node thread binding` line reported every node as holding a
// single CPU: this 16-CPU host printed 1/1 where upstream prints 1/16. The node's CPU
// count was known all along -- the constant, not the topology, was the gap.
pub fn contextCpusInNode(numa_context: *const NumaReplicationContext, node: usize) usize {
    const cfg = &numa_context.config;
    if (node >= cfg.nodes.items.len) return 0;
    return cfg.nodes.items[node].items.len;
}

// Parse an explicit "NumaPolicy" topology ("0-3,8:4-7") and install it. Report whether it
// parsed: upstream's from_string returns nullopt on a bad string and the caller REFUSES the
// option (engine.cpp:236-237), leaving the previous config in place. Swallowing the error
// here meant an unparseable policy was accepted, so numaPolicyMode() saw a non-auto/none
// string and bound the pool from a topology that had never been installed.
// fromString sets custom_affinity, which upstream honours by always binding (numa.h:768).
pub fn setFromString(numa_context: *NumaReplicationContext, ptr: [*]const u8, len: usize) bool {
    const ctx = numa_context;
    const cfg = NumaConfig.fromString(std.heap.c_allocator, ptr[0..len]) catch return false;
    ctx.setNumaConfig(cfg);
    return true;
}

test {
    @import("std").testing.refAllDecls(@This());
}
