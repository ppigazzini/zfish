// Native Search::Worker field constructor.
//
// The Worker's 13.2 MB storage is already Zig-allocated (aligned_large_pages),
// its POD fill is Zig (Worker::clear). The non-history members written by the
// constructor are: the five
// SharedState reference slots, the NUMA scalars, the manager pointer, and the one
// live AccumulatorStack slot. This module writes exactly that set in Zig, so the
// Engine graph constructs a Worker without any C++ constructor.
//
// Only the constructor-set fields are written here; the histories, reductions,
// refresh cache, and shared history are filled afterwards by the existing native
// Worker::clear path. Writes go through typed graph_layout.WorkerLayout fields,
// with worker_off kept only for the two sub-region slots (shared-history pointer,
// AccumulatorStack size).

const std = @import("std");
const graph_layout = @import("graph_layout");
const position_port = @import("position");
const search_driver = @import("search_driver");
const worker_histories = @import("worker_histories");
const search_port = @import("search");
const nnue_acc = @import("nnue_accumulator");
const network_port = @import("network");

const off = graph_layout.worker_off;

// The native FT pointer (network.zig-owned inference storage) lets the full native
// constructor fill the histories exactly as Worker::clear.

// reductions is the [256]c_int table in WorkerLayout (the native layout no longer
// puts it immediately before `manager`, so take the fixed element count directly).
const reductions_count: usize = 256;

// The NUMA scalars follow threadIdx in constructor order (threadIdx,
// numaThreadIdx, numaTotal, numaAccessToken), each a size_t-wide slot, filling
// the 32-byte gap to `reductions`.
const numa_thread_idx_off = off.numa_thread_idx;
const numa_total_off = off.numa_total;
const numa_access_token_off = off.numa_access_token;

// AccumulatorStack::size (size_t == 1 at construction) sits 64 bytes before the
// refresh table -- its last real member plus trailing alignment padding.
const accumulator_stack_size_off = off.accumulator_stack_size_field;

fn writePtr(base: [*]u8, offset: usize, value: usize) void {
    const p: *usize = @ptrCast(@alignCast(base + offset));
    p.* = value;
}

// Inputs the native Worker constructor receives, unpacked from the SharedState plus
// the thread parameters. Pointers are the exact referents the reference members
// must bind to (the SharedState members), matching the C++ initializer list.
pub const WorkerCtorInputs = struct {
    shared_history: usize, // &sharedState.sharedHistories.at(numa)
    threads: usize, // &sharedState.threads
    tt: usize, // &sharedState.tt
    manager: usize, // released ISearchManager / native SearchManager
    thread_idx: usize,
    numa_thread_idx: usize,
    numa_total: usize,
    numa_access_token: usize,
};

// Write the constructor-set members into a (zeroed) Worker buffer. The caller
// owns the buffer (aligned_large_pages, worker_size bytes) and must zero it and
// run the native Worker::clear afterwards.
pub fn writeConstructorFields(worker: [*]u8, in: WorkerCtorInputs) void {
    const wl = graph_layout.WorkerLayout.fromPtr(worker);

    // sharedHistories reference: now a typed field of the embedded WorkerHistories.
    wl.histories.shared_history = @ptrFromInt(in.shared_history);
    // The live SharedState reference members (threads + tt) + the moved-in manager.
    // options/network were vestigial pass-through (never read -- the search reads the
    // global OptionsModel / native FT storage) and are removed (M20.1).
    wl.threads = @ptrFromInt(in.threads);
    wl.tt = @ptrFromInt(in.tt);
    wl.manager = @ptrFromInt(in.manager);
    // NUMA identity scalars.
    wl.thread_idx = in.thread_idx;
    wl.numa_thread_idx = in.numa_thread_idx;
    wl.numa_total = in.numa_total;
    wl.numa_access_token = in.numa_access_token;

    // AccumulatorStack starts with one live slot (size_t at the size field, inside
    // the accumulator_stack region so still addressed by offset).
    writePtr(worker, accumulator_stack_size_off, 1);
}

// Full native Worker construction into a caller-owned, zeroed buffer: write the
// constructor field set, then run the native Worker::clear pieces (histories,
// shared history, reductions, refresh cache). `shared_obj` is the SharedHistories
// the thread clears its range of, and
// `biases` is the network feature-transformer bias array.
fn constructWorkerInto(
    buf: [*]u8,
    in: WorkerCtorInputs,
    shared_obj: *search_driver.SharedHistories,
    biases: [*]const i16,
) void {
    const wl = graph_layout.WorkerLayout.fromPtr(buf);
    writeConstructorFields(buf, in);
    search_driver.clearWorkerHistories(wl);
    search_driver.clearSharedHistory(shared_obj, in.numa_thread_idx, in.numa_total);
    search_port.fillReductions(&wl.reductions, reductions_count);
    nnue_acc.clearRefreshCache(@ptrCast(&wl.refresh_table), biases);
}

// Production entry: construct a complete native Worker into `buf` (a large-page
// block of at least worker_size bytes). Zeroes the block, writes the constructor
// field set, and runs the native Worker::clear pieces -- the full native
// replacement for the C++ Worker placement-new, called by the engine graph.
// `manager` is the moved ISearchManager pointer; the feature-transformer biases
// are sourced from the native network.
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
    @memset(base[0..graph_layout.worker_size], 0);
    const biases: [*]const i16 = @ptrCast(@alignCast(network_port.nativeFtPtr() orelse return));
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
    const buf = try testing.allocator.alignedAlloc(u8, .@"64", graph_layout.worker_size);
    defer testing.allocator.free(buf);
    @memset(buf, 0);

    // Sentinels must be aligned to each destination pointer's @alignOf: they are stored
    // via @ptrFromInt into typed pointer fields (*ThreadPool, *SearchManager, ...) and
    // ReleaseSafe validates the integer's alignment. Page-aligned values satisfy any
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
