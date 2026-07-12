// Thread pool.
//
// Owns the search threads and writes the ThreadPool's observable 56-byte footprint
// so the accessors keep working unchanged:
//   stop@0 (atomic_bool), increaseDepth@1 (atomic_bool),
//   threads slice {ptr@16, len@24}  (of Thread* == SearchThread* addresses),
//   boundThreadToNumaNode slice {ptr@32, len@40}  (per-thread NUMA node).
// num_threads == threads.len; threads[i] == the i-th slice element (a Thread* addr).
//
// LIFECYCLE NOTE: the threads-vector buffer here is Zig-allocated, and each
// SearchThread is Zig-owned, so teardown goes through the pool's clear() path
// rather than any foreign destructor over this footprint. It is unit-tested in
// isolation over a standalone 64-byte buffer.
//
// The Worker construction (large-page alloc + constructFull +
// SearchManager) is injected as a callback so the footprint bookkeeping is tested
// without the engine graph; the engine passes the real builder.

const std = @import("std");
const builtin = @import("builtin");
const SearchThread = @import("search_thread").SearchThread;
const graph_layout = @import("graph_layout");
const native_hooks = @import("native_hooks");
const ThreadPool = graph_layout.ThreadPool;

// The 64-byte pool footprint is a graph_layout.ThreadPool: the writer here
// and every reader (graph_layout accessors, the search's captured
// &stop pointer) go through the same typed struct, so Zig owns the field placement.
inline fn poolOf(slot: [*]u8) *ThreadPool {
    return ThreadPool.fromPtr(@ptrCast(slot));
}

// Per-thread construction hook: given the thread index and the freshly spawned
// SearchThread (idle loop running, no Worker yet), build + attach the Worker.
// Layer 4 binds this to the large-page Worker alloc + constructFull.
pub const ThreadBuilder = struct {
    ctx: ?*anyopaque = null,
    // thread is passed opaque so the worker-builder can write worker@8 directly.
    build: *const fn (ctx: ?*anyopaque, idx: usize, thread: *anyopaque) void,
};

// The thread pool. `slot` points at the 64-byte ThreadPool footprint
// (the Engine's embedded pool, or a standalone buffer in tests).
pub const Pool = struct {
    allocator: std.mem.Allocator,
    slot: [*]u8,

    pub fn init(allocator: std.mem.Allocator, slot: [*]u8) Pool {
        return .{ .allocator = allocator, .slot = slot };
    }

    // Build `count` native Threads (idle loops + Workers via the builder) and lay
    // them into the footprint.
    pub fn set(self: *Pool, count: usize, builder: ThreadBuilder) !void {
        self.clear();
        const tp = poolOf(self.slot);

        // stop / increaseDepth start cleared (no search in flight).
        tp.stop = 0;
        tp.increase_depth = 0;
        // boundThreadToNumaNode: empty (no NUMA binding on the single-node path). The
        // multi-node reconfigure path assigns it via boundNodesAssign before building
        // threads; this reset clears it first.
        tp.bound = &.{};

        if (count == 0) {
            tp.threads = &.{};
            return;
        }

        // The footprint's threads slice IS the backing buffer -- a []usize of Thread*
        // addresses. clear() recovers it straight from tp.threads (see its note).
        const vec = try self.allocator.alloc(usize, count);
        var built: usize = 0;
        errdefer {
            var i: usize = 0;
            while (i < built) : (i += 1) {
                const t: *SearchThread = @ptrFromInt(vec[i]);
                t.deinit(self.allocator);
                self.allocator.destroy(t);
            }
            self.allocator.free(vec);
        }
        for (vec, 0..) |*slotptr, idx| {
            const thread = try self.allocator.create(SearchThread);
            errdefer self.allocator.destroy(thread);
            thread.* = .{};
            try thread.spawn(self.allocator, idx);
            builder.build(builder.ctx, idx, @ptrCast(thread)); // attach the Worker (writes worker@8)
            slotptr.* = @intFromPtr(thread);
            built += 1;
        }
        tp.threads = vec;
    }

    // Footprint-based (stateless): recovers the threads buffer straight from the slot's
    // `threads` slice, not a held field -- so a fresh Pool wrapper over the same
    // slot (reset_for_reconfigure, the destroy hook) tears the pool down correctly.
    // Requires a zeroed-or-valid footprint (a default-constructed ThreadPool has an
    // empty slice, so len==0 is the no-op case).
    pub fn clear(self: *Pool) void {
        const tp = poolOf(self.slot);
        const buf = tp.threads;
        if (buf.len != 0) {
            // Drain any queued/in-flight job BEFORE tearing threads down. The
            // teardown path runs with the stop flag already set (quit /
            // reset_for_reconfigure), so an in-flight search bails immediately and
            // emits its bestmove here. Without this, deinit's exit flag races the
            // idle loop and can drop a just-queued-but-not-yet-started search job
            // -> a lost bestmove (deterministic for `go ...; quit` back-to-back).
            // Idle threads return immediately. Mirrors ~ThreadPool's
            // wait_for_search_finished before deleting threads.
            for (buf) |addr| {
                const t: *SearchThread = @ptrFromInt(addr);
                t.waitForSearchFinished();
            }
            for (buf) |addr| {
                const t: *SearchThread = @ptrFromInt(addr);
                t.deinit(self.allocator);
                self.allocator.destroy(t);
            }
            self.allocator.free(buf);
        }
        tp.threads = &.{};
    }

    pub fn numThreads(self: *const Pool) usize {
        return poolOf(self.slot).numThreads();
    }
};

// ---- Entry points (called by the native reconfigure + teardown) -------

// The native worker-builder: resolves the SharedState members + numa params for
// thread `idx`, large-page-allocs + constructs the Worker, mints the SearchManager,
// and writes the Worker at thread+8 (worker@8). Single-node host.

const WorkerBuildCtx = struct {
    shared_state: ?*anyopaque,
    update_context: ?*const anyopaque,
    total: usize,
};

// Build `count` native Threads (idle loops + Workers) into the Engine's embedded
// ThreadPool footprint `pool`.
pub fn set(
    pool: *graph_layout.ThreadPool,
    shared_state: *anyopaque,
    update_context: *const anyopaque,
    count: usize,
) !void {
    var bctx = WorkerBuildCtx{ .shared_state = shared_state, .update_context = update_context, .total = count };
    var p = Pool.init(std.heap.c_allocator, @ptrCast(pool));
    // Propagate the OOM / thread-spawn error to the engine's resize boundary
    // instead of panicking here (the caller reconfigure -> resizeThreads is now !void).
    try p.set(count, .{ .ctx = &bctx, .build = native_hooks.native_worker_build });
}

// Join + free every native Thread and null the footprint vector. Called by the
// native reset_for_reconfigure and the engine teardown hook.
pub fn clear(pool: *graph_layout.ThreadPool) void {
    var p = Pool.init(std.heap.c_allocator, @ptrCast(pool));
    p.clear();
}

// Wait for one thread's in-flight job to finish. Reads the thread pointer out of
// the footprint vector by index and calls the native wait.
pub fn waitThread(pool: *graph_layout.ThreadPool, thread_id: usize) void {
    const tp = poolOf(@ptrCast(pool));
    if (tp.threads.len == 0) return;
    const thread: *SearchThread = @ptrFromInt(tp.threadAt(thread_id));
    thread.waitForSearchFinished();
}

// Assign the pool's boundThreadToNumaNode footprint slice (a typed []usize via
// the allocator interface).
// `nodes` is the per-thread NUMA-node index list, or null/empty to clear. Frees any
// prior buffer on every reassign, so the lifecycle is leak-clean under a checked
// allocator (the bound-vector unit test drives exactly this). Lives here beside set()
// -- which clears the same footprint slot -- rather than in thread.zig, so all the
// ThreadPool-footprint writes sit in one module and the writer is directly testable.
pub fn boundNodesAssign(pool: *graph_layout.ThreadPool, allocator: std.mem.Allocator, nodes: ?[]const usize) error{OutOfMemory}!void {
    const tp = pool;
    if (tp.bound.len != 0) allocator.free(tp.bound);
    tp.bound = &.{};
    const src = nodes orelse return;
    if (src.len == 0) return;
    // Propagate OOM (was `catch @panic`); the reconfigure caller now unwinds it.
    const buf = try allocator.alloc(usize, src.len);
    @memcpy(buf, src);
    tp.bound = buf;
}

// ---- tests (isolated; mock builder, standalone footprint) -------------------

const testing = std.testing;

// Mock builder: count Worker attachments, leave worker null (no graph here).
const MockBuild = struct {
    attached: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    fn build(ctx: ?*anyopaque, idx: usize, thread_ptr: *anyopaque) void {
        _ = idx;
        const self: *MockBuild = @ptrCast(@alignCast(ctx.?));
        _ = self.attached.fetchAdd(1, .monotonic);
        const thread: *SearchThread = @ptrCast(@alignCast(thread_ptr));
        // Leave thread.worker null (a real builder sets it); confirm idle loop ran.
        thread.startJob(noopJob, null);
        thread.waitForSearchFinished();
    }
    fn noopJob(_: ?*anyopaque) void {}
};

test "Pool lays the C++ footprint and reads back the thread vector" {
    var footprint: [64]u8 align(8) = [_]u8{0} ** 64; // zeroed = default-constructed pool
    var mb = MockBuild{};
    var pool = Pool.init(testing.allocator, &footprint);
    defer pool.clear();

    try pool.set(4, .{ .ctx = &mb, .build = MockBuild.build });

    try testing.expectEqual(@as(u32, 4), mb.attached.load(.monotonic));
    const tp = poolOf(&footprint);
    // stop / increaseDepth cleared.
    try testing.expectEqual(@as(u8, 0), tp.stop);
    try testing.expectEqual(@as(u8, 0), tp.increase_depth);
    // threads slice: length 4, non-empty backing, count == 4 via the accessors.
    try testing.expectEqual(@as(usize, 4), pool.numThreads());
    try testing.expectEqual(@as(usize, 4), tp.threads.len);
    try testing.expect(tp.threads.len != 0);
    // each threads[i] is a live SearchThread with the right idx and worker@8 slot.
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        const t: *SearchThread = @ptrFromInt(tp.threadAt(i));
        try testing.expectEqual(i, t.idx);
        // offset-8 worker read (null here; a real builder would set it).
        try testing.expectEqual(@as(usize, 8), @offsetOf(SearchThread, "worker"));
    }
    // bound slice empty.
    try testing.expectEqual(@as(usize, 0), tp.bound.len);
}

test "boundNodesAssign lays/reads/reassigns/clears the bound slice (leak-checked)" {
    // Standalone footprint -- no threads needed, just the bound slice contract that the
    // multi-node reconfigure path drives (and that single-node runs never populate, so
    // this is its ONLY gate). testing.allocator flags any missed free.
    var footprint: [graph_layout.thread_pool_size]u8 align(8) = [_]u8{0} ** graph_layout.thread_pool_size;
    const tp = poolOf(&footprint);
    tp.* = .{};

    // Assign 4 per-thread node indices; read back via the graph_layout accessors.
    const nodes = [_]usize{ 0, 1, 0, 2 };
    try boundNodesAssign(tp, testing.allocator, &nodes);
    try testing.expectEqual(@as(usize, 4), tp.boundCount());
    for (nodes, 0..) |n, i| try testing.expectEqual(n, tp.boundAt(i));

    // Reassign to a shorter list -- the prior buffer must be freed, not leaked.
    const nodes2 = [_]usize{ 3, 3 };
    try boundNodesAssign(tp, testing.allocator, &nodes2);
    try testing.expectEqual(@as(usize, 2), tp.boundCount());
    try testing.expectEqual(@as(usize, 3), tp.boundAt(0));
    try testing.expectEqual(@as(usize, 3), tp.boundAt(1));

    // Empty assign (null) frees and clears to len 0 -- the single-node do_bind==false case.
    try boundNodesAssign(tp, testing.allocator, null);
    try testing.expectEqual(@as(usize, 0), tp.boundCount());

    // A zero-length slice is also a clear (frees nothing here; must not leak/UB).
    try boundNodesAssign(tp, testing.allocator, &.{});
    try testing.expectEqual(@as(usize, 0), tp.boundCount());
}

test "boundNodesAssign unwinds leak-free on allocation failure" {
    // Now that boundNodesAssign propagates error.OutOfMemory (was `catch @panic`),
    // checkAllAllocationFailures can fail its single allocation and assert the reassign
    // frees the prior buffer and returns the error leak-free.
    const T = struct {
        fn run(a: std.mem.Allocator) !void {
            var footprint: [graph_layout.thread_pool_size]u8 align(8) = [_]u8{0} ** graph_layout.thread_pool_size;
            const tp = poolOf(&footprint);
            tp.* = .{};
            defer boundNodesAssign(tp, a, null) catch {}; // free any live buffer
            try boundNodesAssign(tp, a, &[_]usize{ 0, 1, 0, 2 });
            try boundNodesAssign(tp, a, &[_]usize{ 1, 2 });
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, T.run, .{});
}

test "Pool set(0) clears the vector; resize re-lays it" {
    var footprint: [64]u8 align(8) = [_]u8{0} ** 64;
    var mb = MockBuild{};
    var pool = Pool.init(testing.allocator, &footprint);
    defer pool.clear();

    try pool.set(1, .{ .ctx = &mb, .build = MockBuild.build });
    try testing.expectEqual(@as(usize, 1), pool.numThreads());
    try pool.set(8, .{ .ctx = &mb, .build = MockBuild.build });
    try testing.expectEqual(@as(usize, 8), pool.numThreads());
    try pool.set(0, .{ .ctx = &mb, .build = MockBuild.build });
    try testing.expectEqual(@as(usize, 0), pool.numThreads());
    try testing.expectEqual(@as(usize, 0), poolOf(&footprint).threads.len);
}
