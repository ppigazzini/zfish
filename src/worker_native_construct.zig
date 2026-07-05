// Native Search::Worker field constructor.
//
// The Worker's 13.2 MB storage is already Zig-allocated (aligned_large_pages),
// its POD fill is Zig (Worker::clear -> zfish_search_clear_*), and
// worker_construct.zig already locks the field-init model of a freshly built
// Worker. The one thing still done by the frozen C++ Worker constructor is the
// placement-new that writes the non-history members: the five SharedState
// reference slots, the NUMA scalars, the manager pointer, and the one live
// AccumulatorStack slot. This module reproduces exactly that write set in Zig,
// so the atomic Engine cut can construct a Worker without the C++ constructor.
//
// Only the constructor-set fields are written here; the histories, reductions,
// refresh cache, and shared history are filled afterwards by the existing native
// Worker::clear path. Offsets come from graph_layout.worker_off, the live-probed
// address map that worker_construct.zig verifies on every C++ Worker.

const std = @import("std");
const graph_layout = @import("graph_layout");
const position_port = @import("position");
const search_port = @import("search");
const nnue_acc = @import("nnue_accumulator");
const network_port = @import("network");

const off = graph_layout.worker_off;

// The native FT pointer (network.zig-owned inference storage) lets the full native
// constructor fill the histories exactly as Worker::clear.

// reductions is the 1024-byte (256 x int) array between `reductions` and `manager`.
const reductions_count: usize = (off.manager - off.reductions) / @sizeOf(c_int);

// The NUMA scalars follow threadIdx in constructor order (threadIdx,
// numaThreadIdx, numaTotal, numaAccessToken), each a size_t-wide slot, filling
// the 32-byte gap to `reductions`.
const numa_thread_idx_off = off.thread_idx + 8;
const numa_total_off = off.thread_idx + 16;
const numa_access_token_off = off.thread_idx + 24;

// AccumulatorStack::size (size_t == 1 at construction) sits 64 bytes before the
// refresh table -- its last real member plus trailing alignment padding. Matches
// accumulator_stack_size_off in worker_construct.zig.
const accumulator_stack_size_off = off.refresh_table - 64;

fn writePtr(base: [*]u8, offset: usize, value: usize) void {
    const p: *usize = @ptrCast(@alignCast(base + offset));
    p.* = value;
}

// Inputs the C++ Worker constructor receives, unpacked from the SharedState plus
// the thread parameters. Pointers are the exact referents the reference members
// must bind to (the SharedState members), matching the C++ initializer list.
pub const WorkerCtorInputs = struct {
    shared_history: usize, // &sharedState.sharedHistories.at(numa)
    options: usize, // &sharedState.options
    threads: usize, // &sharedState.threads
    tt: usize, // &sharedState.tt
    network: usize, // &sharedState.network
    manager: usize, // released ISearchManager / native SearchManager
    thread_idx: usize,
    numa_thread_idx: usize,
    numa_total: usize,
    numa_access_token: usize,
};

// Write the constructor-set members into a (zeroed) Worker buffer. The caller
// owns the buffer (aligned_large_pages, worker_size bytes) and must zero it and
// run the native Worker::clear afterwards, exactly as the C++ path does.
pub fn writeConstructorFields(worker: [*]u8, in: WorkerCtorInputs) void {
    // Five SharedState reference members.
    writePtr(worker, position_port.worker_shared_history_off, in.shared_history);
    writePtr(worker, off.options, in.options);
    writePtr(worker, off.threads, in.threads);
    writePtr(worker, off.tt, in.tt);
    writePtr(worker, off.network, in.network);

    // manager unique_ptr<ISearchManager>: the moved-in pointer.
    writePtr(worker, off.manager, in.manager);

    // NUMA identity scalars.
    writePtr(worker, off.thread_idx, in.thread_idx);
    writePtr(worker, numa_thread_idx_off, in.numa_thread_idx);
    writePtr(worker, numa_total_off, in.numa_total);
    writePtr(worker, numa_access_token_off, in.numa_access_token);

    // AccumulatorStack starts with one live slot.
    writePtr(worker, accumulator_stack_size_off, 1);
}

// Full native Worker construction into a caller-owned, zeroed buffer: write the
// constructor field set, then run the native Worker::clear pieces (histories,
// shared history, reductions, refresh cache) exactly as the C++ ctor's clear()
// call. `shared_obj` is the SharedHistories the thread clears its range of, and
// `biases` is the network feature-transformer bias array.
fn constructWorkerInto(
    buf: [*]u8,
    in: WorkerCtorInputs,
    shared_obj: *anyopaque,
    biases: [*]const i16,
) void {
    writeConstructorFields(buf, in);
    position_port.clearWorkerHistories(buf);
    position_port.clearSharedHistory(shared_obj, in.numa_thread_idx, in.numa_total);
    search_port.fillReductions(@ptrCast(@alignCast(buf + off.reductions)), reductions_count);
    nnue_acc.clearRefreshCache(@ptrCast(buf + off.refresh_table), biases);
}

// Production entry: construct a complete native Worker into `buf` (a large-page
// block of at least worker_size bytes). Zeroes the block, writes the constructor
// field set, and runs the native Worker::clear pieces -- the full replacement for
// the C++ Worker placement-new that the engine-graph cut calls instead of
// make_unique_large_page<Worker>. `manager` is the moved ISearchManager pointer;
// the feature-transformer biases are sourced from the native network.
pub fn zfish_worker_construct_full(
    buf: ?*anyopaque,
    shared_history: usize,
    options: usize,
    threads: usize,
    tt: usize,
    network: usize,
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
        .options = options,
        .threads = threads,
        .tt = tt,
        .network = network,
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

    const in = WorkerCtorInputs{
        .shared_history = 0x1111,
        .options = 0x2222,
        .threads = 0x3333,
        .tt = 0x4444,
        .network = 0x5555,
        .manager = 0x6666,
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

    try testing.expectEqual(@as(usize, 0x1111), readPtr(buf.ptr, position_port.worker_shared_history_off));
    try testing.expectEqual(@as(usize, 0x2222), readPtr(buf.ptr, off.options));
    try testing.expectEqual(@as(usize, 0x3333), readPtr(buf.ptr, off.threads));
    try testing.expectEqual(@as(usize, 0x4444), readPtr(buf.ptr, off.tt));
    try testing.expectEqual(@as(usize, 0x5555), readPtr(buf.ptr, off.network));
    try testing.expectEqual(@as(usize, 0x6666), readPtr(buf.ptr, off.manager));
    try testing.expectEqual(@as(usize, 7), readPtr(buf.ptr, off.thread_idx));
    try testing.expectEqual(@as(usize, 8), readPtr(buf.ptr, numa_thread_idx_off));
    try testing.expectEqual(@as(usize, 9), readPtr(buf.ptr, numa_total_off));
    try testing.expectEqual(@as(usize, 10), readPtr(buf.ptr, numa_access_token_off));
    try testing.expectEqual(@as(usize, 1), readPtr(buf.ptr, accumulator_stack_size_off));
}
