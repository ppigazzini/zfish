// Worker field constructor.
//
// Note that the Worker's ~4.5 MB storage is already Zig-allocated (aligned_large_pages),
// its POD fill is Zig (the worker-clear reset). Write the non-history members the
// constructor owns: the five
// SharedState reference slots, the NUMA scalars, the manager pointer, and the one
// live AccumulatorStack slot. Write exactly that set in Zig, so the
// Engine graph constructs a Worker directly in Zig.
//
// Write only the constructor-set fields here; fill the histories, reductions,
// refresh cache, and shared history afterwards through the existing
// worker-clear reset path. Route every write through a typed
// worker_layout.WorkerLayout field or the owning module's accessor, so no member is
// addressed by an offset from the block base.

const std = @import("std");
const worker_layout = @import("worker_layout");
const position_port = @import("position");
const search_driver = @import("search_driver");
const worker_histories = @import("worker_histories");
const search_port = @import("search");
const nnue_acc = @import("nnue_accumulator");
const network_port = @import("network");

const off = worker_layout.worker_off;

// Use the FT pointer (network.zig-owned inference storage) to let the full
// constructor fill the histories exactly as the worker-clear reset.

// Treat reductions as the [256]i32 table in WorkerLayout; take the fixed element
// count directly rather than deriving it from the neighbouring field offsets.
const reductions_count: usize = 256;

// Collect the inputs the Worker constructor receives, unpacked from the SharedState
// plus the thread parameters. Point each reference member at the exact referent it
// must bind to (the SharedState members), as a typed pointer: the referent types are
// all reachable from here, so the seam needs no integer round-trip.
pub const WorkerCtorInputs = struct {
    shared_history: *search_driver.SharedHistories, // sharedState.sharedHistories.at(numa)
    threads: *worker_layout.ThreadPool, // sharedState.threads
    tt: *worker_layout.TranspositionTable, // sharedState.tt
    manager: *worker_layout.SearchManager, // the moved-in ISearchManager
    thread_idx: usize,
    numa_thread_idx: usize,
    numa_total: usize,
    numa_access_token: usize,
};

// Write the constructor-set members into a (zeroed) Worker buffer. The caller
// owns the buffer (aligned_large_pages, worker_size bytes) and must zero it and
// run the worker-clear reset afterwards.
pub fn writeConstructorFields(worker: [*]u8, in: WorkerCtorInputs) void {
    const wl = worker_layout.WorkerLayout.fromPtr(worker);

    // Bind the sharedHistories reference: now a typed field of the embedded WorkerHistories.
    wl.histories.shared_history = in.shared_history;
    // Bind the live SharedState reference members (threads + tt) + the moved-in manager.
    // Drop options/network — vestigial pass-through (never read -- the search reads the
    // global OptionsModel / FT storage).
    wl.threads = in.threads;
    wl.tt = in.tt;
    wl.manager = in.manager;
    // Write the NUMA identity scalars.
    wl.thread_idx = in.thread_idx;
    wl.numa_thread_idx = in.numa_thread_idx;
    wl.numa_total = in.numa_total;
    wl.numa_access_token = in.numa_access_token;

    // Initialize the two slice headers that are READ before any per-search write --
    // the fields the historic "zero the large-page block" fix (2f30856f) pinned
    // implicitly. Make the dependency explicit here so it does not hide in a memset:
    //   * root_moves: workerSetRootMoves and workerDestroy free the old buffer
    //     whenever .len != 0, and ssContext reads .len for root_moves_empty -- a
    //     garbage header is a free() of a wild pointer on the first `go`.
    //   * limits.searchmoves: workerSetLimits deliberately copies only the POD
    //     limits fields and never writes this slice, so the worker's own copy must
    //     start empty or searchmoveCount reads a garbage length forever.
    wl.root_moves = &.{};
    wl.limits.searchmoves = &.{};

    // Start the AccumulatorStack with one live slot. Write it through the arena's own
    // accessor, so the size field's placement stays nnue_acc_layout's to choose rather
    // than a second offset derived here.
    nnue_acc.setStackSize(&wl.accumulator_stack, 1);
}

// Construct a full Worker into a caller-owned, zeroed buffer: write the
// constructor field set, then run the worker-clear reset pieces (histories,
// shared history, reductions, refresh cache). The SharedHistories the thread clears
// its range of is `in.shared_history` -- the same referent the reference member binds
// to. Pass `biases` as the network feature-transformer bias array.
fn constructWorkerInto(buf: [*]u8, in: WorkerCtorInputs, biases: [*]const i16) void {
    const wl = worker_layout.WorkerLayout.fromPtr(buf);
    writeConstructorFields(buf, in);
    search_driver.clearWorkerHistories(wl);
    search_driver.clearSharedHistory(in.shared_history, .{ .index = in.numa_thread_idx, .total = in.numa_total });
    search_port.fillReductions(&wl.reductions, reductions_count);
    nnue_acc.clearRefreshCache(@ptrCast(&wl.refresh_table), biases);
}

// Enter production: construct a complete Worker into `buf` (a large-page
// block of at least worker_size bytes). Zero the block, write the constructor
// field set, and run the worker-clear reset pieces, called by the engine graph.
// Source the feature-transformer biases from the network.
pub fn constructFull(buf: ?*anyopaque, in: WorkerCtorInputs) void {
    const base: [*]u8 = @ptrCast(buf orelse return);
    @memset(base[0..worker_layout.worker_size], 0);
    const biases: [*]const i16 = @ptrCast(@alignCast(network_port.ftPtr() orelse return));
    constructWorkerInto(base, in, biases);
}

// ---- tests ------------------------------------------------------------------

const testing = std.testing;

test "writeConstructorFields lands every member at its worker_off slot" {
    const buf = try testing.allocator.alignedAlloc(u8, .@"64", worker_layout.worker_size);
    defer testing.allocator.free(buf);
    // Poison the block instead of zeroing it: the constructor must pin every
    // read-before-write field itself (root_moves, limits.searchmoves), not
    // inherit a zero from the caller's fill. A 0xAA image makes an implicit
    // zero-dependency fail here instead of as a wild free() on the first `go`.
    @memset(buf, 0xAA);

    // Point each reference member at a real, distinct object of its own type, so the
    // recorded slot can be compared against the referent's actual address. Only the
    // addresses are read back here -- nothing dereferences them.
    var sentinel_shared: search_driver.SharedHistories = undefined;
    var sentinel_threads: worker_layout.ThreadPool = .{};
    var sentinel_tt: worker_layout.TranspositionTable = .{};
    var sentinel_manager: worker_layout.SearchManager = .{};
    const in = WorkerCtorInputs{
        .shared_history = &sentinel_shared,
        .threads = &sentinel_threads,
        .tt = &sentinel_tt,
        .manager = &sentinel_manager,
        .thread_idx = 7,
        .numa_thread_idx = 8,
        .numa_total = 9,
        .numa_access_token = 10,
    };
    writeConstructorFields(buf.ptr, in);

    const readPtr = struct {
        fn read(b: [*]const u8, o: usize) usize {
            const p: *const usize = @ptrCast(@alignCast(b + o));
            return p.*;
        }
    }.read;

    try testing.expectEqual(@intFromPtr(&sentinel_shared), readPtr(buf.ptr, off.histories + worker_histories.worker_shared_history_off));
    try testing.expectEqual(@intFromPtr(&sentinel_threads), readPtr(buf.ptr, off.threads));
    try testing.expectEqual(@intFromPtr(&sentinel_tt), readPtr(buf.ptr, off.tt));
    try testing.expectEqual(@intFromPtr(&sentinel_manager), readPtr(buf.ptr, off.manager));
    try testing.expectEqual(@as(usize, 7), readPtr(buf.ptr, off.thread_idx));
    try testing.expectEqual(@as(usize, 8), readPtr(buf.ptr, off.numa_thread_idx));
    try testing.expectEqual(@as(usize, 9), readPtr(buf.ptr, off.numa_total));
    try testing.expectEqual(@as(usize, 10), readPtr(buf.ptr, off.numa_access_token));
    try testing.expectEqual(@as(usize, 1), readPtr(buf.ptr, off.accumulator_stack_size_field));

    // Pin the read-before-write slice headers to empty: workerSetRootMoves /
    // workerDestroy free root_moves whenever .len != 0, and workerSetLimits never
    // writes searchmoves, so both must leave the constructor empty.
    const wl = worker_layout.WorkerLayout.fromPtr(buf.ptr);
    try testing.expectEqual(@as(usize, 0), wl.root_moves.len);
    try testing.expectEqual(@as(usize, 0), wl.limits.searchmoves.len);
}
