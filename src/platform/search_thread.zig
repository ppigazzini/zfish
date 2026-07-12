// Search thread.
//
// The thread vehicle: a std.Thread idle_loop that runs the search as its job. The
// search BODY lives elsewhere; this owns the *vehicle* -- the worker handle + the
// futex idle-loop runner (thread_runtime.zig) + the per-thread search job.
//
// LAYOUT CONTRACT: the only field any other code reads off a live Thread by offset
// is `worker` at offset 8 (worker_layout.Thread / the sibling ops all read `*(thread
// + 8)`). `worker` stays at offset 8 because the four fields are equal-size (u64/
// pointer) and Zig keeps their declaration order; the `@offsetOf(worker) == 8` test
// below guards it. The ThreadRuntime (std.Thread handle + futex atomics) lives on
// the heap behind a pointer so this footprint stays small.
//
// This module is unit-tested in isolation against thread_runtime.zig with a mock
// job, so the search-launch handshake is proven independently of the
// ThreadPool/Engine construction that attaches a real Worker.

const std = @import("std");
const builtin = @import("builtin");
const rt = @import("thread_runtime");
const worker_layout = @import("worker_layout");
const runtime_hooks = @import("runtime_hooks");

// Marker at offset 0 (no reader touches thread@0, so this just makes a
// SearchThread identifiable in a dump and pads `worker` to offset 8).
pub const thread_tag: u64 = 0x5a_46_49_53_48_54_48_31; // "ZFISHTH1"

pub const SearchThread = struct {
    tag: u64 = thread_tag, // @0
    worker: ?*anyopaque = null, // @8  -- offset-read by thread_off.worker
    runtime: ?*rt.ThreadRuntime = null, // @16
    idx: usize = 0, // @24

    // Allocate + spawn the futex idle-loop runner. The Worker is attached later
    // (setWorker), by the ThreadPool construction that builds the Worker block.
    pub fn spawn(self: *SearchThread, allocator: std.mem.Allocator, idx: usize) !void {
        const runtime = try allocator.create(rt.ThreadRuntime);
        errdefer allocator.destroy(runtime);
        runtime.* = rt.ThreadRuntime{};
        try runtime.start();
        self.* = .{ .worker = null, .runtime = runtime, .idx = idx };
    }

    pub fn setWorker(self: *SearchThread, worker: ?*anyopaque) void {
        self.worker = worker;
    }

    // Submit a job to the idle loop and return immediately. The job runs on the thread.
    pub fn startJob(self: *SearchThread, job: rt.ThreadJobFn, ctx: ?*anyopaque) void {
        self.runtime.?.runCustomJob(job, ctx);
    }

    pub fn waitForSearchFinished(self: *SearchThread) void {
        self.runtime.?.waitForSearchFinished();
    }

    // Join the runner, then tear down the attached Worker. Idempotent.
    pub fn deinit(self: *SearchThread, allocator: std.mem.Allocator) void {
        if (self.runtime) |runtime| {
            runtime.deinit(); // join the idle loop first -- no thread uses worker after this
            allocator.destroy(runtime);
            self.runtime = null;
        }
        // Free the large-page Worker block the builder attached at worker@8 (the
        // Worker teardown + aligned_large_pages_free); without this the ~14 MB Worker
        // leaks on every reconfigure/teardown. Done after the join above.
        if (self.worker) |w| {
            runtime_hooks.worker_destroy(w);
            self.worker = null;
        }
    }
};

// The teardown for the Worker (via runtime_hooks.worker_destroy):
// destruct the Worker + large-page free.

// The search_thread tests attach only dummy workers (worker == 0), so deinit's
// runtime_hooks.worker_destroy call is never reached — no test stub needed.

// The search driver entry, injected by the thread module at search start.
// search_thread must not import position (position imports the thread stack for its
// pool ops, so the reverse would cycle), so the driver is registered as a function
// pointer rather than called by name.
pub var searchEntry: ?*const fn (?*anyopaque) void = null;

// Production search job: run the registered Zig search driver on this thread, with
// the Worker pointer as context.
pub fn searchJob(ctx: ?*anyopaque) void {
    if (searchEntry) |f| f(ctx);
}

// Start this thread's search: run searchJob with the attached Worker as context.
pub fn startSearching(self: *SearchThread) void {
    self.startJob(searchJob, self.worker);
}

// Reinterpret a pool thread slot (a *SearchThread) for the pool-level sibling ops.
inline fn asSearchThread(thread: *worker_layout.Thread) *SearchThread {
    return @ptrCast(@alignCast(thread));
}

// Start the sibling threads (index 1..) searching. The pool-level entry the search
// driver (position.zig) calls -- pure graph iteration + the per-thread start, so it
// needs no position import.
pub fn startPoolSiblings(pool: *worker_layout.ThreadPool) void {
    const tp = pool;
    const n = tp.numThreads();
    var i: usize = 1;
    while (i < n) : (i += 1) startSearching(asSearchThread(tp.threadTyped(i)));
}

// Wait for the sibling threads (index 1..) to finish their current search.
pub fn waitPoolSiblings(pool: *worker_layout.ThreadPool) void {
    const tp = pool;
    const n = tp.numThreads();
    var i: usize = 1;
    while (i < n) : (i += 1) asSearchThread(tp.threadTyped(i)).waitForSearchFinished();
}

// Per-thread worker-clear job. Submitted to the idle loop; caller waits separately.

fn clearWorkerJob(ctx: ?*anyopaque) void {
    runtime_hooks.worker_clear(ctx.?);
}

pub fn clearWorker(self: *SearchThread) void {
    self.startJob(clearWorkerJob, self.worker);
}

// ---- tests (isolated; mock job, no graph) -----------------------------------

const testing = std.testing;

test "SearchThread keeps worker at offset 8" {
    try testing.expectEqual(@as(usize, 0), @offsetOf(SearchThread, "tag"));
    try testing.expectEqual(@as(usize, 8), @offsetOf(SearchThread, "worker"));
}

const MockCtx = struct {
    runs: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    last_worker: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    fn job(raw: ?*anyopaque) void {
        const self: *MockCtx = @ptrCast(@alignCast(raw.?));
        _ = self.runs.fetchAdd(1, .monotonic);
    }
};

test "SearchThread spawns, round-trips a job, and joins" {
    var thread: SearchThread = .{};
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
    // The engine registers worker_destroy at startup; a standalone test does
    // not, so deinit()'s `worker_destroy.?(worker)` on the mock worker below
    // would deref a null hook (UB -- silent under ReleaseFast, a panic under
    // ReleaseSafe). Install a no-op teardown for the mock (it is a stack value, not
    // a real large-page Worker) and restore the prior hook after.
    const prev_destroy = runtime_hooks.worker_destroy;
    runtime_hooks.worker_destroy = struct {
        fn noop(_: *anyopaque) void {}
    }.noop;
    defer runtime_hooks.worker_destroy = prev_destroy;

    var thread: SearchThread = .{};
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
