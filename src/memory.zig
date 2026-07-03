const c = @cImport({
    @cDefine("_GNU_SOURCE", "1");
    @cInclude("stdlib.h");
    @cInclude("sys/mman.h");
});

pub fn stdAlignedAlloc(alignment: usize, size: usize) ?*anyopaque {
    var mem: ?*anyopaque = null;
    if (c.posix_memalign(&mem, alignment, size) != 0) {
        return null;
    }
    return mem;
}

pub fn stdAlignedFree(ptr: ?*anyopaque) void {
    c.free(ptr);
}

pub fn alignedLargePagesAlloc(alloc_size: usize) ?*anyopaque {
    const alignment: usize = 2 * 1024 * 1024;
    const rounded_size = if (alloc_size == 0)
        0
    else
        ((alloc_size + alignment - 1) / alignment) * alignment;

    const mem = stdAlignedAlloc(alignment, rounded_size);
    if (mem) |ptr| {
        // Zero the block. posix_memalign returns uninitialized memory; fresh OS
        // pages happen to be zero, but reused blocks (thread resize, search
        // clear) carry stale data, and the Worker has a field read during
        // multipv search that neither its constructor nor clear() initializes,
        // leaving it heap-layout-dependent. Zeroing makes that field
        // deterministically 0 -- the same value a fresh-page allocation gives --
        // and lets native Worker construction rely on zero-fill.
        @memset(@as([*]u8, @ptrCast(ptr))[0..rounded_size], 0);
        if (@hasDecl(c, "MADV_HUGEPAGE")) {
            _ = c.madvise(ptr, rounded_size, c.MADV_HUGEPAGE);
        }
    }
    return mem;
}

pub fn alignedLargePagesFree(ptr: ?*anyopaque) void {
    stdAlignedFree(ptr);
}

pub fn hasLargePages() bool {
    return @hasDecl(c, "MADV_HUGEPAGE");
}
