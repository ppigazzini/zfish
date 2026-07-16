// Lay out the NNUE accumulator-stack memory, split out of nnue_accumulator.zig: the
// per-state byte offsets/strides, the diff-view record types, the opaque
// AccumulatorStack handle, and every byte/offset accessor that reinterprets the
// stack buffer. Pure layout math over std + the position snapshot; both the
// accumulator update algorithm and the transform/stack facade import this
// foundation, so the split stays acyclic.

const std = @import("std");
const position_snapshot = @import("position_snapshot");
const position_types = @import("position_types");
const Position = position_types.Position;

pub const psq_feature: u8 = 0;
pub const threat_feature: u8 = 1;
pub const white: u8 = 0;
pub const black: u8 = 1;
pub const king_piece: u8 = 6;
pub const pawn_piece_type: u8 = 1;
pub const no_piece: u8 = 0;
pub const sq_none: u8 = 64;
pub const square_count: usize = 64;
/// Match PieceType.king.
const king_piece_type: u8 = 6;
pub const max_stack_size: usize = 247;
pub const nnue_align: usize = 64;
pub const color_count: usize = 2;
pub const half_dimensions: usize = 1024;
pub const psqt_buckets: usize = 8;
/// Set the lane count for transformBucket's clipped-ReLU pass. Independent of nnue_acc_rowops's
/// row_tile_width -- they touch different loops, and a sweep of each (16/32/64 here; 32/64/128/256
/// there) finds different optima. Do not fold them into one knob.
pub const transform_vec_width: usize = 32;
pub const dirty_threat_capacity: usize = 96;
pub const psq_index_capacity: usize = 32;
pub const threat_index_capacity: usize = 128;
pub const threat_dimensions: u32 = 60720;
pub const psq_feature_dimensions: usize = 22528;

pub const HalfDiff = struct {
    pc: u8,
    from: u8,
    to: u8,
    remove_sq: u8,
    add_sq: u8,
    remove_pc: u8,
    add_pc: u8,
};

pub const DirtyThreatRaw = struct {
    data: u32,
};

pub const DirtyThreatListView = struct {
    values: [dirty_threat_capacity]DirtyThreatRaw,
    size_: usize,
};

pub const ThreatDiffView = struct {
    list: DirtyThreatListView,
    us: u8,
    prev_ksq: u8,
    ksq: u8,
};

/// Expose an opaque handle to the per-Worker accumulator stack arena. A raw
/// 64-aligned byte buffer of accumulator_stack_size bytes (embedded in the Worker /
/// malloc'd for the eval trace); the state/diff byte-offset accessors below
/// reinterpret it. A distinct handle type, not a bare *anyopaque, so it can't be
/// confused with the FT / refresh-cache handles.
pub const AccumulatorStack = opaque {};

pub const BridgePositionSnapshot = position_snapshot.PositionSnapshot;

pub const accumulator_bytes = color_count * half_dimensions * @sizeOf(i16) + color_count * psqt_buckets * @sizeOf(i32) + color_count * @sizeOf(bool);
pub const computed_offset = color_count * half_dimensions * @sizeOf(i16) + color_count * psqt_buckets * @sizeOf(i32);
pub const accumulator_state_bytes = roundUp(accumulator_bytes, nnue_align);
pub const psq_diff_offset = accumulator_bytes;
pub const threat_diff_offset = roundUp(accumulator_bytes, @alignOf(ThreatDiffView));
pub const psq_state_stride = accumulator_state_bytes;
pub const threat_state_stride = roundUp(threat_diff_offset + @sizeOf(ThreatDiffView), nnue_align);
pub const psq_array_bytes = psq_state_stride * max_stack_size;
pub const threat_array_offset = psq_array_bytes;
pub const threat_array_bytes = threat_state_stride * max_stack_size;
pub const stack_size_offset = threat_array_offset + threat_array_bytes;
pub const threat_refresh_diff_offset = threat_diff_offset + @sizeOf(DirtyThreatListView);

pub fn findLastUsable(feature_kind: u8, stack: *const AccumulatorStack, perspective: u8) usize {
    const size = stackSize(stack);
    var current = size - 1;

    while (current > 0) : (current -= 1) {
        if (stateComputed(stack, feature_kind, current, perspective))
            return current;

        if (stateRequiresRefresh(stack, feature_kind, current, perspective))
            return current;
    }

    return 0;
}

pub fn roundUp(value: usize, alignment: usize) usize {
    return ((value + alignment - 1) / alignment) * alignment;
}

pub fn stackBytes(stack: *const AccumulatorStack) [*]const u8 {
    return @ptrCast(stack);
}

pub fn stackBytesMut(stack: *AccumulatorStack) [*]u8 {
    return @ptrCast(stack);
}

pub fn stackSize(stack: *const AccumulatorStack) usize {
    const bytes = stackBytes(stack);
    return std.mem.readInt(usize, bytes[stack_size_offset..][0..@sizeOf(usize)], .little);
}

pub fn setStackSize(bytes: [*]u8, size: usize) void {
    std.mem.writeInt(usize, bytes[stack_size_offset..][0..@sizeOf(usize)], size, .little);
}

pub fn stateComputed(stack: *const AccumulatorStack, feature_kind: u8, index: usize, perspective: u8) bool {
    const bytes = stackBytes(stack);
    return bytes[stateOffset(feature_kind, index) + computed_offset + perspective] != 0;
}

pub fn clearComputed(bytes: [*]u8, feature_kind: u8, index: usize) void {
    @memset(bytes[stateOffset(feature_kind, index) + computed_offset ..][0..color_count], 0);
}

pub fn stateRequiresRefresh(stack: *const AccumulatorStack, feature_kind: u8, index: usize, perspective: u8) bool {
    const bytes = stackBytes(stack);
    return switch (feature_kind) {
        psq_feature => psqRequiresRefresh(bytes, index, perspective),
        threat_feature => threatRequiresRefresh(bytes, index, perspective),
        else => unreachable,
    };
}

pub fn stateOffset(feature_kind: u8, index: usize) usize {
    return switch (feature_kind) {
        psq_feature => index * psq_state_stride,
        threat_feature => threat_array_offset + index * threat_state_stride,
        else => unreachable,
    };
}

pub fn diffOffset(feature_kind: u8) usize {
    return switch (feature_kind) {
        psq_feature => psq_diff_offset,
        threat_feature => threat_diff_offset,
        else => unreachable,
    };
}

pub fn stateBytesConst(feature_kind: u8, index: usize, stack: *const AccumulatorStack) [*]const u8 {
    return stackBytes(stack) + stateOffset(feature_kind, index);
}

pub fn stateBytesMut(feature_kind: u8, index: usize, stack: *AccumulatorStack) [*]u8 {
    return stackBytesMut(stack) + stateOffset(feature_kind, index);
}

/// Compute upstream's `pos.square<KING>(c)`.
pub fn kingSquare(pos: *const Position, color: u8) u8 {
    return @intCast(@ctz(pos.by_color_bb[color] & pos.by_type_bb[king_piece_type]));
}

pub fn stateAccumulationConst(feature_kind: u8, index: usize, stack: *const AccumulatorStack, perspective: u8) []const i16 {
    const offset = perspective * half_dimensions * @sizeOf(i16);
    const ptr: [*]const i16 = @ptrCast(@alignCast(stateBytesConst(feature_kind, index, stack) + offset));
    return ptr[0..half_dimensions];
}

pub fn stateAccumulationMut(feature_kind: u8, index: usize, stack: *AccumulatorStack, perspective: u8) []i16 {
    const offset = perspective * half_dimensions * @sizeOf(i16);
    const ptr: [*]i16 = @ptrCast(@alignCast(stateBytesMut(feature_kind, index, stack) + offset));
    return ptr[0..half_dimensions];
}

pub fn statePsqtConst(feature_kind: u8, index: usize, stack: *const AccumulatorStack, perspective: u8) []const i32 {
    const offset = color_count * half_dimensions * @sizeOf(i16) + perspective * psqt_buckets * @sizeOf(i32);
    const ptr: [*]const i32 = @ptrCast(@alignCast(stateBytesConst(feature_kind, index, stack) + offset));
    return ptr[0..psqt_buckets];
}

pub fn statePsqtMut(feature_kind: u8, index: usize, stack: *AccumulatorStack, perspective: u8) []i32 {
    const offset = color_count * half_dimensions * @sizeOf(i16) + perspective * psqt_buckets * @sizeOf(i32);
    const ptr: [*]i32 = @ptrCast(@alignCast(stateBytesMut(feature_kind, index, stack) + offset));
    return ptr[0..psqt_buckets];
}

pub fn diffBytesMut(feature_kind: u8, index: usize, stack: *AccumulatorStack) [*]u8 {
    return stateBytesMut(feature_kind, index, stack) + diffOffset(feature_kind);
}

pub fn psqDiff(bytes: [*]const u8) HalfDiff {
    return @as(*const HalfDiff, @ptrCast(@alignCast(bytes + psq_diff_offset))).*;
}

pub fn threatDiff(bytes: [*]const u8) ThreatDiffView {
    return @as(*const ThreatDiffView, @ptrCast(@alignCast(bytes + threat_diff_offset))).*;
}

pub fn zeroDiff(bytes: [*]u8, feature_kind: u8, index: usize, len: usize) void {
    @memset(bytes[stateOffset(feature_kind, index) + diffOffset(feature_kind) ..][0..len], 0);
}

pub fn psqRequiresRefresh(bytes: [*]const u8, index: usize, perspective: u8) bool {
    const offset = stateOffset(psq_feature, index) + psq_diff_offset;
    return bytes[offset] == kingPiece(perspective);
}

pub fn threatRequiresRefresh(bytes: [*]const u8, index: usize, perspective: u8) bool {
    const offset = stateOffset(threat_feature, index) + threat_refresh_diff_offset;
    return perspective == bytes[offset] and
        (((@as(i8, @bitCast(bytes[offset + 2])) & 0b100) != (@as(i8, @bitCast(bytes[offset + 1])) & 0b100)));
}

pub fn kingPiece(perspective: u8) u8 {
    return king_piece + 8 * perspective;
}

test {
    @import("std").testing.refAllDecls(@This());
}
