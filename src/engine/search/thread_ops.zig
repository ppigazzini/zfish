//! Inject the thread-pool operations for the parallel (Lazy-SMP) search.
//!
//! Treat starting sibling search threads, waiting for them, and picking the vote-winning
//! thread as threading-runtime operations -- a platform service -- so reach them through
//! function pointers the platform registers at startup rather
//! than importing a platform module. Default to the single-threaded case: no
//! siblings to start or wait for, and the best thread is the main one. Run a headless,
//! single-threaded engine build with no thread pool attached (a valid engine
//! build); the shipped engine injects the real pool ops, so parallel search is the
//! platform's.
//!
//! hook-class: service — a leaf answering a query it must not import the answer for.
//!
//! Treat the 4 search-coordination hooks (startSiblings / waitSiblings / waitThread /
//! bestThreadWorker) as SEARCH-AFFECTING when unregistered: unregistered they answer
//! rather than abort, so the engine searches single-threaded and still reports a legal
//! move. runThread is not search-affecting: its inline default executes the job
//! serially, byte-identically.
//! Tolerate this only because both roots are accounted for, which the hook-lint REGISTERED
//! rule keeps true:
//!   * shipped exe -- main.zig:68 registers all 4 before the engine is reachable
//!     (main.zig:79), so no shipped path can read a default.
//!   * headless roots -- genuinely single-threaded, so "no siblings" and "the main
//!     worker is the best worker" are the correct answers, not degraded ones.

const std = @import("std");
const worker_layout = @import("worker_layout");

const ThreadPool = worker_layout.ThreadPool;
const WorkerLayout = worker_layout.WorkerLayout;

fn noopPool(_: *ThreadPool) void {}
fn noopWaitThread(_: *ThreadPool, _: usize) void {}
// Return thread 0 (the main worker) as the single-threaded default best thread.
fn mainWorker(pool: *ThreadPool) *WorkerLayout {
    return pool.threadAt(0).worker.?;
}

/// Start the sibling search threads (index 1..).
/// failure: silent — starts nothing, i.e. a single-threaded search. Correct with no
/// pool attached: there are no siblings to start.
pub var startSiblings: *const fn (pool: *ThreadPool) void = &noopPool;
/// Wait for the sibling search threads to finish their current search.
/// failure: silent — waits for nothing, the correct dual of startSiblings' no-op.
pub var waitSiblings: *const fn (pool: *ThreadPool) void = &noopPool;
/// Wait for one thread's in-flight job (used while a TT resize clears the table).
/// failure: silent — no wait, correct when no pool means no in-flight job exists.
pub var waitThread: *const fn (pool: *ThreadPool, thread_id: usize) void = &noopWaitThread;
/// Run a job on one pool thread and return without waiting; pair each dispatch with
/// waitThread. Serve the parallel TT clear (upstream TranspositionTable::clear runs
/// one zeroing job per thread via run_on_thread).
/// failure: silent — runs the job inline on the calling thread: with no pool attached
/// there is no thread to dispatch to, and the serial clear is the correct
/// single-threaded execution of the same job.
pub var runThread: *const fn (pool: *ThreadPool, thread_id: usize, job: *const fn (?*anyopaque) void, ctx: ?*anyopaque) void = &inlineRunThread;

fn inlineRunThread(_: *ThreadPool, _: usize, job: *const fn (?*anyopaque) void, ctx: ?*anyopaque) void {
    job(ctx);
}
/// Return the worker of the vote-winning thread -- the thread whose move the search reports.
/// failure: silent — the main worker, which IS the vote winner when it is the only
/// searching thread. Correct single-threaded; wrong the moment siblings exist.
pub var bestThreadWorker: *const fn (pool: *ThreadPool) *WorkerLayout = &mainWorker;

test {
    std.testing.refAllDecls(@This());
}
