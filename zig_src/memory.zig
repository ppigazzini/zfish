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
