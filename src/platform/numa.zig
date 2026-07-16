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

pub fn contextSetSystem(_: *anyopaque) void {}
pub fn contextSetHardware(_: *anyopaque) void {}
pub fn contextSetNone(_: *anyopaque) void {}

/// Return the NumaConfig for a context — identity here (the context is its own config).
pub fn contextConfig(numa_context: *const anyopaque) *const anyopaque {
    return numa_context;
}

pub fn suggestsBindingThreads(_: *const anyopaque, _: usize) bool {
    return false;
}

/// Assign every requested thread to node 0; return the node count used (1).
pub fn distributeThreadsAmongNodes(_: *const anyopaque, requested: usize, out_nodes: [*]usize) usize {
    var i: usize = 0;
    while (i < requested) : (i += 1) out_nodes[i] = 0;
    return 1;
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
pub fn configNodeCount(_: *const anyopaque) usize {
    return 1;
}

// Implement NumaReplicationContext's get_numa_config().num_numa_nodes() — config is the
// context's first member, so delegate to configNodeCount.
pub fn contextNodeCount(numa_context: *const anyopaque) usize {
    return configNodeCount(numa_context);
}

// Return num_cpus_in_numa_node(node): the single-node stub never binds, so keep this >=1 and
// never dereference the context.
pub fn contextCpusInNode(_: *const anyopaque, _: usize) usize {
    return 1;
}

// Reconfigure NumaPolicy from an option string: single-node build, so no-op
// here (there is no multi-node topology to re-derive).
pub fn setFromString(_: *anyopaque, _: [*]const u8, _: usize) void {}

test {
    @import("std").testing.refAllDecls(@This());
}
