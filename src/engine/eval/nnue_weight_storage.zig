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

var layer_w: [layer_stacks_n][layers_per_stack]?[*]u8 =
    @splat(.{ null, null, null });
var layer_b: [layer_stacks_n][layers_per_stack]?[*]u8 =
    @splat(.{ null, null, null });

// Name the two arrays an affine layer stores, so a call site reads as `.biases` rather than 0.
pub const LayerPart = enum { biases, weights };

pub fn layerStorage(bucket: usize, idx: usize, part: LayerPart, n: usize) ?[*]u8 {
    if (bucket >= layer_stacks_n or idx >= layers_per_stack or n == 0) return null;
    const slot = switch (part) {
        .weights => &layer_w[bucket][idx],
        .biases => &layer_b[bucket][idx],
    };
    if (slot.* == null) slot.* = @ptrCast(page_alloc.alloc(n) orelse return null);
    return slot.*.?;
}

pub fn layerPtr(bucket: usize, idx: usize, part: LayerPart) ?[*]const u8 {
    if (bucket >= layer_stacks_n or idx >= layers_per_stack) return null;
    return switch (part) {
        .weights => layer_w[bucket][idx],
        .biases => layer_b[bucket][idx],
    };
}

test {
    @import("std").testing.refAllDecls(@This());
}
