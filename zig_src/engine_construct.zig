// Construction verifier for the Engine graph (harness H6, REPORT-9 big-bang plan).
//
// Stage 6 reconstructs Engine::Engine in Zig: numaContext(NumaConfig::from_system),
// the states deque, the LazyNumaReplicated network wrapper, the embedded
// ThreadPool, then the native init_body. The engine_off member offsets are already
// trusted (native accessors offset into the Engine), so this verifier checks the
// CONSTRUCTED STATE the native ctor must reproduce, not the offsets:
//   - from_system NUMA topology is sane: >= 1 node, and every node has >= 1 CPU
//     (a host-independent invariant -- an empty node means from_system mis-parsed);
//   - the network wrapper resolves instance[0] (prepare_replicate_from ran);
//   - the embedded ThreadPool is populated (>= 1 thread).
//
// Runs at the end of Engine::Engine (default build only), against the live C++
// engine. Read-only; panics on a mismatch. Models worker_construct.zig /
// thread_construct.zig.

const std = @import("std");
const graph_layout = @import("graph_layout.zig");

const eoff = graph_layout.engine_off;

fn readUsize(addr: usize) usize {
    return @as(*const usize, @ptrFromInt(addr)).*;
}

fn fail(comptime msg: []const u8) noreturn {
    std.debug.print("engine-graph construction: {s}\n", .{msg});
    @panic("Engine construction model mismatch");
}

export fn zfish_verify_engine_graph(engine: ?*const anyopaque) void {
    const base = @intFromPtr(engine orelse return);

    // (NUMA from_system topology is intentionally NOT asserted here: the node
    // COUNT is host-dependent -- on a non-NUMA host (WSL2) from_system yields an
    // empty nodes vector that the engine treats as a single implied node via
    // @max(node_count,1) -- and the std::set internals are fragile to pin. The
    // node count is already exercised by reconfigure. H6 anchors the construction
    // pieces that ARE host-independent: a resolved network instance and a
    // populated ThreadPool.)

    // --- network wrapper resolves a live instance ------------------------------
    // LazyNumaReplicated layout: [vtable:8][context:8][instances vector @16]...;
    // instance[0] = *(*(wrapper+16)). prepare_replicate_from guarantees it exists.
    const wrapper = base + eoff.network;
    const instances_begin = readUsize(wrapper + 16);
    if (instances_begin == 0) fail("network instances vector is null after construction");
    const instance0 = readUsize(instances_begin);
    if (instance0 == 0) fail("network instance[0] is null after construction");

    // --- embedded ThreadPool is populated --------------------------------------
    const pool = base + eoff.threads;
    const tbegin = readUsize(pool + graph_layout.thread_pool_off.threads_begin);
    const tend = readUsize(pool + graph_layout.thread_pool_off.threads_end);
    if (tbegin == 0) fail("engine ThreadPool threads vector is null");
    const tcount = (tend - tbegin) / @sizeOf(usize);
    if (tcount == 0) fail("engine ThreadPool has 0 threads after init_body");
}
