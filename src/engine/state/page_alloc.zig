//! Inject a large-block allocator for the engine's big, long-lived arenas
//! (transposition table, shared-history stats, NNUE weight storage).
//!
//! Treat huge-page-aligned allocation as a platform service (posix_memalign +
//! madvise, or the Windows aligned CRT), so the engine must not call it directly or
//! it stops being a standalone library. Let the platform register its allocator at
//! startup; default to a std page-backed allocator so a headless engine build
//! (unit tests, fuzzing) can still allocate with no platform attached.
//!
//! Honor this contract (matches the platform allocator): `alloc(size)` returns an
//! UNINITIALIZED block whose payload is at least 64-byte aligned, or null on failure;
//! `free(ptr)` takes only the pointer. Every consumer fully initializes what it reads
//! (the TT via clearState, the shared-history arenas via the worker stripe fills, the
//! NNUE arenas via the parse plus an explicit padding zero) -- do NOT add a consumer
//! that assumes a zeroed block. Have the default record the block length in a header
//! word placed before the payload so free() needs no size. Note that in the shipped
//! engine the platform injects its 2 MiB huge-page allocator, so production allocation
//! is the platform's.
//!
//! hook-class: service — a leaf answering a query it must not import the answer for.
//!
//! Treat these 2 as GENUINELY SAFE unregistered: the default is a REAL page-backed
//! allocator honouring the same contract (uninitialized, >=64-aligned, size-free
//! `free`), not a stub that returns a plausible-looking answer. Allocate correctly in a
//! headless build with no platform attached; lose only the huge-page optimisation.

const std = @import("std");
const builtin = @import("builtin");

// Reserve one 64-byte unit before the payload: keep the payload 64-aligned (page
// memory is already 4096-aligned) and hold the block length for free().
const payload_offset = 64;

fn defaultAlloc(size: usize) ?*anyopaque {
    if (size == 0) return null;
    const total = payload_offset + size;
    const raw = std.heap.page_allocator.alloc(u8, total) catch return null;
    // Poison in Debug, mirroring the platform allocator: fresh mmap pages happen to
    // be zero, which would let a read-before-write consumer pass every test while
    // being heap-dependent in production. The poison makes that bug fail here.
    if (builtin.mode == .Debug) @memset(raw[payload_offset..], 0xAA);
    std.mem.writeInt(usize, raw[0..@sizeOf(usize)], total, .little);
    return @ptrCast(raw.ptr + payload_offset);
}

fn defaultFree(ptr: ?*anyopaque) void {
    const p: [*]u8 = @ptrCast(ptr orelse return);
    const raw = p - payload_offset;
    const total = std.mem.readInt(usize, raw[0..@sizeOf(usize)], .little);
    std.heap.page_allocator.free(raw[0..total]);
}

/// Return an uninitialized, >=64-aligned block of `size` bytes, or null. Let the
/// platform register it; default to the std page-backed allocator above.
/// failure: silent — a real page-backed allocator meeting the full contract, not a
/// stub. Correct unregistered; the platform's huge pages are an optimisation, not a
/// requirement. Consumers own initialization -- see the module comment.
pub var alloc: *const fn (size: usize) ?*anyopaque = &defaultAlloc;

/// Free a block from `alloc`. Pointer only; the size is the allocator's business.
/// failure: silent — the matching real free for the default alloc. Correct only when
/// PAIRED with it, which holds: both are registered together or not at all.
pub var free: *const fn (ptr: ?*anyopaque) void = &defaultFree;

test {
    // Round-trip an aligned block headless through the default; the contents are
    // uninitialized (Debug poisons them), so only write-then-read is contractual.
    const p = alloc(4096) orelse return error.OutOfMemory;
    const bytes: [*]u8 = @ptrCast(p);
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(p) % 64);
    bytes[0] = 0x5A;
    bytes[4095] = 0xA5;
    try std.testing.expectEqual(@as(u8, 0x5A), bytes[0]);
    try std.testing.expectEqual(@as(u8, 0xA5), bytes[4095]);
    free(p);
}
