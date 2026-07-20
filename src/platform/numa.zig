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

    // Report every CPU as the fallback: used off Linux, and on Linux when the affinity
    // syscall is unavailable (a seccomp sandbox or a filtered container).
    const fullRange = struct {
        fn f(alloc: std.mem.Allocator) ?[*:0]u8 {
            const n = std.Thread.getCpuCount() catch 1;
            const owned = if (n <= 1)
                std.fmt.allocPrintSentinel(alloc, "0", .{}, 0) catch return null
            else
                std.fmt.allocPrintSentinel(alloc, "0-{d}", .{n - 1}, 0) catch return null;
            return owned.ptr;
        }
    }.f;

    if (builtin.os.tag != .linux) return fullRange(a);

    const linux = std.os.linux;
    var set: linux.cpu_set_t = undefined;
    @memset(std.mem.asBytes(&set), 0);
    // Check the return: dropping it leaves the mask all-zero, and the bit-walk below then
    // reports an EMPTY cpu set as if the process were bound to nothing.
    const rc = linux.sched_getaffinity(0, @sizeOf(linux.cpu_set_t), &set);
    if (linux.errno(rc) != .SUCCESS) return fullRange(a);

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
    const cfg = NumaConfig.fromString(std.heap.c_allocator, ptr[0..len]) catch return false;
    ctx.setNumaConfig(cfg);
    return true;
}

test {
    @import("std").testing.refAllDecls(@This());
}
