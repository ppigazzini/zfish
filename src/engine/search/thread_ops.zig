//! Injected thread-pool operations for the parallel (Lazy-SMP) search.
//!
//! Starting sibling search threads, waiting for them, and picking the vote-winning
//! thread are threading-runtime operations -- a platform service -- so the search
//! reaches them through function pointers the platform registers at startup rather
//! than importing a platform module. The defaults are the single-threaded case: no
//! siblings to start or wait for, and the best thread is the main one. So a headless,
//! single-threaded engine build runs with no thread pool attached (a valid engine
//! build); the shipped engine injects the real pool ops, so parallel search is the
//! platform's.

const std = @import("std");
const worker_layout = @import("worker_layout");

const ThreadPool = worker_layout.ThreadPool;
const WorkerLayout = worker_layout.WorkerLayout;

fn noopPool(_: *ThreadPool) void {}
fn noopWaitThread(_: *ThreadPool, _: usize) void {}
// Single-threaded default: the best thread is thread 0 (the main worker).
fn mainWorker(pool: *ThreadPool) *WorkerLayout {
    return worker_layout.Thread.fromAddr(pool.threadAt(0)).worker.?;
}

/// Start the sibling search threads (index 1..).
pub var startSiblings: *const fn (pool: *ThreadPool) void = &noopPool;
/// Wait for the sibling search threads to finish their current search.
pub var waitSiblings: *const fn (pool: *ThreadPool) void = &noopPool;
/// Wait for one thread's in-flight job (used while a TT resize clears the table).
pub var waitThread: *const fn (pool: *ThreadPool, thread_id: usize) void = &noopWaitThread;
/// Worker of the vote-winning thread -- the thread whose move the search reports.
pub var bestThreadWorker: *const fn (pool: *ThreadPool) *WorkerLayout = &mainWorker;

test {
    std.testing.refAllDecls(@This());
}
