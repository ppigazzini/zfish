// Construction verifier for the ThreadPool / Thread graph (harness H4).
//
// The stage-4 big-bang replaces the C++ ThreadPool::set + std::thread/idle_loop
// Thread with a native runtime. The native ThreadPool must reproduce the C++
// ThreadPool's observable layout (stop@0, increaseDepth@1, the threads vector at
// 16/24, boundThreadToNumaNode at 40/48) and each native Thread must keep its
// Worker at thread_off.worker, because the search-driver code (cb_worker_state,
// id_collect_bmc, nodesSearched, get_best_thread, ...) reads all of these by
// offset and would silently corrupt if the native construction drifted.
//
// This runs at the end of the live C++ ThreadPool::set (default build only) and
// asserts the freshly constructed pool against the pinned offsets. Landed now, it
// verifies the C++-built pool — anchoring the offsets while the C++ runtime is
// still alive — and it will verify the native pool unchanged once stage 4 swaps
// the construction. Same model as worker_construct.zig. Read-only; panics on
// drift.

const std = @import("std");
const graph_layout = @import("graph_layout.zig");

const pool_off = graph_layout.thread_pool_off;
const thread_off = graph_layout.thread_off;

fn readUsize(base: [*]const u8, offset: usize) usize {
    const p: *const usize = @ptrCast(@alignCast(base + offset));
    return p.*;
}

fn fail(comptime msg: []const u8) noreturn {
    std.debug.print("thread-graph construction: {s}\n", .{msg});
    @panic("ThreadPool/Thread construction model mismatch");
}

// Verify a freshly constructed ThreadPool against the Zig model. `requested` is
// the Thread count ThreadPool::set was asked to build; `bound` is the expected
// boundThreadToNumaNode size (0 when threads are not NUMA-bound, else == requested).
export fn zfish_verify_thread_graph(pool: ?*const anyopaque, requested: usize, bound: usize) void {
    const base: [*]const u8 = @ptrCast(pool orelse return);

    // The leading atomic pair is zeroed right after construction (no search has
    // started): a load through the byte offsets must read 0/0.
    if (base[pool_off.stop] != 0) fail("ThreadPool.stop not zero at construction");
    if (base[pool_off.increase_depth] != 0) fail("ThreadPool.increaseDepth not zero at construction");

    // threads is std::vector<unique_ptr<Thread>> {begin,end,cap}; size == requested.
    const tbegin = readUsize(base, pool_off.threads_begin);
    const tend = readUsize(base, pool_off.threads_end);
    if (tbegin == 0) fail("ThreadPool.threads vector is null after construction");
    const count = (tend - tbegin) / @sizeOf(usize);
    if (count != requested) fail("ThreadPool.threads size != requested");

    // boundThreadToNumaNode is std::vector<NumaIndex> {begin,end}; size == bound.
    const bbegin = readUsize(base, pool_off.bound_nodes_begin);
    const bend = readUsize(base, pool_off.bound_nodes_end);
    const bcount = if (bbegin == 0) 0 else (bend - bbegin) / @sizeOf(usize);
    if (bcount != bound) fail("ThreadPool.boundThreadToNumaNode size != expected");

    // Each threads[i] is a live unique_ptr<Thread> whose Worker slot is bound.
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const thread = readUsize(@ptrFromInt(tbegin), i * @sizeOf(usize));
        if (thread == 0) fail("ThreadPool.threads[i] is null");
        const worker = readUsize(@ptrFromInt(thread), thread_off.worker);
        if (worker == 0) fail("Thread[i].worker (LargePagePtr) is null");
    }
}
