//! Injected large-block allocator for the engine's big, long-lived arenas
//! (transposition table, shared-history stats, NNUE weight storage).
//!
//! Allocating huge-page-aligned memory is a platform service (posix_memalign +
//! madvise, or the Windows aligned CRT), so the engine must not call it directly or
//! it stops being a standalone library. The platform registers its allocator at
//! startup; the default is a std page-backed allocator so a headless engine build
//! (unit tests, fuzzing) can still allocate with no platform attached.
//!
//! Contract (matches the platform allocator): `alloc(size)` returns a zeroed block
//! whose payload is at least 64-byte aligned, or null on failure; `free(ptr)` takes
//! only the pointer. The default records the block length in a header word placed
//! before the payload so free() needs no size. In the shipped engine the platform
//! injects its 2 MiB huge-page allocator, so production allocation is the platform's,
//! including the zero-fill the worker construction relies on.

const std = @import("std");

// One 64-byte unit reserved before the payload: keeps the payload 64-aligned (page
// memory is already 4096-aligned) and holds the block length for free().
const payload_offset = 64;

fn defaultAlloc(size: usize) ?*anyopaque {
    if (size == 0) return null;
    const total = payload_offset + size;
    const raw = std.heap.page_allocator.alloc(u8, total) catch return null;
    @memset(raw, 0);
    std.mem.writeInt(usize, raw[0..@sizeOf(usize)], total, .little);
    return @ptrCast(raw.ptr + payload_offset);
}

fn defaultFree(ptr: ?*anyopaque) void {
    const p: [*]u8 = @ptrCast(ptr orelse return);
    const raw = p - payload_offset;
    const total = std.mem.readInt(usize, raw[0..@sizeOf(usize)], .little);
    std.heap.page_allocator.free(raw[0..total]);
}

/// A zeroed, >=64-aligned block of `size` bytes, or null. Registered by the platform;
/// the default is the std page-backed allocator above.
pub var alloc: *const fn (size: usize) ?*anyopaque = &defaultAlloc;

/// Free a block from `alloc`. Pointer only; the size is the allocator's business.
pub var free: *const fn (ptr: ?*anyopaque) void = &defaultFree;

test {
    // The default round-trips a zeroed, aligned block headless.
    const p = alloc(4096) orelse return error.OutOfMemory;
    const bytes: [*]u8 = @ptrCast(p);
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(p) % 64);
    try std.testing.expectEqual(@as(u8, 0), bytes[0]);
    try std.testing.expectEqual(@as(u8, 0), bytes[4095]);
    free(p);
}
