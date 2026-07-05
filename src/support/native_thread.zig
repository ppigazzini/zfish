// Native Search Thread (big-bang stage 4, layer 1).
//
// Replaces the C++ `Thread` vehicle: a std::thread idle_loop that runs the search
// as its job. The search BODY is already Zig (zfish_worker_start_searching); this
// owns the *vehicle* -- the worker handle + the futex idle-loop runner
// (thread_runtime.zig) + the per-thread search job.
//
// LAYOUT CONTRACT: the only field any other code reads off a live Thread by offset
// is `worker` at thread_off.worker == 8 (id_collect_bmc / get_best_thread /
// nodesSearched all do `*(thread + 8)`). So `worker` MUST stay at offset 8; the
// rest is native-private. The struct is `extern` to pin that. The ThreadRuntime
// (which holds a std.Thread handle + futex atomics, not extern-friendly) lives on
// the heap behind a pointer so this footprint stays POD.
//
// This layer is wired to NOTHING yet: it is unit-tested in isolation against
// thread_runtime.zig with a mock job, so the search-launch handshake is proven
// before the ThreadPool/Engine construction (layers 3-4) attach a real Worker.

const std = @import("std");
const builtin = @import("builtin");
const rt = @import("thread_runtime.zig");
const graph_layout = @import("graph_layout");

// Marker at offset 0 (the C++ Thread had its vtable pointer here; no native reader
// touches thread@0, so this just makes a NativeThread identifiable in a dump and
// pads `worker` to offset 8).
pub const thread_tag: u64 = 0x5a_46_49_53_48_54_48_31; // "ZFISHTH1"

pub const NativeThread = extern struct {
    tag: u64 = thread_tag, // @0
    worker: ?*anyopaque = null, // @8  -- offset-read by thread_off.worker
    runtime: ?*rt.ThreadRuntime = null, // @16
    idx: usize = 0, // @24

    // Allocate + spawn the futex idle-loop runner. The Worker is attached later
    // (setWorker), by the ThreadPool construction that builds the Worker block.
    pub fn spawn(self: *NativeThread, allocator: std.mem.Allocator, idx: usize) !void {
        const runtime = try allocator.create(rt.ThreadRuntime);
        errdefer allocator.destroy(runtime);
        runtime.* = rt.ThreadRuntime{};
        try runtime.start();
        self.* = .{ .worker = null, .runtime = runtime, .idx = idx };
    }

    pub fn setWorker(self: *NativeThread, worker: ?*anyopaque) void {
        self.worker = worker;
    }

    // Submit a job to the idle loop and return immediately (the C++
    // Thread::start_searching / run_custom_job shape). The job runs on the thread.
    pub fn startJob(self: *NativeThread, job: rt.ThreadJobFn, ctx: ?*anyopaque) void {
        self.runtime.?.runCustomJob(job, ctx);
    }

    pub fn waitForSearchFinished(self: *NativeThread) void {
        self.runtime.?.waitForSearchFinished();
    }

    // Join the runner, then tear down the attached Worker. Idempotent.
    pub fn deinit(self: *NativeThread, allocator: std.mem.Allocator) void {
        if (self.runtime) |runtime| {
            runtime.deinit(); // join the idle loop first -- no thread uses worker after this
            allocator.destroy(runtime);
            self.runtime = null;
        }
        // Free the large-page Worker block the builder attached at worker@8
        // (~Worker + aligned_large_pages_free); without this the ~14 MB Worker
        // leaks on every reconfigure/teardown. Done after the join above.
        if (self.worker) |w| {
            zfish_native_worker_destroy(w);
            self.worker = null;
        }
    }
};

// C++ teardown for the native Worker (uci_bridge): ~Worker + large-page free,
// mirroring the C++ LargePagePtr deleter. Resolved natively only; the legacy
// build provides an abort stub it never calls.
extern fn zfish_native_worker_destroy(worker: *anyopaque) callconv(.c) void;

// In test builds the C++ destroyer is absent; provide a no-op stub so the module
// links standalone (the tests attach a dummy worker, never a real Worker block).
comptime {
    if (builtin.is_test) {
        @export(&testWorkerDestroyStub, .{ .name = "zfish_native_worker_destroy" });
    }
}
fn testWorkerDestroyStub(worker: *anyopaque) callconv(.c) void {
    _ = worker;
}

// The search driver entry, injected by the thread module at search start (M16.7).
// native_thread must not import position (position imports the thread stack for its
// pool ops, so the reverse would cycle), so the driver is registered as a function
// pointer rather than called by name.
pub var searchEntry: ?*const fn (?*anyopaque) callconv(.c) void = null;

// Production search job: run the registered Zig search driver on this thread, with
// the Worker pointer as context.
pub fn searchJob(ctx: ?*anyopaque) callconv(.c) void {
    if (searchEntry) |f| f(ctx);
}

// Start this thread's search: run searchJob with the attached Worker as context.
pub fn startSearching(self: *NativeThread) void {
    self.startJob(searchJob, self.worker);
}

// Reinterpret a pool thread slot (a *NativeThread) for the pool-level sibling ops.
inline fn asNativeThread(thread: *anyopaque) *NativeThread {
    return @ptrCast(@alignCast(thread));
}

// Start the sibling threads (index 1..) searching. The pool-level entry the search
// driver (position.zig) calls -- pure graph iteration + the per-thread start, so it
// needs no position import.
pub fn startPoolSiblings(pool: *anyopaque) void {
    const tp = graph_layout.ThreadPool.fromPtr(@constCast(pool));
    const n = tp.numThreads();
    var i: usize = 1;
    while (i < n) : (i += 1) startSearching(asNativeThread(tp.threadAtPtr(i)));
}

// Wait for the sibling threads (index 1..) to finish their current search.
pub fn waitPoolSiblings(pool: *anyopaque) void {
    const tp = graph_layout.ThreadPool.fromPtr(@constCast(pool));
    const n = tp.numThreads();
    var i: usize = 1;
    while (i < n) : (i += 1) asNativeThread(tp.threadAtPtr(i)).waitForSearchFinished();
}

// Per-thread Worker::clear job (the C++ Thread::clear_worker == run_custom_job([
// worker->clear()])). Submitted to the idle loop; caller waits separately.
extern fn zfish_worker_clear(worker: *anyopaque) void;

fn clearWorkerJob(ctx: ?*anyopaque) callconv(.c) void {
    zfish_worker_clear(ctx.?);
}

pub fn clearWorker(self: *NativeThread) void {
    self.startJob(clearWorkerJob, self.worker);
}

// ---- tests (isolated; mock job, no graph) -----------------------------------

const testing = std.testing;

test "NativeThread keeps worker at offset 8" {
    try testing.expectEqual(@as(usize, 0), @offsetOf(NativeThread, "tag"));
    try testing.expectEqual(@as(usize, 8), @offsetOf(NativeThread, "worker"));
}

const MockCtx = struct {
    runs: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    last_worker: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    fn job(raw: ?*anyopaque) callconv(.c) void {
        const self: *MockCtx = @ptrCast(@alignCast(raw.?));
        _ = self.runs.fetchAdd(1, .monotonic);
    }
};

test "NativeThread spawns, round-trips a job, and joins" {
    var thread: NativeThread = .{};
    try thread.spawn(testing.allocator, 0);
    defer thread.deinit(testing.allocator);

    var ctx = MockCtx{};
    var i: usize = 0;
    while (i < 500) : (i += 1) {
        thread.startJob(MockCtx.job, &ctx);
        thread.waitForSearchFinished();
    }
    try testing.expectEqual(@as(u32, 500), ctx.runs.load(.monotonic));
}

test "setWorker stores the handle read by offset 8" {
    var thread: NativeThread = .{};
    try thread.spawn(testing.allocator, 3);
    defer thread.deinit(testing.allocator);

    var dummy_worker: u64 = 0xABCD;
    thread.setWorker(&dummy_worker);

    // The offset-8 read the rest of the engine does:
    const base: [*]const u8 = @ptrCast(&thread);
    const at_8 = @as(*const usize, @ptrCast(@alignCast(base + 8))).*;
    try testing.expectEqual(@intFromPtr(&dummy_worker), at_8);
    try testing.expectEqual(@as(usize, 3), thread.idx);
}
