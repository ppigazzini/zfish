// Allocate aligned + large pages behind a cross-platform seam.
//
// Use no @cImport here: sys/mman.h does not exist on Windows and the macOS SDK headers
// can't be cross-compiled, so declare the C entry points directly via std.posix / std.c
// (POSIX) / an extern kernel decl (Windows). Handle the three owned OSes:
//   - Linux:       mmap + munmap, aligned to 2 MiB, with madvise(MADV_HUGEPAGE).
//   - macOS:       posix_memalign + free.
//   - Windows:     _aligned_malloc + _aligned_free (alignment-aware CRT allocator).
const std = @import("std");
const builtin = @import("builtin");
const thread_runtime = @import("thread_runtime");

// Bind the Windows CRT aligned allocator (ucrt/msvcrt via mingw). Unlike posix_memalign the
// alignment is the SECOND argument, and release the block with _aligned_free -- never plain
// free, which would corrupt the heap. Reference only on the Windows branch below.
extern "c" fn _aligned_malloc(size: usize, alignment: usize) ?*anyopaque;
extern "c" fn _aligned_free(ptr: ?*anyopaque) void;

/// Poison freshly handed-out blocks with 0xAA wherever safety checks are on, so a consumer that
/// reads before it writes fails on an obviously wrong value instead of on heap residue. Both safe
/// modes, not Debug alone -- see alignedLargePagesAlloc for why Debug alone is unreachable here.
pub const poison_uninitialized = builtin.mode == .Debug or builtin.mode == .ReleaseSafe;

pub fn stdAlignedAlloc(alignment: usize, size: usize) ?*anyopaque {
    if (builtin.os.tag == .windows) {
        return _aligned_malloc(size, alignment);
    }
    var mem: ?*anyopaque = null;
    if (std.c.posix_memalign(&mem, alignment, size) != 0) {
        return null;
    }
    return mem;
}

pub fn stdAlignedFree(ptr: ?*anyopaque) void {
    if (builtin.os.tag == .windows) {
        _aligned_free(ptr);
    } else {
        std.c.free(ptr);
    }
}

// Return whether the MADV_HUGEPAGE hint is worth issuing on this kernel. WSL kernels
// accept the advisory but never back the region with huge pages, so the hint only
// costs cycles there; detect WSL by the kernel release string and skip it. The probe
// is idempotent and cached after the first call.
var thp_hint_decided: bool = false;
var thp_hint_useful: bool = false;

fn thpHintUseful() bool {
    if (!thp_hint_decided) {
        const uts = std.posix.uname();
        const release = std.mem.sliceTo(&uts.release, 0);
        thp_hint_useful = std.mem.find(u8, release, "microsoft") == null and
            std.mem.find(u8, release, "Microsoft") == null;
        thp_hint_decided = true;
    }
    return thp_hint_useful;
}

/// Pin the alignment every large-page block is handed out at: one transparent huge page.
pub const large_page_alignment: usize = 2 * 1024 * 1024;

// Record base -> mapped length for every block mmapHugeAligned handed out, so the free path
// can munmap exactly what was mapped. Upstream carries the same registry (a std::map behind a
// mutex, memory.cpp) for the same reason: munmap needs a length and the caller returns only a
// pointer. Linux only -- nothing else takes the mmap route.
//
// The mutex is not decoration: TT resize, `setoption name Threads`, and the NNUE arenas all
// allocate and free through here, and a pool teardown frees one block per worker.
var large_map_mutex: thread_runtime.Mutex = .{};
var large_map: std.AutoHashMapUnmanaged(usize, usize) = .empty;

const use_mmap_large_pages = builtin.os.tag == .linux;

// Map `size` bytes aligned to 2 MiB, going STRAIGHT to the kernel rather than through the
// libc allocator (upstream 7ab49b9b). glibc serves a posix_memalign of this size from an
// arena, and an arena outlives the thread it was created for: a later thread bound to a
// different NUMA node reuses it and the engine silently runs on remote memory, which is what
// made `setoption name Threads` twice measurably slower than setting it once.
//
// There is no aligned mmap, so over-reserve by one alignment with PROT_NONE, MAP_FIXED the
// real mapping onto the aligned base inside that reservation, and give the prefix and suffix
// back. Fall back to a plain unaligned mmap if any step fails -- the alignment is what the
// huge-page hint wants, not what correctness needs.
fn mmapHugeAligned(size: usize) ?[]align(std.heap.page_size_min) u8 {
    const page_size = std.heap.pageSize();
    if (size >= large_page_alignment and page_size > 0) {
        const mapping_size = ((size + page_size - 1) / page_size) * page_size;
        const reservation_size = mapping_size + large_page_alignment;
        if (std.posix.mmap(
            null,
            reservation_size,
            .{ .READ = false, .WRITE = false },
            .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
            -1,
            0,
        )) |reservation| {
            const base = @intFromPtr(reservation.ptr);
            const aligned_base = (base + large_page_alignment - 1) & ~(large_page_alignment - 1);
            if (std.posix.mmap(
                @ptrFromInt(aligned_base),
                size,
                .{ .READ = true, .WRITE = true },
                .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .FIXED = true },
                -1,
                0,
            )) |mapped| {
                // Return the slack. MAP_FIXED replaced the middle of the reservation, so the
                // prefix and the suffix are still the PROT_NONE mapping and unmap separately.
                const prefix = aligned_base - base;
                const suffix = reservation_size - prefix - mapping_size;
                if (prefix != 0) std.posix.munmap(reservation[0..prefix]);
                if (suffix != 0) {
                    const tail: [*]align(std.heap.page_size_min) u8 = @ptrFromInt(aligned_base + mapping_size);
                    std.posix.munmap(tail[0..suffix]);
                }
                return mapped;
            } else |_| {
                std.posix.munmap(reservation);
            }
        } else |_| {}
    }

    return std.posix.mmap(
        null,
        size,
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
        -1,
        0,
    ) catch null;
}

// Take the mmap route and record the mapping. Refuse the allocation if the registry cannot
// record it rather than hand out a block free() could only leak.
fn largePagesMmapAlloc(rounded_size: usize) ?*anyopaque {
    const mapped = mmapHugeAligned(rounded_size) orelse return null;
    large_map_mutex.lock();
    defer large_map_mutex.unlock();
    large_map.put(std.heap.c_allocator, @intFromPtr(mapped.ptr), mapped.len) catch {
        std.posix.munmap(mapped);
        return null;
    };
    return @ptrCast(mapped.ptr);
}

// Unmap a block the registry knows, reporting whether it owned it.
fn largePagesMmapFree(ptr: *anyopaque) bool {
    large_map_mutex.lock();
    defer large_map_mutex.unlock();
    const entry = large_map.fetchRemove(@intFromPtr(ptr)) orelse return false;
    const base: [*]align(std.heap.page_size_min) u8 = @ptrCast(@alignCast(ptr));
    std.posix.munmap(base[0..entry.value]);
    return true;
}

pub fn alignedLargePagesAlloc(alloc_size: usize) ?*anyopaque {
    const alignment: usize = large_page_alignment;
    const rounded_size = if (alloc_size == 0)
        0
    else
        ((alloc_size + alignment - 1) / alignment) * alignment;

    const mem = if (use_mmap_large_pages and rounded_size != 0)
        largePagesMmapAlloc(rounded_size)
    else
        stdAlignedAlloc(alignment, rounded_size);
    if (mem) |ptr| {
        // Hand the block out UNINITIALIZED, as upstream's aligned_large_pages_alloc
        // does: every consumer fully initializes what it reads (the TT via clearState,
        // the shared-history arenas via the worker stripe fills, the NNUE arenas via
        // the parse plus an explicit padding zero, the Worker via constructFull) --
        // proven by a 0xAA poison audit of each path. Blanket-zeroing here re-wrote
        // ~100 MB the consumers immediately overwrite. In the SAFE modes poison the
        // block instead, so a regressed read-before-write consumer fails loudly
        // rather than riding whatever the heap happens to hold.
        //
        // ReleaseSafe is in that set deliberately, and it is the half that runs: a
        // Debug build of the exe SEGVs the Zig 0.16 compiler itself (deterministic,
        // `zig build -Doptimize=Debug` -> "process terminated with signal SEGV"), so a
        // Debug-only poison could never execute in the engine at all. ReleaseSafe is
        // what `zig build test -Doptimize=ReleaseSafe` and `zig build fuzz` build, so
        // gating on `builtin.mode` rather than on Debug alone is what makes the audit
        // reachable. The shipped ReleaseFast binary prunes the branch at comptime.
        if (poison_uninitialized) {
            @memset(@as([*]u8, @ptrCast(ptr))[0..rounded_size], 0xAA);
        }
        // Hint transparent huge pages (madvise MADV_HUGEPAGE), a Linux-only advisory,
        // skipped where the kernel never backs it (thpHintUseful). macOS/Windows have no
        // equivalent call; the allocation is already 2 MiB-aligned, so the OS is free to
        // back it with large pages on its own.
        if (builtin.os.tag == .linux and rounded_size != 0 and thpHintUseful()) {
            _ = std.c.madvise(@ptrCast(@alignCast(ptr)), rounded_size, std.c.MADV.HUGEPAGE);
        }
    }
    return mem;
}

pub fn alignedLargePagesFree(ptr: ?*anyopaque) void {
    if (use_mmap_large_pages) {
        // A zero-size request took the stdAlignedAlloc route, so a pointer the registry does
        // not know is a CRT block, not a bug.
        if (ptr) |p| if (largePagesMmapFree(p)) return;
    }
    stdAlignedFree(ptr);
}

pub fn hasLargePages() bool {
    return builtin.os.tag == .linux;
}

/// Count the large-page blocks the registry still holds -- zero once every allocation has been
/// freed. Restore the leak coverage the mmap route takes AWAY: `parity-valgrind` reports a
/// missed free as a definite leak only for blocks memcheck tracks, and it does not track an
/// mmap, so a dropped `alignedLargePagesFree` used to redden that gate and now would not.
/// This is what says so instead.
pub fn liveLargePageBlocks() usize {
    if (!use_mmap_large_pages) return 0;
    large_map_mutex.lock();
    defer large_map_mutex.unlock();
    return large_map.count();
}

test "large-page blocks are 2 MiB aligned, writable, and drain the registry" {
    if (!use_mmap_large_pages) return error.SkipZigTest;
    const before = liveLargePageBlocks();

    // Three sizes: one under the alignment (which takes the plain-mmap fallback), one exactly
    // on it, and one that rounds up to two pages.
    const sizes = [_]usize{ 4096, large_page_alignment, large_page_alignment + 1 };
    var blocks: [sizes.len]?*anyopaque = undefined;
    for (sizes, 0..) |size, i| {
        blocks[i] = alignedLargePagesAlloc(size) orelse return error.SkipZigTest;
        // Write the first and last byte of what the caller ASKED for: the fallback maps
        // exactly `size`, so a rounding error here faults rather than passing quietly.
        const bytes: [*]u8 = @ptrCast(blocks[i].?);
        bytes[0] = 0x5a;
        bytes[size - 1] = 0xa5;
        try std.testing.expectEqual(@as(u8, 0x5a), bytes[0]);
        try std.testing.expectEqual(@as(u8, 0xa5), bytes[size - 1]);
    }

    // Every block the registry took is aligned to a huge page; the sub-alignment request is
    // the one allowed to miss, since its fallback asks the kernel for no alignment at all.
    for (sizes, blocks) |size, block| {
        if (size >= large_page_alignment)
            try std.testing.expectEqual(@as(usize, 0), @intFromPtr(block.?) % large_page_alignment);
    }

    try std.testing.expectEqual(before + sizes.len, liveLargePageBlocks());
    for (blocks) |block| alignedLargePagesFree(block);
    try std.testing.expectEqual(before, liveLargePageBlocks());
}

test {
    @import("std").testing.refAllDecls(@This());
}
