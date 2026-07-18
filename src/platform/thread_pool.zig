// Thread pool.
//
// Own the search threads. The footprint is worker_layout.ThreadPool, whose size is asserted
// there (worker_layout.thread_pool_size) rather than restated here -- an earlier copy of the
// numbers in this comment drifted to 56 bytes and omitted setup_states entirely.
// num_threads == threads.len; threads[i] == the i-th slice element (a Thread* addr).
//
// LIFECYCLE NOTE: route teardown through the pool's clear() path -- the threads-slice
// buffer here is Zig-allocated and each SearchThread Zig-owned -- rather than any
// implicit teardown over this footprint. Exercise it in unit tests in isolation over
// a standalone 64-byte buffer.
//
// Inject the Worker construction (large-page alloc + constructFull +
// SearchManager) as a callback so the footprint bookkeeping is tested
// without the engine graph; the engine passes the real builder.

const std = @import("std");
const builtin = @import("builtin");
const SearchThread = @import("search_thread").SearchThread;
const worker_layout = @import("worker_layout");
const runtime_hooks = @import("runtime_hooks");
const ThreadPool = worker_layout.ThreadPool;

// Treat the 64-byte pool footprint as a worker_layout.ThreadPool: the writer here
// and every reader (worker_layout accessors, the search's captured
// &stop pointer) go through the same typed struct, so Zig owns the field placement.
inline fn poolOf(slot: [*]u8) *ThreadPool {
    return ThreadPool.fromPtr(@ptrCast(slot));
}

// Per-thread construction hook: given the thread index and the freshly spawned
// SearchThread (idle loop running, no Worker yet), build + attach the Worker.
// Bind this in Layer 4 to the large-page Worker alloc + constructFull.
pub const ThreadBuilder = struct {
    ctx: ?*anyopaque = null,
    // Pass thread opaque so the worker-builder can write worker@8 directly.
    build: *const fn (ctx: ?*anyopaque, idx: usize, thread: *anyopaque) error{OutOfMemory}!void,
};

// Represent the thread pool; `slot` points at the 64-byte ThreadPool footprint
// (the Engine's embedded pool, or a standalone buffer in tests).
pub const Pool = struct {
    allocator: std.mem.Allocator,
    slot: [*]u8,

    pub fn init(allocator: std.mem.Allocator, slot: [*]u8) Pool {
        return .{ .allocator = allocator, .slot = slot };
    }

    // Build `count` threads (idle loops + Workers via the builder) and lay
    // them into the footprint.
    pub fn set(self: *Pool, count: usize, builder: ThreadBuilder) !void {
        self.clear();
        const tp = poolOf(self.slot);

        // Clear stop / increaseDepth at start (no search in flight).
        tp.stop = 0;
        tp.increase_depth = 0;
        // Empty boundThreadToNumaNode here (no NUMA binding on the single-node path); the
        // multi-node reconfigure path assigns it via boundNodesAssign before building
        // threads, so clear it here first.
        tp.bound = &.{};

        if (count == 0) {
            tp.threads = &.{};
            return;
        }

        // Treat the footprint's threads slice as the backing buffer itself -- a []usize of
        // Thread* addresses; clear() recovers it straight from tp.threads (see its note).
        const vec = try self.allocator.alloc(*worker_layout.Thread, count);
        var built: usize = 0;
        errdefer {
            var i: usize = 0;
            while (i < built) : (i += 1) {
                const t: *SearchThread = @ptrCast(@alignCast(vec[i]));
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
            try builder.build(builder.ctx, idx, @ptrCast(thread)); // attach the Worker (writes worker@8)
            slotptr.* = @ptrCast(thread);
            built += 1;
        }
        tp.threads = vec;
    }

    // Recover the threads buffer straight from the slot's `threads` slice, not a held
    // field (footprint-based, stateless) -- so a fresh Pool wrapper over the same
    // slot (reset_for_reconfigure, the destroy hook) tears the pool down correctly.
    // Require a zeroed-or-valid footprint (a default-constructed ThreadPool has an
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
            // Idle threads return immediately. Wait for every in-flight search to
            // finish, as upstream does before deleting threads.
            for (buf) |thread| {
                const t: *SearchThread = @ptrCast(@alignCast(thread));
                t.waitForSearchFinished();
            }
            for (buf) |thread| {
                const t: *SearchThread = @ptrCast(@alignCast(thread));
                t.deinit(self.allocator);
                self.allocator.destroy(t);
            }
            self.allocator.free(buf);
        }
        tp.threads = &.{};

        // Free the bound-node buffer here: boundNodesAssign is the only other free site, and
        // clear() is the one point both the reconfigure and the teardown path pass through.
        if (tp.bound.len != 0) self.allocator.free(tp.bound);
        tp.bound = &.{};
    }

    pub fn numThreads(self: *const Pool) usize {
        return poolOf(self.slot).numThreads();
    }
};

// ---- Entry points (called by the reconfigure + teardown) -------

// Build the worker: resolve the SharedState members + numa params for
// thread `idx`, large-page-alloc + construct the Worker, mint the SearchManager,
// and write the Worker at thread+8 (worker@8). Single-node host.

const WorkerBuildCtx = struct {
    shared_state: ?*anyopaque,
    update_context: ?*const anyopaque,
    total: usize,
};

// Build `count` threads (idle loops + Workers) into the Engine's embedded
// ThreadPool footprint `pool`.
pub fn set(
    pool: *worker_layout.ThreadPool,
    shared_state: *anyopaque,
    update_context: *const anyopaque,
    count: usize,
) !void {
    var bctx = WorkerBuildCtx{ .shared_state = shared_state, .update_context = update_context, .total = count };
    var p = Pool.init(std.heap.c_allocator, @ptrCast(pool));
    // Propagate the OOM / thread-spawn error to the engine's resize boundary
    // instead of panicking here (the caller reconfigure -> resizeThreads is now !void).
    try p.set(count, .{ .ctx = &bctx, .build = runtime_hooks.worker_build });
}

// Join + free every thread and null the footprint slice. Serve the
// reset_for_reconfigure and the engine teardown hook.
pub fn clear(pool: *worker_layout.ThreadPool) void {
    var p = Pool.init(std.heap.c_allocator, @ptrCast(pool));
    p.clear();
}

// Wait for one thread's in-flight job to finish. Read the thread pointer out of
// the footprint slice by index and call the wait.
pub fn waitThread(pool: *worker_layout.ThreadPool, thread_id: usize) void {
    const tp = poolOf(@ptrCast(pool));
    if (tp.threads.len == 0) return;
    const thread: *SearchThread = @ptrCast(@alignCast(tp.threadAt(thread_id)));
    thread.waitForSearchFinished();
}

// Assign the pool's boundThreadToNumaNode footprint slice (a typed []usize via
// the allocator interface).
// Pass `nodes` as the per-thread NUMA-node index list, or null/empty to clear. Free any
// prior buffer on every reassign, so the lifecycle is leak-clean under a checked
// allocator (the bound-slice unit test drives exactly this). Keep this here beside set()
// -- which clears the same footprint slot -- rather than in thread.zig, so all the
// ThreadPool-footprint writes sit in one module and the writer is directly testable.
pub fn boundNodesAssign(pool: *worker_layout.ThreadPool, allocator: std.mem.Allocator, nodes: ?[]const usize) error{OutOfMemory}!void {
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
    fn build(ctx: ?*anyopaque, idx: usize, thread_ptr: *anyopaque) error{OutOfMemory}!void {
        _ = idx;
        const self: *MockBuild = @ptrCast(@alignCast(ctx.?));
        _ = self.attached.fetchAdd(1, .monotonic);
        const thread: *SearchThread = @ptrCast(@alignCast(thread_ptr));
        // Leave thread.worker null (a real builder sets it); confirm the idle loop ran.
        thread.startJob(noopJob, null);
        thread.waitForSearchFinished();
    }
    fn noopJob(_: ?*anyopaque) void {}
};

test "Pool lays the ThreadPool footprint and reads back the thread vector" {
    var footprint: [64]u8 align(8) = @splat(0); // zeroed = default-constructed pool
    var mb = MockBuild{};
    var pool = Pool.init(testing.allocator, &footprint);
    defer pool.clear();

    try pool.set(4, .{ .ctx = &mb, .build = MockBuild.build });

    try testing.expectEqual(@as(u32, 4), mb.attached.load(.monotonic));
    const tp = poolOf(&footprint);
    // Confirm stop / increaseDepth cleared.
    try testing.expectEqual(@as(u8, 0), tp.stop);
    try testing.expectEqual(@as(u8, 0), tp.increase_depth);
    // Check the threads slice: length 4, non-empty backing, count == 4 via the accessors.
    try testing.expectEqual(@as(usize, 4), pool.numThreads());
    try testing.expectEqual(@as(usize, 4), tp.threads.len);
    try testing.expect(tp.threads.len != 0);
    // Verify each threads[i] is a live SearchThread with the right idx and worker@8 slot.
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        const t: *SearchThread = @ptrCast(@alignCast(tp.threadAt(i)));
        try testing.expectEqual(i, t.idx);
        // Read the offset-8 worker (null here; a real builder would set it).
        try testing.expectEqual(@as(usize, 8), @offsetOf(SearchThread, "worker"));
    }
    // Confirm the bound slice is empty.
    try testing.expectEqual(@as(usize, 0), tp.bound.len);
}

test "boundNodesAssign lays/reads/reassigns/clears the bound slice (leak-checked)" {
    // Use a standalone footprint -- no threads needed, just the bound slice contract that the
    // multi-node reconfigure path drives (and that single-node runs never populate, so
    // this is its ONLY gate). testing.allocator flags any missed free.
    var footprint: [worker_layout.thread_pool_size]u8 align(8) = @splat(0);
    const tp = poolOf(&footprint);
    tp.* = .{};

    // Assign 4 per-thread node indices; read back via the worker_layout accessors.
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

    // Assign empty (null) to free and clear to len 0 -- the single-node do_bind==false case.
    try boundNodesAssign(tp, testing.allocator, null);
    try testing.expectEqual(@as(usize, 0), tp.boundCount());

    // Treat a zero-length slice as a clear too (frees nothing here; must not leak/UB).
    try boundNodesAssign(tp, testing.allocator, &.{});
    try testing.expectEqual(@as(usize, 0), tp.boundCount());
}

test "boundNodesAssign unwinds leak-free on allocation failure" {
    // Fail checkAllAllocationFailures' single allocation and assert the reassign frees the
    // prior buffer and returns the error leak-free, now that boundNodesAssign propagates
    // error.OutOfMemory (was `catch @panic`).
    const T = struct {
        fn run(a: std.mem.Allocator) !void {
            var footprint: [worker_layout.thread_pool_size]u8 align(8) = @splat(0);
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
    var footprint: [64]u8 align(8) = @splat(0);
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
