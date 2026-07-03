// Native ThreadPool (big-bang stage 4, layer 3).
//
// Owns native Threads and writes the C++ ThreadPool's observable 64-byte footprint
// so the offset readers keep working unchanged:
//   stop@0 (atomic_bool), increaseDepth@1 (atomic_bool),
//   threads vector {begin@16, end@24, cap@32}  (of Thread* == NativeThread*),
//   boundThreadToNumaNode vector {begin@40, end@48, cap@56}.
// num_threads == (threads_end - threads_begin) / 8; threads[i] == *(begin + i*8).
//
// LIFECYCLE NOTE (the trap that makes stages 4+6 atomic): the threads-vector buffer
// here is Zig-allocated, and each NativeThread is Zig-owned. The C++ ThreadPool
// destructor must NOT run over this footprint -- it would delete the NativeThread*
// as C++ Thread* and free the buffer with the C++ allocator. So this is only safe
// once the Engine that embeds the pool is itself natively constructed/destructed
// (layer 4). Here it is unit-tested in isolation over a standalone 64-byte buffer.
//
// The Worker construction (large-page alloc + zfish_worker_construct_full +
// SearchManager) is injected as a callback so the footprint bookkeeping is tested
// without the engine graph; layer 4 passes the real builder.

const std = @import("std");
const builtin = @import("builtin");
const NativeThread = @import("native_thread.zig").NativeThread;

pub const pool_off = struct {
    pub const stop: usize = 0;
    pub const increase_depth: usize = 1;
    pub const threads_begin: usize = 16;
    pub const threads_end: usize = 24;
    pub const threads_cap: usize = 32;
    pub const bound_begin: usize = 40;
    pub const bound_end: usize = 48;
    pub const bound_cap: usize = 56;
};

fn writeUsize(base: [*]u8, off: usize, v: usize) void {
    @as(*usize, @ptrCast(@alignCast(base + off))).* = v;
}
fn readUsize(base: [*]const u8, off: usize) usize {
    return @as(*const usize, @ptrCast(@alignCast(base + off))).*;
}

// Per-thread construction hook: given the thread index and the freshly spawned
// NativeThread (idle loop running, no Worker yet), build + attach the Worker.
// Layer 4 binds this to the large-page Worker alloc + zfish_worker_construct_full.
pub const ThreadBuilder = struct {
    ctx: ?*anyopaque = null,
    // thread is passed opaque so the C++ worker-builder can write worker@8 directly.
    build: *const fn (ctx: ?*anyopaque, idx: usize, thread: *anyopaque) callconv(.c) void,
};

// A native ThreadPool. `slot` points at the 64-byte C++ ThreadPool footprint
// (the Engine's embedded pool, or a standalone buffer in tests).
pub const NativePool = struct {
    allocator: std.mem.Allocator,
    slot: [*]u8,
    // Zig-owned backing for the threads vector: a contiguous array of
    // *NativeThread the footprint's begin/end/cap point into.
    threads: []*NativeThread = &.{},

    pub fn init(allocator: std.mem.Allocator, slot: [*]u8) NativePool {
        return .{ .allocator = allocator, .slot = slot };
    }

    // Build `count` native Threads (idle loops + Workers via the builder) and lay
    // them into the footprint. Mirrors ThreadPool::set's thread-creation loop.
    pub fn set(self: *NativePool, count: usize, builder: ThreadBuilder) !void {
        self.clear();

        // stop / increaseDepth start cleared (no search in flight).
        self.slot[pool_off.stop] = 0;
        self.slot[pool_off.increase_depth] = 0;
        // boundThreadToNumaNode: empty (no NUMA binding on the single-node path).
        writeUsize(self.slot, pool_off.bound_begin, 0);
        writeUsize(self.slot, pool_off.bound_end, 0);
        writeUsize(self.slot, pool_off.bound_cap, 0);

        if (count == 0) {
            writeUsize(self.slot, pool_off.threads_begin, 0);
            writeUsize(self.slot, pool_off.threads_end, 0);
            writeUsize(self.slot, pool_off.threads_cap, 0);
            return;
        }

        const vec = try self.allocator.alloc(*NativeThread, count);
        var built: usize = 0;
        errdefer {
            var i: usize = 0;
            while (i < built) : (i += 1) {
                vec[i].deinit(self.allocator);
                self.allocator.destroy(vec[i]);
            }
            self.allocator.free(vec);
        }
        for (vec, 0..) |*slotptr, idx| {
            const thread = try self.allocator.create(NativeThread);
            errdefer self.allocator.destroy(thread);
            thread.* = .{};
            try thread.spawn(self.allocator, idx);
            builder.build(builder.ctx, idx, @ptrCast(thread)); // attach the Worker (writes worker@8)
            slotptr.* = thread;
            built += 1;
        }
        self.threads = vec;

        const begin = @intFromPtr(vec.ptr);
        writeUsize(self.slot, pool_off.threads_begin, begin);
        writeUsize(self.slot, pool_off.threads_end, begin + count * @sizeOf(usize));
        writeUsize(self.slot, pool_off.threads_cap, begin + count * @sizeOf(usize));
    }

    // Footprint-based (stateless): recovers the threads buffer from the C++ slot's
    // begin/end, not a held slice -- so a fresh NativePool wrapper over the same
    // slot (reset_for_reconfigure, the destroy hook) tears the pool down correctly.
    // Requires a zeroed-or-valid footprint (a default-constructed C++ ThreadPool is
    // zeroed, so begin==0 is the no-op case).
    pub fn clear(self: *NativePool) void {
        const begin = readUsize(self.slot, pool_off.threads_begin);
        if (begin != 0) {
            const end = readUsize(self.slot, pool_off.threads_end);
            const count = (end - begin) / @sizeOf(usize);
            const buf = @as([*]*NativeThread, @ptrFromInt(begin))[0..count];
            // Drain any queued/in-flight job BEFORE tearing threads down. The
            // teardown path runs with the stop flag already set (quit /
            // reset_for_reconfigure), so an in-flight search bails immediately and
            // emits its bestmove here. Without this, deinit's exit flag races the
            // idle loop and can drop a just-queued-but-not-yet-started search job
            // -> a lost bestmove (deterministic for `go ...; quit` back-to-back).
            // Idle threads return immediately. Mirrors ~ThreadPool's
            // wait_for_search_finished before deleting threads.
            for (buf) |t| t.waitForSearchFinished();
            for (buf) |t| {
                t.deinit(self.allocator);
                self.allocator.destroy(t);
            }
            self.allocator.free(buf);
        }
        self.threads = &.{};
        writeUsize(self.slot, pool_off.threads_begin, 0);
        writeUsize(self.slot, pool_off.threads_end, 0);
        writeUsize(self.slot, pool_off.threads_cap, 0);
    }

    pub fn numThreads(self: *const NativePool) usize {
        const begin = readUsize(self.slot, pool_off.threads_begin);
        const end = readUsize(self.slot, pool_off.threads_end);
        if (begin == 0) return 0;
        return (end - begin) / @sizeOf(usize);
    }
};

// ---- C-ABI entry points (called by the native reconfigure + teardown) -------

// The C++ worker-builder (uci_bridge): resolves the SharedState members + numa
// params for thread `idx`, large-page-allocs + constructs the Worker, mints the
// SearchManager, and writes the Worker at thread+8 (worker@8). Single-node host.
extern fn zfish_native_worker_build(ctx: ?*anyopaque, idx: usize, thread: *anyopaque) callconv(.c) void;

const WorkerBuildCtx = extern struct {
    shared_state: ?*anyopaque,
    update_context: ?*const anyopaque,
    total: usize,
};

// Build `count` native Threads (idle loops + Workers) into the Engine's embedded
// ThreadPool footprint `pool`. Replaces the C++ per-thread add_main_thread loop.
pub fn zfish_native_threadpool_set(
    pool: *anyopaque,
    shared_state: *anyopaque,
    update_context: *const anyopaque,
    count: usize,
) void {
    var bctx = WorkerBuildCtx{ .shared_state = shared_state, .update_context = update_context, .total = count };
    var p = NativePool.init(std.heap.c_allocator, @ptrCast(pool));
    p.set(count, .{ .ctx = &bctx, .build = zfish_native_worker_build }) catch @panic("native thread pool set: OOM");
}

// Join + free every native Thread and null the footprint vector. Called by the
// native reset_for_reconfigure and the zfish_uci_engine_destruct_at teardown hook,
// BEFORE any C++ ThreadPool dtor (which then sees an empty vector and no-ops).
pub export fn zfish_native_threadpool_clear(pool: *anyopaque) void {
    var p = NativePool.init(std.heap.c_allocator, @ptrCast(pool));
    p.clear();
}

// Native equivalent of C++ ThreadPool::wait_on_thread(id): wait for one thread's
// in-flight job to finish. Reads the thread pointer out of the footprint vector
// by index and calls the native wait -- the C++ wait_on_thread would lock the C++
// Thread's std::mutex, which is garbage on a NativeThread. Routed here by the
// gated zfish_threadpool_wait_thread bridge shim in the default build.
pub export fn zfish_native_threadpool_wait_thread(pool: *anyopaque, thread_id: usize) void {
    const slot: [*]u8 = @ptrCast(pool);
    const begin = readUsize(slot, pool_off.threads_begin);
    if (begin == 0) return;
    const vec: [*]const usize = @ptrFromInt(begin);
    const thread: *NativeThread = @ptrFromInt(vec[thread_id]);
    thread.waitForSearchFinished();
}

// In test builds the real C++ builder is absent; provide a stub so the module
// links standalone. The tests drive set() with MockBuild, not this symbol.
comptime {
    if (builtin.is_test) {
        @export(&testWorkerBuildStub, .{ .name = "zfish_native_worker_build" });
    }
}
fn testWorkerBuildStub(ctx: ?*anyopaque, idx: usize, thread: *anyopaque) callconv(.c) void {
    _ = ctx;
    _ = idx;
    _ = thread;
}

// ---- tests (isolated; mock builder, standalone footprint) -------------------

const testing = std.testing;

// Mock builder: count Worker attachments, leave worker null (no graph here).
const MockBuild = struct {
    attached: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    fn build(ctx: ?*anyopaque, idx: usize, thread_ptr: *anyopaque) callconv(.c) void {
        _ = idx;
        const self: *MockBuild = @ptrCast(@alignCast(ctx.?));
        _ = self.attached.fetchAdd(1, .monotonic);
        const thread: *NativeThread = @ptrCast(@alignCast(thread_ptr));
        // Leave thread.worker null (a real builder sets it); confirm idle loop ran.
        thread.startJob(noopJob, null);
        thread.waitForSearchFinished();
    }
    fn noopJob(_: ?*anyopaque) callconv(.c) void {}
};

test "NativePool lays the C++ footprint and reads back the thread vector" {
    var footprint: [64]u8 align(8) = [_]u8{0} ** 64; // zeroed = default-constructed C++ pool
    var mb = MockBuild{};
    var pool = NativePool.init(testing.allocator, &footprint);
    defer pool.clear();

    try pool.set(4, .{ .ctx = &mb, .build = MockBuild.build });

    try testing.expectEqual(@as(u32, 4), mb.attached.load(.monotonic));
    // stop / increaseDepth cleared.
    try testing.expectEqual(@as(u8, 0), footprint[pool_off.stop]);
    try testing.expectEqual(@as(u8, 0), footprint[pool_off.increase_depth]);
    // threads vector: begin/end consistent, count == 4 via the offset readers.
    try testing.expectEqual(@as(usize, 4), pool.numThreads());
    const begin = readUsize(&footprint, pool_off.threads_begin);
    const end = readUsize(&footprint, pool_off.threads_end);
    try testing.expect(begin != 0);
    try testing.expectEqual(@as(usize, 4), (end - begin) / 8);
    // each threads[i] is a live NativeThread with the right idx and worker@8 slot.
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        const tptr = readUsize(@ptrFromInt(begin), i * 8);
        const t: *NativeThread = @ptrFromInt(tptr);
        try testing.expectEqual(i, t.idx);
        // offset-8 worker read (null here; a real builder would set it).
        try testing.expectEqual(@as(usize, 8), @offsetOf(NativeThread, "worker"));
    }
    // bound vector empty.
    try testing.expectEqual(@as(usize, 0), readUsize(&footprint, pool_off.bound_begin));
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
    try testing.expectEqual(@as(usize, 0), readUsize(&footprint, pool_off.threads_begin));
}
