// Zig-owned thread job runner (engine-graph reimplementation).
//
// Replaces the C++ Thread idle_loop / run_custom_job / wait_for_search_finished
// handshake so worker threads can be owned by Zig once engine construction moves
// off the C++ object graph. Self-contained (std only): it owns a std.Thread and
// executes opaque jobs (a C-ABI callback plus context pointer), exactly as the
// C++ runner executes std::function<void()>.
//
// Zig 0.16 removed std.Thread.Mutex / Condition / Futex, so the blocking
// primitives are built directly on the Linux futex syscall: a canonical
// three-state (Drepper) mutex and a sequence-counter condition variable. Both
// are exercised by the tests at the bottom, which spawn the thread and
// round-trip jobs, so the concurrency handshake is verified here rather than
// deferred to the wiring step.

const std = @import("std");
const linux = std.os.linux;

const Atomic = std.atomic.Value(u32);

fn futexWait(ptr: *const Atomic, expect: u32) void {
    // FUTEX_WAIT reads the 4th (timeout) syscall argument, so it MUST be passed
    // explicitly as NULL (wait indefinitely). futex_3arg leaves the timeout
    // register undefined -> the kernel dereferences garbage -> EFAULT, so the wait
    // returns immediately and the predicate loop busy-spins (and valgrind flags
    // "futex(timeout) points to unaddressable byte(s)"). futex_4arg(..., null)
    // makes the thread actually block. (WAKE genuinely ignores the extra args, so
    // futexWake keeps using futex_3arg.)
    _ = linux.futex_4arg(&ptr.raw, .{ .cmd = .WAIT, .private = true }, expect, null);
}

fn futexWake(ptr: *const Atomic, count: u32) void {
    _ = linux.futex_3arg(&ptr.raw, .{ .cmd = .WAKE, .private = true }, count);
}

// Three-state futex mutex (0 = unlocked, 1 = locked, 2 = locked with waiters).
pub const Mutex = struct {
    state: Atomic = Atomic.init(0),

    pub fn lock(m: *Mutex) void {
        // Fast path: uncontended acquire.
        if (m.state.cmpxchgStrong(0, 1, .acquire, .monotonic) == null)
            return;

        // Contended: mark waiters and block until the holder hands it over.
        var current = m.state.swap(2, .acquire);
        while (current != 0) {
            futexWait(&m.state, 2);
            current = m.state.swap(2, .acquire);
        }
    }

    pub fn unlock(m: *Mutex) void {
        // If there were waiters (state was 2), wake exactly one.
        if (m.state.fetchSub(1, .release) != 1) {
            m.state.store(0, .release);
            futexWake(&m.state, 1);
        }
    }
};

// Sequence-counter condition variable. Callers use predicate loops, so spurious
// wakeups are harmless.
pub const Condition = struct {
    seq: Atomic = Atomic.init(0),

    pub fn wait(cv: *Condition, mutex: *Mutex) void {
        const observed = cv.seq.load(.monotonic);
        mutex.unlock();
        futexWait(&cv.seq, observed);
        mutex.lock();
    }

    pub fn signal(cv: *Condition) void {
        _ = cv.seq.fetchAdd(1, .monotonic);
        futexWake(&cv.seq, 1);
    }

    pub fn broadcast(cv: *Condition) void {
        _ = cv.seq.fetchAdd(1, .monotonic);
        futexWake(&cv.seq, std.math.maxInt(u32));
    }
};

pub const ThreadJobFn = *const fn (?*anyopaque) callconv(.c) void;

pub const ThreadRuntime = struct {
    handle: ?std.Thread = null,
    mutex: Mutex = .{},
    cond: Condition = .{},
    job_fn: ?ThreadJobFn = null,
    job_ctx: ?*anyopaque = null,
    // 'searching' starts true and idle_loop drives it to false once the thread
    // parks, matching the C++ Thread constructor's stated contract.
    searching: bool = true,
    exit: bool = false,

    pub fn start(self: *ThreadRuntime) std.Thread.SpawnError!void {
        self.handle = try std.Thread.spawn(.{}, idleLoop, .{self});
        self.waitForSearchFinished();
    }

    fn idleLoop(self: *ThreadRuntime) void {
        while (true) {
            self.mutex.lock();
            self.searching = false;
            self.cond.broadcast(); // wake anyone waiting for search-finished
            // The predicate must include `exit`: deinit may set exit+searching and
            // broadcast while this loop is between iterations (just past a job). If
            // we then re-enter here, set searching=false, and waited on `searching`
            // alone, we would re-park and never observe the exit -- nothing sets
            // searching=true again after deinit's single broadcast. Waiting on
            // `!searching and !exit` makes the exit signal impossible to miss.
            while (!self.searching and !self.exit) self.cond.wait(&self.mutex);

            if (self.exit) {
                self.mutex.unlock();
                return;
            }

            const job_fn = self.job_fn;
            const job_ctx = self.job_ctx;
            self.job_fn = null;
            self.mutex.unlock();

            if (job_fn) |run| run(job_ctx);
        }
    }

    pub fn runCustomJob(self: *ThreadRuntime, job_fn: ThreadJobFn, job_ctx: ?*anyopaque) void {
        self.mutex.lock();
        while (self.searching) self.cond.wait(&self.mutex);
        self.job_fn = job_fn;
        self.job_ctx = job_ctx;
        self.searching = true;
        self.mutex.unlock();
        self.cond.broadcast();
    }

    pub fn waitForSearchFinished(self: *ThreadRuntime) void {
        self.mutex.lock();
        while (self.searching) self.cond.wait(&self.mutex);
        self.mutex.unlock();
    }

    pub fn deinit(self: *ThreadRuntime) void {
        self.mutex.lock();
        self.exit = true;
        self.searching = true;
        self.mutex.unlock();
        self.cond.broadcast();
        if (self.handle) |handle| handle.join();
        self.handle = null;
    }
};

// A pool of Zig-owned worker threads. Mirrors the C++ ThreadPool job-dispatch
// surface (run_on_thread / wait_on_thread / per-thread start + wait), plus the
// shared `stop` flag the search polls. Thread 0 is the main thread. The pool
// owns the ThreadRuntime array; the per-thread search payload is attached by
// the caller through the job context, exactly as the C++ pool attaches Workers.
pub const ThreadPool = struct {
    threads: []ThreadRuntime = &.{},
    allocator: std.mem.Allocator,
    stop: Atomic = Atomic.init(0),

    pub fn init(allocator: std.mem.Allocator) ThreadPool {
        return .{ .allocator = allocator };
    }

    pub fn set(self: *ThreadPool, count: usize) !void {
        self.clear();
        if (count == 0) return;
        self.threads = try self.allocator.alloc(ThreadRuntime, count);
        var started: usize = 0;
        errdefer {
            var i: usize = 0;
            while (i < started) : (i += 1) self.threads[i].deinit();
            self.allocator.free(self.threads);
            self.threads = &.{};
        }
        for (self.threads) |*t| {
            t.* = ThreadRuntime{};
            try t.start();
            started += 1;
        }
    }

    pub fn clear(self: *ThreadPool) void {
        for (self.threads) |*t| t.deinit();
        if (self.threads.len != 0) self.allocator.free(self.threads);
        self.threads = &.{};
    }

    pub fn numThreads(self: *const ThreadPool) usize {
        return self.threads.len;
    }

    pub fn runOnThread(self: *ThreadPool, thread_id: usize, job_fn: ThreadJobFn, job_ctx: ?*anyopaque) void {
        self.threads[thread_id].runCustomJob(job_fn, job_ctx);
    }

    pub fn waitOnThread(self: *ThreadPool, thread_id: usize) void {
        self.threads[thread_id].waitForSearchFinished();
    }

    pub fn waitForSearchFinished(self: *ThreadPool) void {
        for (self.threads) |*t| t.waitForSearchFinished();
    }

    pub fn setStop(self: *ThreadPool, value: bool) void {
        self.stop.store(@intFromBool(value), .monotonic);
    }

    pub fn stopped(self: *const ThreadPool) bool {
        return self.stop.load(.monotonic) != 0;
    }
};

const TestCtx = struct {
    counter: Atomic = Atomic.init(0),

    fn job(raw: ?*anyopaque) callconv(.c) void {
        const self: *TestCtx = @ptrCast(@alignCast(raw.?));
        _ = self.counter.fetchAdd(1, .monotonic);
    }
};

test "mutex provides mutual exclusion under contention" {
    const Shared = struct {
        mutex: Mutex = .{},
        value: u64 = 0,

        fn bump(self: *@This()) void {
            var i: usize = 0;
            while (i < 100_000) : (i += 1) {
                self.mutex.lock();
                self.value += 1;
                self.mutex.unlock();
            }
        }
    };

    var shared = Shared{};
    var threads: [4]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, Shared.bump, .{&shared});
    for (&threads) |*t| t.join();
    try std.testing.expectEqual(@as(u64, 400_000), shared.value);
}

test "thread runtime round-trips jobs in order" {
    var ctx = TestCtx{};
    var runtime = ThreadRuntime{};
    try runtime.start();

    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        runtime.runCustomJob(TestCtx.job, &ctx);
        runtime.waitForSearchFinished();
    }

    runtime.deinit();
    try std.testing.expectEqual(@as(u32, 1000), ctx.counter.load(.monotonic));
}

test "thread runtime exits cleanly when idle" {
    var runtime = ThreadRuntime{};
    try runtime.start();
    // No jobs submitted; deinit must wake the parked thread and join it.
    runtime.deinit();
    try std.testing.expect(runtime.handle == null);
}

test "thread pool fans jobs across all threads" {
    var pool = ThreadPool.init(std.testing.allocator);
    defer pool.clear();
    try pool.set(4);
    try std.testing.expectEqual(@as(usize, 4), pool.numThreads());

    var ctx = TestCtx{};
    var thread_id: usize = 0;
    while (thread_id < pool.numThreads()) : (thread_id += 1) {
        var rep: usize = 0;
        while (rep < 250) : (rep += 1) {
            pool.runOnThread(thread_id, TestCtx.job, &ctx);
            pool.waitOnThread(thread_id);
        }
    }
    try std.testing.expectEqual(@as(u32, 1000), ctx.counter.load(.monotonic));
}

test "thread pool stop flag round-trips" {
    var pool = ThreadPool.init(std.testing.allocator);
    defer pool.clear();
    try pool.set(2);
    try std.testing.expect(!pool.stopped());
    pool.setStop(true);
    try std.testing.expect(pool.stopped());
    pool.setStop(false);
    try std.testing.expect(!pool.stopped());
}

test "thread pool set resizes and re-spawns" {
    var pool = ThreadPool.init(std.testing.allocator);
    defer pool.clear();
    try pool.set(1);
    try std.testing.expectEqual(@as(usize, 1), pool.numThreads());
    try pool.set(8);
    try std.testing.expectEqual(@as(usize, 8), pool.numThreads());
    try pool.set(0);
    try std.testing.expectEqual(@as(usize, 0), pool.numThreads());
}
