//! NUMA topology surface (M16.7 — relocated out of main.zig). zfish runs single-node: binding is
//! a no-op, every thread maps to node 0, and execute-on-node runs the callback inline. Kept as a
//! real module so the engine/thread paths call it as ordinary Zig instead of main.zig C-ABI glue.

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
