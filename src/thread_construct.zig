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
const graph_layout = @import("graph_layout");

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
pub fn verifyThreadGraph(pool: *const anyopaque, requested: usize, bound: usize) void {
    const tp = graph_layout.ThreadPool.fromPtr(@constCast(pool));

    // The leading atomic pair is zeroed right after construction (no search has started).
    if (tp.stop != 0) fail("ThreadPool.stop not zero at construction");
    if (tp.increase_depth != 0) fail("ThreadPool.increaseDepth not zero at construction");

    // threads is std::vector<unique_ptr<Thread>> {begin,end,cap}; size == requested.
    if (tp.threads_begin == 0) fail("ThreadPool.threads vector is null after construction");
    const count = tp.numThreads();
    if (count != requested) fail("ThreadPool.threads size != requested");

    // boundThreadToNumaNode is std::vector<NumaIndex> {begin,end}; size == bound.
    if (tp.boundCount() != bound) fail("ThreadPool.boundThreadToNumaNode size != expected");

    // Each threads[i] is a live unique_ptr<Thread> whose Worker slot is bound.
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const thread = tp.threadAt(i);
        if (thread == 0) fail("ThreadPool.threads[i] is null");
        const worker = graph_layout.Thread.fromAddr(thread).worker;
        if (worker == 0) fail("Thread[i].worker (LargePagePtr) is null");
    }
}
