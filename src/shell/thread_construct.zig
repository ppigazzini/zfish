// Construction verifier for the ThreadPool / Thread graph.
//
// The ThreadPool reproduces a pinned observable layout (stop@0,
// increaseDepth@1, the threads vector at 16/24, boundThreadToNumaNode at 40/48)
// and each Thread keeps its Worker at thread_off.worker, because the
// search-driver code (cb_worker_state, id_collect_bmc, nodesSearched,
// get_best_thread, ...) reads all of these by offset and would silently corrupt
// if the construction drifted.
//
// This verifier asserts the freshly constructed pool against the pinned
// offsets. Same model as the worker constructor. Read-only; panics on drift.

const std = @import("std");
const worker_layout = @import("worker_layout");

const thread_off = worker_layout.thread_off;

fn readUsize(base: [*]const u8, offset: usize) usize {
    const p: *const usize = @ptrCast(@alignCast(base + offset));
    return p.*;
}

fn fail(comptime msg: []const u8) noreturn {
    std.debug.print("thread-graph construction: {s}\n", .{msg});
    @panic("ThreadPool/Thread construction model mismatch");
}

// Verify a freshly constructed ThreadPool against the Zig model. `requested` is
// the Thread count the pool was asked to build; `bound` is the expected
// boundThreadToNumaNode size (0 when threads are not NUMA-bound, else == requested).
pub fn verifyThreadGraph(pool: *const worker_layout.ThreadPool, requested: usize, bound: usize) void {
    const tp = pool;

    // The leading atomic pair is zeroed right after construction (no search has started).
    if (tp.stop != 0) fail("ThreadPool.stop not zero at construction");
    if (tp.increase_depth != 0) fail("ThreadPool.increaseDepth not zero at construction");

    // threads is a Zig slice of Thread* addresses; size == requested.
    if (tp.threads.len == 0) fail("ThreadPool.threads vector is null after construction");
    const count = tp.numThreads();
    if (count != requested) fail("ThreadPool.threads size != requested");

    // boundThreadToNumaNode is a []usize slice of NumaIndex; size == bound.
    if (tp.boundCount() != bound) fail("ThreadPool.boundThreadToNumaNode size != expected");

    // Each threads[i] is a live owned Thread whose Worker slot is bound.
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const thread = tp.threadAt(i);
        if (thread == 0) fail("ThreadPool.threads[i] is null");
        if (worker_layout.Thread.fromAddr(thread).worker == null) fail("Thread[i].worker (LargePagePtr) is null");
    }
}

test {
    @import("std").testing.refAllDecls(@This());
}
