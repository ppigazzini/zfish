// Construction verifier for Search::Worker.
//
// The Worker's 13.2 MB storage is already Zig-owned: make_unique_large_page
// allocates it through aligned_large_pages_alloc, which is exported from Zig
// (memory_port.alignedLargePagesAlloc), and frees it the same way. The POD fill
// (histories, shared history, reductions, refresh cache) is Zig too, via
// Worker::clear -> zfish_search_clear_*. The only work left in C++ is the part
// frozen src/ forces to stay there: the placement-new that binds the five C++
// reference members and moves the unique_ptr<ISearchManager> (a vtable object),
// plus the matching destructor.
//
// This verifier proves the Zig model of a freshly constructed Worker is exact:
// the reference slots point at the expected SharedState members, the manager
// slot is populated, the rootMoves vector is empty (24 zero bytes), and the
// AccumulatorStack reports size == 1. It runs on every Worker right after
// construction (default-build seam) and panics on any mismatch, so the Zig
// understanding of Worker construction is locked against upstream drift.

const std = @import("std");
const graph_layout = @import("graph_layout.zig");

const off = graph_layout.worker_off;

// AccumulatorStack::size (a size_t initialised to 1) is its last real member,
// followed by 56 bytes of trailing padding to the struct's 64-byte alignment,
// so it sits 64 bytes before refresh_table.
const accumulator_stack_size_off = off.refresh_table - 64;

fn readPtr(base: [*]const u8, offset: usize) usize {
    const p: *const usize = @ptrCast(@alignCast(base + offset));
    return p.*;
}

fn fail(comptime msg: []const u8) noreturn {
    std.debug.print("worker construction: {s}\n", .{msg});
    @panic("Worker construction model mismatch");
}

// Verify a freshly constructed Worker against the Zig model. The caller passes
// the referents the reference members must be bound to (the SharedState fields)
// and the expected thread index.
export fn zfish_verify_worker_construction(
    worker: ?*const anyopaque,
    thread_idx: usize,
    options_ref: ?*const anyopaque,
    threads_ref: ?*const anyopaque,
    tt_ref: ?*const anyopaque,
    network_ref: ?*const anyopaque,
) void {
    const base: [*]const u8 = @ptrCast(worker orelse return);

    // The five reference members must be bound, and four of them must point at
    // the exact SharedState referents the caller supplied.
    if (readPtr(base, off.shared_history) == 0) fail("sharedHistory reference is null");
    if (readPtr(base, off.options) != @intFromPtr(options_ref)) fail("options reference mis-bound");
    if (readPtr(base, off.threads) != @intFromPtr(threads_ref)) fail("threads reference mis-bound");
    if (readPtr(base, off.tt) != @intFromPtr(tt_ref)) fail("tt reference mis-bound");
    if (readPtr(base, off.network) != @intFromPtr(network_ref)) fail("network reference mis-bound");

    // The manager unique_ptr must own a minted ISearchManager.
    if (readPtr(base, off.manager) == 0) fail("manager unique_ptr is empty");

    // Scalar identity.
    if (readPtr(base, off.thread_idx) != thread_idx) fail("threadIdx mismatch");

    // rootMoves is a freshly default-constructed std::vector: {begin, end, cap}
    // all null -> 24 zero bytes.
    inline for (0..3) |i| {
        if (readPtr(base, off.root_moves + i * @sizeOf(usize)) != 0)
            fail("rootMoves is not an empty vector at construction");
    }

    // The AccumulatorStack starts with one live slot.
    if (readPtr(base, accumulator_stack_size_off) != 1) fail("AccumulatorStack size is not 1");
}
