//! NUMA topology surface (M16.7 — relocated out of main.zig). zfish runs single-node: binding is
//! a no-op, every thread maps to node 0, and execute-on-node runs the callback inline. Kept as a
//! real module so the engine/thread paths call it as ordinary Zig instead of main.zig C-ABI glue.

const std = @import("std");
const builtin = @import("builtin");

/// The affinity CPU-range string (e.g. "0-15"), malloc'd + NUL-terminated (caller frees). On
/// Linux this is the process's sched_getaffinity mask rendered as comma-joined ranges; elsewhere
/// it is the full "0-{ncpu-1}" range.
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

/// The NumaConfig for a context — identity here (the context is its own config).
pub fn contextConfig(numa_context: *const anyopaque) *const anyopaque {
    return numa_context;
}

pub fn suggestsBindingThreads(_: *const anyopaque, _: usize) bool {
    return false;
}

/// Assign every requested thread to node 0; returns the node count used (1).
pub fn distributeThreadsAmongNodes(_: *const anyopaque, requested: usize, out_nodes: [*]usize) usize {
    var i: usize = 0;
    while (i < requested) : (i += 1) out_nodes[i] = 0;
    return 1;
}

pub fn executeOnNode(
    _: *const anyopaque,
    _: usize,
    callback: *const fn (?*anyopaque) callconv(.c) void,
    context: ?*anyopaque,
) void {
    callback(context);
}
