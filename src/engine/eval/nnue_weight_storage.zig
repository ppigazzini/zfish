// Own the NNUE weight storage plus the loaded-net identity, split out of
// network.zig so the inference path and the file-I/O path share one owner
// without importing each other. The parse/load path writes the weights straight
// into these buffers; inference reads from the same memory. Owning them here
// (no dependency on network.zig) keeps that split acyclic.
//
// The feature transformer is ~106 MB of SIMD-permuted weights; each per-bucket
// affine layer stack has fc_0/fc_1/fc_2 biases+weights. Large-page allocations
// come from the memory port and are freed there on resize.

const std = @import("std");
const page_alloc = @import("page_alloc");

const layer_stacks_n = 8;
const layers_per_stack = 3;

// Track the loaded-net identity: the current EvalFile name, its description, and the
// initialized flag. The load path owns these.
var nn_initialized: bool = false;
var nn_current: [256]u8 = undefined;
var nn_current_len: usize = 0;
var nn_description: [256]u8 = undefined;
var nn_description_len: usize = 0;

pub fn nnCurrent() []const u8 {
    return nn_current[0..nn_current_len];
}

pub fn nnDescription() []const u8 {
    return nn_description[0..nn_description_len];
}

pub fn markInitialized() void {
    nn_initialized = true;
}

pub fn setLoadedState(current: []const u8, description: []const u8) void {
    const cl = @min(current.len, nn_current.len);
    @memcpy(nn_current[0..cl], current[0..cl]);
    nn_current_len = cl;
    const dl = @min(description.len, nn_description.len);
    @memcpy(nn_description[0..dl], description[0..dl]);
    nn_description_len = dl;
}

pub fn equalCurrentName(target: []const u8) bool {
    return std.mem.eql(u8, nnCurrent(), target);
}

// Hold the inference storage. The parse writes the weights straight here;
// inference reads from the same memory.
var ft_ptr_storage: ?[*]u8 = null;
var ft_len: usize = 0;

pub fn ftStorage(n: usize) ?[*]u8 {
    if (n == 0) return null;
    if (ft_ptr_storage != null and ft_len != n) {
        page_alloc.free(ft_ptr_storage);
        ft_ptr_storage = null;
    }
    if (ft_ptr_storage == null) {
        ft_ptr_storage = @ptrCast(page_alloc.alloc(n) orelse return null);
        ft_len = n;
    }
    return ft_ptr_storage.?;
}

pub fn ftPtr() ?[*]const u8 {
    return ft_ptr_storage;
}

// Name the two arrays an affine layer stores, so a call site reads as `.biases` rather than 0.
pub const LayerPart = enum { biases, weights };

// Fix the affine-layer byte sizes by the NNUE architecture (SFNNv15)
// (fc_0 1024->32, fc_1 64->32, fc_2 128->1; biases int32 linear, weights int8 SSSE3-scrambled).
// sizeof(AffineTransform.biases/weights): {128,128,4} / {32768,2048,128}.
pub const layer_biases_bytes = [layers_per_stack]usize{ 128, 128, 4 };
pub const layer_weights_bytes = [layers_per_stack]usize{ 32768, 2048, 128 };

// Lay every bucket's layer stack out in ONE arena, mirroring upstream's in-line
// `NetworkArchitecture network[LayerStacks]` member: consecutive buckets adjacent,
// parts in traversal order (fc_0 b/w, fc_1 b/w, fc_2 b/w), each part rounded up to a
// cache line so the SIMD kernels keep their 64-byte alignment. One allocation is the
// point, not a convenience: 48 separate huge-page blocks put every part at the same
// address bits modulo 2 MiB, so the whole layer stack aliased a handful of LL cache
// sets and paid ~5 LL misses per eval that upstream does not.
const part_align = 64;
fn alignPart(n: usize) usize {
    return (n + part_align - 1) & ~@as(usize, part_align - 1);
}
const stack_stride = blk: {
    var total: usize = 0;
    for (0..layers_per_stack) |idx| {
        total += alignPart(layer_biases_bytes[idx]) + alignPart(layer_weights_bytes[idx]);
    }
    break :blk total;
};
// Precompute each part's offset inside a bucket's stack at comptime; layerPtr runs
// on the per-eval path, so keep it a table read plus one multiply.
const part_offsets: [layers_per_stack][2]usize = blk: {
    var offsets: [layers_per_stack][2]usize = undefined;
    var off: usize = 0;
    for (0..layers_per_stack) |idx| {
        offsets[idx][@intFromEnum(LayerPart.biases)] = off;
        off += alignPart(layer_biases_bytes[idx]);
        offsets[idx][@intFromEnum(LayerPart.weights)] = off;
        off += alignPart(layer_weights_bytes[idx]);
    }
    break :blk offsets;
};

var layer_arena: ?[*]u8 = null;

pub fn layerStorage(bucket: usize, idx: usize, part: LayerPart, n: usize) ?[*]u8 {
    if (bucket >= layer_stacks_n or idx >= layers_per_stack or n == 0) return null;
    // Reject a size that disagrees with the architecture's layout table; the arena
    // slot cannot hold it.
    const expected = switch (part) {
        .biases => layer_biases_bytes[idx],
        .weights => layer_weights_bytes[idx],
    };
    if (n != expected) return null;
    if (layer_arena == null) {
        layer_arena = @ptrCast(page_alloc.alloc(stack_stride * layer_stacks_n) orelse return null);
    }
    return layer_arena.? + bucket * stack_stride + part_offsets[idx][@intFromEnum(part)];
}

pub fn layerPtr(bucket: usize, idx: usize, part: LayerPart) ?[*]const u8 {
    if (bucket >= layer_stacks_n or idx >= layers_per_stack) return null;
    const arena = layer_arena orelse return null;
    return arena + bucket * stack_stride + part_offsets[idx][@intFromEnum(part)];
}

test {
    @import("std").testing.refAllDecls(@This());
}
