// Worker field constructor.
//
// Note that the Worker's 13.2 MB storage is already Zig-allocated (aligned_large_pages),
// its POD fill is Zig (the worker-clear reset). Write the non-history members the
// constructor owns: the five
// SharedState reference slots, the NUMA scalars, the manager pointer, and the one
// live AccumulatorStack slot. Write exactly that set in Zig, so the
// Engine graph constructs a Worker directly in Zig.
//
// Write only the constructor-set fields here; fill the histories, reductions,
// refresh cache, and shared history afterwards through the existing
// worker-clear reset path. Route writes through typed worker_layout.WorkerLayout fields,
// keeping worker_off only for the two sub-region slots (shared-history pointer,
// AccumulatorStack size).

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

// Treat reductions as the [256]i32 table in WorkerLayout (the layout no longer
// puts it immediately before `manager`, so take the fixed element count directly).
const reductions_count: usize = 256;

// Place the NUMA scalars after threadIdx in constructor order (threadIdx,
// numaThreadIdx, numaTotal, numaAccessToken), each a size_t-wide slot, filling
// the 32-byte gap to `reductions`.
const numa_thread_idx_off = off.numa_thread_idx;
const numa_total_off = off.numa_total;
const numa_access_token_off = off.numa_access_token;

// Locate AccumulatorStack::size (size_t == 1 at construction) 64 bytes before the
// refresh table -- its last real member plus trailing alignment padding.
const accumulator_stack_size_off = off.accumulator_stack_size_field;

fn writePtr(base: [*]u8, offset: usize, value: usize) void {
    const p: *usize = @ptrCast(@alignCast(base + offset));
    p.* = value;
}

// Collect the inputs the Worker constructor receives, unpacked from the SharedState
// plus the thread parameters. Point each pointer at the exact referent its reference
// member must bind to (the SharedState members).
pub const WorkerCtorInputs = struct {
    shared_history: usize, // &sharedState.sharedHistories.at(numa)
    threads: usize, // &sharedState.threads
    tt: usize, // &sharedState.tt
    manager: usize, // released ISearchManager / SearchManager
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
    wl.histories.shared_history = @ptrFromInt(in.shared_history);
    // Bind the live SharedState reference members (threads + tt) + the moved-in manager.
    // Drop options/network — vestigial pass-through (never read -- the search reads the
    // global OptionsModel / FT storage).
    wl.threads = @ptrFromInt(in.threads);
    wl.tt = @ptrFromInt(in.tt);
    wl.manager = @ptrFromInt(in.manager);
    // Write the NUMA identity scalars.
    wl.thread_idx = in.thread_idx;
    wl.numa_thread_idx = in.numa_thread_idx;
    wl.numa_total = in.numa_total;
    wl.numa_access_token = in.numa_access_token;

    // Start the AccumulatorStack with one live slot (size_t at the size field, inside
    // the accumulator_stack region so still addressed by offset).
    writePtr(worker, accumulator_stack_size_off, 1);
}

// Construct a full Worker into a caller-owned, zeroed buffer: write the
// constructor field set, then run the worker-clear reset pieces (histories,
// shared history, reductions, refresh cache). Pass `shared_obj` as the SharedHistories
// the thread clears its range of, and
// `biases` as the network feature-transformer bias array.
fn constructWorkerInto(
    buf: [*]u8,
    in: WorkerCtorInputs,
    shared_obj: *search_driver.SharedHistories,
    biases: [*]const i16,
) void {
    const wl = worker_layout.WorkerLayout.fromPtr(buf);
    writeConstructorFields(buf, in);
    search_driver.clearWorkerHistories(wl);
    search_driver.clearSharedHistory(shared_obj, in.numa_thread_idx, in.numa_total);
    search_port.fillReductions(&wl.reductions, reductions_count);
    nnue_acc.clearRefreshCache(@ptrCast(&wl.refresh_table), biases);
}

// Enter production: construct a complete Worker into `buf` (a large-page
// block of at least worker_size bytes). Zero the block, write the constructor
// field set, and run the worker-clear reset pieces, called by the engine graph.
// Pass `manager` as the moved ISearchManager pointer; source the feature-transformer
// biases from the network.
pub fn constructFull(
    buf: ?*anyopaque,
    shared_history: usize,
    threads: usize,
    tt: usize,
    manager: usize,
    thread_idx: usize,
    numa_thread_idx: usize,
    numa_total: usize,
    numa_access_token: usize,
) void {
    const base: [*]u8 = @ptrCast(buf orelse return);
    @memset(base[0..worker_layout.worker_size], 0);
    const biases: [*]const i16 = @ptrCast(@alignCast(network_port.ftPtr() orelse return));
    constructWorkerInto(base, .{
        .shared_history = shared_history,
        .threads = threads,
        .tt = tt,
        .manager = manager,
        .thread_idx = thread_idx,
        .numa_thread_idx = numa_thread_idx,
        .numa_total = numa_total,
        .numa_access_token = numa_access_token,
    }, @ptrFromInt(shared_history), biases);
}

// ---- tests ------------------------------------------------------------------

const testing = std.testing;

test "writeConstructorFields lands every member at its worker_off slot" {
    const buf = try testing.allocator.alignedAlloc(u8, .@"64", worker_layout.worker_size);
    defer testing.allocator.free(buf);
    @memset(buf, 0);

    // Align sentinels to each destination pointer's @alignOf: they are stored
    // via @ptrFromInt into typed pointer fields (*ThreadPool, *SearchManager, ...) and
    // ReleaseSafe validates the integer's alignment. Choose page-aligned values to satisfy any
    // field alignment while staying distinct and recognizable in the byte image.
    const in = WorkerCtorInputs{
        .shared_history = 0x1000,
        .threads = 0x3000,
        .tt = 0x4000,
        .manager = 0x6000,
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

    try testing.expectEqual(@as(usize, 0x1000), readPtr(buf.ptr, off.histories + worker_histories.worker_shared_history_off));
    try testing.expectEqual(@as(usize, 0x3000), readPtr(buf.ptr, off.threads));
    try testing.expectEqual(@as(usize, 0x4000), readPtr(buf.ptr, off.tt));
    try testing.expectEqual(@as(usize, 0x6000), readPtr(buf.ptr, off.manager));
    try testing.expectEqual(@as(usize, 7), readPtr(buf.ptr, off.thread_idx));
    try testing.expectEqual(@as(usize, 8), readPtr(buf.ptr, numa_thread_idx_off));
    try testing.expectEqual(@as(usize, 9), readPtr(buf.ptr, numa_total_off));
    try testing.expectEqual(@as(usize, 10), readPtr(buf.ptr, numa_access_token_off));
    try testing.expectEqual(@as(usize, 1), readPtr(buf.ptr, accumulator_stack_size_off));
}
