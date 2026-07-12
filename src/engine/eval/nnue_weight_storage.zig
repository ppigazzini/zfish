// Native-owned NNUE weight storage plus the loaded-net identity, split out of
// network.zig so the inference path and the file-I/O path share one owner
// without importing each other. The parse/load path writes the weights straight
// into these buffers; inference reads from the same memory. Owning them here
// (no dependency on network.zig) keeps that split acyclic.
//
// The feature transformer is ~106 MB of SIMD-permuted weights; each per-bucket
// affine layer stack has fc_0/fc_1/fc_2 biases+weights. Large-page allocations
// come from the memory port and are freed there on resize.

const std = @import("std");
const memory_port = @import("memory");

const layer_stacks_n = 8;
const layers_per_stack = 3;

// Loaded-net identity: the current EvalFile name, its description, and the
// initialized flag. The native load path owns these.
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

pub fn markInitializedNative() void {
    nn_initialized = true;
}

pub fn setLoadedStateNative(current: []const u8, description: []const u8) void {
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

// Inference storage. The native parse writes the weights straight here;
// inference reads from the same memory.
var native_ft_ptr_storage: ?[*]u8 = null;
var native_ft_len: usize = 0;

pub fn ftStorage(n: usize) ?[*]u8 {
    if (n == 0) return null;
    if (native_ft_ptr_storage != null and native_ft_len != n) {
        memory_port.alignedLargePagesFree(native_ft_ptr_storage);
        native_ft_ptr_storage = null;
    }
    if (native_ft_ptr_storage == null) {
        native_ft_ptr_storage = @ptrCast(memory_port.alignedLargePagesAlloc(n) orelse return null);
        native_ft_len = n;
    }
    return native_ft_ptr_storage.?;
}

pub fn ftPtr() ?[*]const u8 {
    return native_ft_ptr_storage;
}

var native_layer_w: [layer_stacks_n][layers_per_stack]?[*]u8 =
    .{.{ null, null, null }} ** layer_stacks_n;
var native_layer_b: [layer_stacks_n][layers_per_stack]?[*]u8 =
    .{.{ null, null, null }} ** layer_stacks_n;

pub fn layerStorage(bucket: usize, idx: c_int, is_weights: c_int, n: usize) ?[*]u8 {
    if (bucket >= layer_stacks_n or idx < 0 or idx >= layers_per_stack or n == 0) return null;
    const ui: usize = @intCast(idx);
    const slot = if (is_weights != 0) &native_layer_w[bucket][ui] else &native_layer_b[bucket][ui];
    if (slot.* == null) slot.* = @ptrCast(memory_port.alignedLargePagesAlloc(n) orelse return null);
    return slot.*.?;
}

pub fn layerPtr(bucket: usize, idx: c_int, is_weights: c_int) ?[*]const u8 {
    if (bucket >= layer_stacks_n or idx < 0 or idx >= layers_per_stack) return null;
    const ui: usize = @intCast(idx);
    return if (is_weights != 0) native_layer_w[bucket][ui] else native_layer_b[bucket][ui];
}

test {
    @import("std").testing.refAllDecls(@This());
}
