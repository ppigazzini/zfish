// Native ThreadPool (big-bang stage 4, layer 3).
//
// Owns native Threads and writes the ThreadPool's observable 56-byte footprint
// so the accessors keep working unchanged:
//   stop@0 (atomic_bool), increaseDepth@1 (atomic_bool),
//   threads slice {ptr@16, len@24}  (of Thread* == NativeThread* addresses, M19.1),
//   boundThreadToNumaNode slice {ptr@32, len@40}  (per-thread NUMA node, M19.1).
// num_threads == threads.len; threads[i] == the i-th slice element (a Thread* addr).
//
// LIFECYCLE NOTE (the trap that makes stages 4+6 atomic): the threads-vector buffer
// here is Zig-allocated, and each NativeThread is Zig-owned. The C++ ThreadPool
// destructor must NOT run over this footprint -- it would delete the NativeThread*
// as C++ Thread* and free the buffer with the C++ allocator. So this is only safe
// once the Engine that embeds the pool is itself natively constructed/destructed
// (layer 4). Here it is unit-tested in isolation over a standalone 64-byte buffer.
//
// The Worker construction (large-page alloc + constructFull +
// SearchManager) is injected as a callback so the footprint bookkeeping is tested
// without the engine graph; layer 4 passes the real builder.

const std = @import("std");
const builtin = @import("builtin");
const NativeThread = @import("native_thread").NativeThread;
const graph_layout = @import("graph_layout");
const native_hooks = @import("native_hooks");
const ThreadPool = graph_layout.ThreadPool;

// The 64-byte pool footprint is now a native graph_layout.ThreadPool (M16.8 de-mirror):
// the writer here and every reader (graph_layout accessors, the search's captured
// &stop pointer) go through the same typed struct, so Zig owns the field placement.
inline fn poolOf(slot: [*]u8) *ThreadPool {
    return ThreadPool.fromPtr(@ptrCast(slot));
}

// Per-thread construction hook: given the thread index and the freshly spawned
// NativeThread (idle loop running, no Worker yet), build + attach the Worker.
// Layer 4 binds this to the large-page Worker alloc + constructFull.
pub const ThreadBuilder = struct {
    ctx: ?*anyopaque = null,
    // thread is passed opaque so the native worker-builder can write worker@8 directly.
    build: *const fn (ctx: ?*anyopaque, idx: usize, thread: *anyopaque) void,
};

// A native ThreadPool. `slot` points at the 64-byte C++ ThreadPool footprint
// (the Engine's embedded pool, or a standalone buffer in tests).
pub const NativePool = struct {
    allocator: std.mem.Allocator,
    slot: [*]u8,

    pub fn init(allocator: std.mem.Allocator, slot: [*]u8) NativePool {
        return .{ .allocator = allocator, .slot = slot };
    }

    // Build `count` native Threads (idle loops + Workers via the builder) and lay
    // them into the footprint. Mirrors ThreadPool::set's thread-creation loop.
    pub fn set(self: *NativePool, count: usize, builder: ThreadBuilder) !void {
        self.clear();
        const tp = poolOf(self.slot);

        // stop / increaseDepth start cleared (no search in flight).
        tp.stop = 0;
        tp.increase_depth = 0;
        // boundThreadToNumaNode: empty (no NUMA binding on the single-node path). The
        // multi-node reconfigure path assigns it via boundNodesAssign before building
        // threads; this reset matches the C++ ThreadPool::set clearing it first.
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
                const t: *NativeThread = @ptrFromInt(vec[i]);
                t.deinit(self.allocator);
                self.allocator.destroy(t);
            }
            self.allocator.free(vec);
        }
        for (vec, 0..) |*slotptr, idx| {
            const thread = try self.allocator.create(NativeThread);
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
    // `threads` slice, not a held field -- so a fresh NativePool wrapper over the same
    // slot (reset_for_reconfigure, the destroy hook) tears the pool down correctly.
    // Requires a zeroed-or-valid footprint (a default-constructed ThreadPool has an
    // empty slice, so len==0 is the no-op case).
    pub fn clear(self: *NativePool) void {
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
                const t: *NativeThread = @ptrFromInt(addr);
                t.waitForSearchFinished();
            }
            for (buf) |addr| {
                const t: *NativeThread = @ptrFromInt(addr);
                t.deinit(self.allocator);
                self.allocator.destroy(t);
            }
            self.allocator.free(buf);
        }
        tp.threads = &.{};
    }

    pub fn numThreads(self: *const NativePool) usize {
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
// ThreadPool footprint `pool`. Replaces the C++ per-thread add_main_thread loop.
pub fn set(
    pool: *graph_layout.ThreadPool,
    shared_state: *anyopaque,
    update_context: *const anyopaque,
    count: usize,
) void {
    var bctx = WorkerBuildCtx{ .shared_state = shared_state, .update_context = update_context, .total = count };
    var p = NativePool.init(std.heap.c_allocator, @ptrCast(pool));
    p.set(count, .{ .ctx = &bctx, .build = native_hooks.native_worker_build }) catch @panic("native thread pool set: OOM");
}

// Join + free every native Thread and null the footprint vector. Called by the
// native reset_for_reconfigure and the engine teardown hook.
pub fn clear(pool: *graph_layout.ThreadPool) void {
    var p = NativePool.init(std.heap.c_allocator, @ptrCast(pool));
    p.clear();
}

// Native equivalent of C++ ThreadPool::wait_on_thread(id): wait for one thread's
// in-flight job to finish. Reads the thread pointer out of the footprint vector
// by index and calls the native wait -- the C++ wait_on_thread would lock the C++
// Thread's std::mutex, which is garbage on a NativeThread.
pub fn waitThread(pool: *graph_layout.ThreadPool, thread_id: usize) void {
    const tp = poolOf(@ptrCast(pool));
    if (tp.threads.len == 0) return;
    const thread: *NativeThread = @ptrFromInt(tp.threadAt(thread_id));
    thread.waitForSearchFinished();
}

// Assign the pool's boundThreadToNumaNode footprint slice (M19.1: a typed []usize via
// the allocator interface, was a raw c.malloc {begin,end,cap} triple in thread.zig).
// `nodes` is the per-thread NUMA-node index list, or null/empty to clear. Frees any
// prior buffer on every reassign, so the lifecycle is leak-clean under a checked
// allocator (the bound-vector unit test drives exactly this). Lives here beside set()
// -- which clears the same footprint slot -- rather than in thread.zig, so all the
// ThreadPool-footprint writes sit in one module and the writer is directly testable.
pub fn boundNodesAssign(pool: *graph_layout.ThreadPool, allocator: std.mem.Allocator, nodes: ?[]const usize) void {
    const tp = pool;
    if (tp.bound.len != 0) allocator.free(tp.bound);
    tp.bound = &.{};
    const src = nodes orelse return;
    if (src.len == 0) return;
    const buf = allocator.alloc(usize, src.len) catch @panic("bound_nodes_assign: OOM");
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
        const thread: *NativeThread = @ptrCast(@alignCast(thread_ptr));
        // Leave thread.worker null (a real builder sets it); confirm idle loop ran.
        thread.startJob(noopJob, null);
        thread.waitForSearchFinished();
    }
    fn noopJob(_: ?*anyopaque) void {}
};

test "NativePool lays the C++ footprint and reads back the thread vector" {
    var footprint: [64]u8 align(8) = [_]u8{0} ** 64; // zeroed = default-constructed C++ pool
    var mb = MockBuild{};
    var pool = NativePool.init(testing.allocator, &footprint);
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
    // each threads[i] is a live NativeThread with the right idx and worker@8 slot.
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        const t: *NativeThread = @ptrFromInt(tp.threadAt(i));
        try testing.expectEqual(i, t.idx);
        // offset-8 worker read (null here; a real builder would set it).
        try testing.expectEqual(@as(usize, 8), @offsetOf(NativeThread, "worker"));
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
    boundNodesAssign(tp, testing.allocator, &nodes);
    try testing.expectEqual(@as(usize, 4), tp.boundCount());
    for (nodes, 0..) |n, i| try testing.expectEqual(n, tp.boundAt(i));

    // Reassign to a shorter list -- the prior buffer must be freed, not leaked.
    const nodes2 = [_]usize{ 3, 3 };
    boundNodesAssign(tp, testing.allocator, &nodes2);
    try testing.expectEqual(@as(usize, 2), tp.boundCount());
    try testing.expectEqual(@as(usize, 3), tp.boundAt(0));
    try testing.expectEqual(@as(usize, 3), tp.boundAt(1));

    // Empty assign (null) frees and clears to len 0 -- the single-node do_bind==false case.
    boundNodesAssign(tp, testing.allocator, null);
    try testing.expectEqual(@as(usize, 0), tp.boundCount());

    // A zero-length slice is also a clear (frees nothing here; must not leak/UB).
    boundNodesAssign(tp, testing.allocator, &.{});
    try testing.expectEqual(@as(usize, 0), tp.boundCount());
}

test "NativePool set(0) clears the vector; resize re-lays it" {
    var footprint: [64]u8 align(8) = [_]u8{0} ** 64;
    var mb = MockBuild{};
    var pool = NativePool.init(testing.allocator, &footprint);
    defer pool.clear();

    try pool.set(1, .{ .ctx = &mb, .build = MockBuild.build });
    try testing.expectEqual(@as(usize, 1), pool.numThreads());
    try pool.set(8, .{ .ctx = &mb, .build = MockBuild.build });
    try testing.expectEqual(@as(usize, 8), pool.numThreads());
    try pool.set(0, .{ .ctx = &mb, .build = MockBuild.build });
    try testing.expectEqual(@as(usize, 0), pool.numThreads());
    try testing.expectEqual(@as(usize, 0), poolOf(&footprint).threads.len);
}
