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
const graph_layout = @import("graph_layout.zig");
const memory_port = @import("memory.zig");

const off = graph_layout.worker_off;

// Native Worker::clear pieces (exported from main.zig) and the native FT pointer,
// so the full native constructor can fill the histories exactly as Worker::clear.
extern fn zfish_search_clear_worker_histories(worker: *anyopaque) void;
extern fn zfish_search_clear_shared_history(shared: *anyopaque, thread_idx: usize, numa_total: usize) void;
extern fn zfish_search_fill_reductions(reductions: [*]c_int, count: usize) void;
extern fn zfish_search_clear_refresh_cache(cache: *anyopaque, biases: [*]const i16) void;
extern fn zfish_native_ft_ptr() ?*const anyopaque;

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
pub const WorkerCtorInputs = extern struct {
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
    writePtr(worker, off.shared_history, in.shared_history);
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

// C-ABI entry for the bridge / native engine construction. Writes the
// constructor field set into `worker`, which the caller has zeroed.
export fn zfish_worker_write_constructor_fields(worker: ?*anyopaque, inputs: *const WorkerCtorInputs) void {
    const base: [*]u8 = @ptrCast(worker orelse return);
    writeConstructorFields(base, inputs.*);
}

fn readField(base: [*]const u8, offset: usize) usize {
    const p: *const usize = @ptrCast(@alignCast(base + offset));
    return p.*;
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
    zfish_search_clear_worker_histories(buf);
    zfish_search_clear_shared_history(shared_obj, in.numa_thread_idx, in.numa_total);
    zfish_search_fill_reductions(@ptrCast(@alignCast(buf + off.reductions)), reductions_count);
    zfish_search_clear_refresh_cache(@ptrCast(buf + off.refresh_table), biases);
}

// Production entry: construct a complete native Worker into `buf` (a large-page
// block of at least worker_size bytes). Zeroes the block, writes the constructor
// field set, and runs the native Worker::clear pieces -- the full replacement for
// the C++ Worker placement-new that the engine-graph cut calls instead of
// make_unique_large_page<Worker>. `manager` is the moved ISearchManager pointer;
// the feature-transformer biases are sourced from the native network.
export fn zfish_worker_construct_full(
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
    const biases: [*]const i16 = @ptrCast(@alignCast(zfish_native_ft_ptr() orelse return));
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

// Self-check: build a COMPLETE native Worker with the live worker's own inputs
// and assert all 13.8 MB are byte-identical to the live C++-constructed worker.
// This proves the native constructor (field write + native Worker::clear)
// reproduces the C++ ctor exactly, so the engine-graph cut can build a Worker
// without C++. Read-only on the live worker; large-page allocs are zero-filled so
// it is deterministic. The moved manager pointer and the opaque NUMA token are
// copied from the live worker (their identity is not what we are proving here).
export fn zfish_verify_worker_native_full(
    live_worker: ?*const anyopaque,
    shared_history: usize,
    options: usize,
    threads: usize,
    tt: usize,
    network: usize,
    thread_idx: usize,
    numa_thread_idx: usize,
    numa_total: usize,
) void {
    const live: [*]const u8 = @ptrCast(live_worker orelse return);
    const scratch_raw = memory_port.alignedLargePagesAlloc(graph_layout.worker_size) orelse return;
    defer memory_port.alignedLargePagesFree(scratch_raw);
    const scratch: [*]u8 = @ptrCast(scratch_raw);

    const biases: [*]const i16 = @ptrCast(@alignCast(zfish_native_ft_ptr() orelse return));
    constructWorkerInto(scratch, .{
        .shared_history = shared_history,
        .options = options,
        .threads = threads,
        .tt = tt,
        .network = network,
        .manager = readField(live, off.manager),
        .thread_idx = thread_idx,
        .numa_thread_idx = numa_thread_idx,
        .numa_total = numa_total,
        .numa_access_token = readField(live, numa_access_token_off),
    }, @ptrFromInt(shared_history), biases);

    var i: usize = 0;
    while (i < graph_layout.worker_size) : (i += 1) {
        if (scratch[i] != live[i]) {
            std.debug.print("native worker full ctor: byte {d} differs (native {d} vs live {d})\n", .{ i, scratch[i], live[i] });
            @panic("native Worker construction is not byte-identical to the C++ worker");
        }
    }
}

// Self-check: confirm the live C++-constructed worker carries, at each
// constructor-set offset, exactly the value the native constructor
// (writeConstructorFields) would write from the same inputs -- proving the two
// agree field-for-field. This reads only the live worker (no scratch alloc, so it
// does not perturb the heap), with writeConstructorFields itself covered by the
// unit test. manager and numaAccessToken are excluded: the former is a moved
// vtable pointer, the latter an opaque NUMA token. Panics on any drift.
export fn zfish_verify_worker_native_construct(
    live_worker: ?*const anyopaque,
    shared_history: usize,
    options: usize,
    threads: usize,
    tt: usize,
    network: usize,
    thread_idx: usize,
    numa_thread_idx: usize,
    numa_total: usize,
) void {
    const live: [*]const u8 = @ptrCast(live_worker orelse return);

    const Check = struct { o: usize, v: usize, name: []const u8 };
    const checks = [_]Check{
        .{ .o = off.shared_history, .v = shared_history, .name = "sharedHistory" },
        .{ .o = off.options, .v = options, .name = "options" },
        .{ .o = off.threads, .v = threads, .name = "threads" },
        .{ .o = off.tt, .v = tt, .name = "tt" },
        .{ .o = off.network, .v = network, .name = "network" },
        .{ .o = off.thread_idx, .v = thread_idx, .name = "threadIdx" },
        .{ .o = numa_thread_idx_off, .v = numa_thread_idx, .name = "numaThreadIdx" },
        .{ .o = numa_total_off, .v = numa_total, .name = "numaTotal" },
        .{ .o = accumulator_stack_size_off, .v = 1, .name = "AccumulatorStack.size" },
    };
    for (checks) |chk| {
        if (readField(live, chk.o) != chk.v) {
            std.debug.print("native worker ctor: live {s} mismatch\n", .{chk.name});
            @panic("native Worker constructor disagrees with the C++ placement-new");
        }
    }
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

    try testing.expectEqual(@as(usize, 0x1111), readPtr(buf.ptr, off.shared_history));
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
