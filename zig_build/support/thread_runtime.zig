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
    _ = linux.futex_3arg(&ptr.raw, .{ .cmd = .WAIT, .private = true }, expect);
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
            while (!self.searching) self.cond.wait(&self.mutex);

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
