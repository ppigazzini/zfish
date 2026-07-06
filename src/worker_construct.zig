// Construction verifier for Search::Worker.
//
// The Worker's 13.2 MB storage is already Zig-owned: make_unique_large_page
// allocates it through aligned_large_pages_alloc, which is exported from Zig
// (memory_port.alignedLargePagesAlloc), and frees it the same way. The POD fill
// (histories, shared history, reductions, refresh cache) is Zig too, via
// Worker::clear. The construction itself is native (worker_native_construct.zig):
// the placement-new that binds the five reference members and moves the
// unique_ptr<ISearchManager> (a vtable object), plus the matching destructor.
//
// This verifier proves the Zig model of a freshly constructed Worker is exact:
// the reference slots point at the expected SharedState members, the manager
// slot is populated, the rootMoves vector is empty (24 zero bytes), and the
// AccumulatorStack reports size == 1. It runs on every Worker right after
// construction and panics on any mismatch, so the Zig understanding of Worker
// construction is locked against upstream drift.

const std = @import("std");
const graph_layout = @import("graph_layout");

const off = graph_layout.worker_off;

// AccumulatorStack::size (a size_t initialised to 1) is its last real member,
// followed by 56 bytes of trailing padding to the struct's 64-byte alignment,
// so it sits 64 bytes before refresh_table.
const accumulator_stack_size_off = off.accumulator_stack_size_field;

fn readPtr(base: [*]const u8, offset: usize) usize {
    const p: *const usize = @ptrCast(@alignCast(base + offset));
    return p.*;
}

fn fail(comptime msg: []const u8) noreturn {
    std.debug.print("worker construction: {s}\n", .{msg});
    @panic("Worker construction model mismatch");
}
