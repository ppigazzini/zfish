// Allocate aligned + large pages behind a cross-platform seam.
//
// Use no @cImport here: sys/mman.h does not exist on Windows and the macOS SDK headers
// can't be cross-compiled, so declare the C entry points directly via std.c
// (POSIX) / an extern kernel decl (Windows). Handle the three owned OSes:
//   - Linux/macOS: posix_memalign + free, with madvise(MADV_HUGEPAGE) on Linux only.
//   - Windows:     _aligned_malloc + _aligned_free (alignment-aware CRT allocator).
const std = @import("std");
const builtin = @import("builtin");

// Bind the Windows CRT aligned allocator (ucrt/msvcrt via mingw). Unlike posix_memalign the
// alignment is the SECOND argument, and release the block with _aligned_free -- never plain
// free, which would corrupt the heap. Reference only on the Windows branch below.
extern "c" fn _aligned_malloc(size: usize, alignment: usize) ?*anyopaque;
extern "c" fn _aligned_free(ptr: ?*anyopaque) void;

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
        thp_hint_useful = std.mem.indexOf(u8, release, "microsoft") == null and
            std.mem.indexOf(u8, release, "Microsoft") == null;
        thp_hint_decided = true;
    }
    return thp_hint_useful;
}

pub fn alignedLargePagesAlloc(alloc_size: usize) ?*anyopaque {
    const alignment: usize = 2 * 1024 * 1024;
    const rounded_size = if (alloc_size == 0)
        0
    else
        ((alloc_size + alignment - 1) / alignment) * alignment;

    const mem = stdAlignedAlloc(alignment, rounded_size);
    if (mem) |ptr| {
        // Zero the block. posix_memalign / _aligned_malloc return uninitialized memory;
        // fresh OS pages happen to be zero, but reused blocks (thread resize, search
        // clear) carry stale data, and the Worker has a field read during multipv search
        // that neither its constructor nor clear() initializes, leaving it heap-layout-
        // dependent. Zeroing makes that field deterministically 0 -- the same value a
        // fresh-page allocation gives -- and lets the Worker construction rely on
        // zero-fill.
        @memset(@as([*]u8, @ptrCast(ptr))[0..rounded_size], 0);
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
    stdAlignedFree(ptr);
}

pub fn hasLargePages() bool {
    return builtin.os.tag == .linux;
}

test {
    @import("std").testing.refAllDecls(@This());
}
