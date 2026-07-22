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
/// row_tile_width -- they touch different loops, and a sweep of each finds different optima. Do
/// not fold them into one knob.
///
/// 64 on x86-64, from a paired hardware-counter sweep of {16, 32, 64} on the identical
/// 2792255-node tree: 64 beats 32 by 1.4% instructions on avx512icl and 1.0% on sse41; 16 loses
/// 4.1%. Non-x86 keeps 32, the value it has always run -- no aarch64 measurement exists, and a
/// width is tuned for the tier it was measured on, not a property of the algorithm.
pub const transform_vec_width: usize = blk: {
    const b = @import("builtin");
    if (b.cpu.arch == .x86_64) {
        // 128 on avx512 (measured -1.1% cycles, IPC flat), 64 on the rest of x86 (the {16,32,64}
        // sweep's winner; 16 loses 4.1%). aarch64 keeps 32, unmeasured.
        break :blk if (@import("std").Target.x86.featureSetHas(b.cpu.features, .avx512f)) 128 else 64;
    }
    break :blk 32;
};
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
/// 64-aligned byte buffer of arena_bytes bytes (embedded in the Worker /
/// malloc'd for the eval trace); the state/diff byte-offset accessors below
/// reinterpret it. A distinct handle type, not a bare *anyopaque, so it can't be
/// confused with the FT / refresh-cache handles.
pub const AccumulatorStack = opaque {};

pub const BridgePositionSnapshot = position_snapshot.PositionSnapshot;

pub const accumulator_bytes = color_count * half_dimensions * @sizeOf(i16) + color_count * psqt_buckets * @sizeOf(i32) + color_count * @sizeOf(bool);
pub const computed_offset = color_count * half_dimensions * @sizeOf(i16) + color_count * psqt_buckets * @sizeOf(i32);
pub const accumulator_state_bytes = roundUp(accumulator_bytes, nnue_align);
pub const psq_diff_offset = accumulator_bytes;
// The combined accumulator lives in the psq_feature slot (see nnue_acc_update.zig), so the
// threat slot holds ONLY its per-ply diff -- there is no threat accumulator to reserve a
// prefix for. Place the diff at offset 0: that sheds ~4160 B of dead padding per slot (threat
// stride ~4608 -> ~448), halving the per-thread accumulator arena and shrinking the DTLB reach
// of the N-ply incremental-replay walk. The threat `computed` flags that used to sit in that
// prefix are write-only (nothing reads stateComputed(threat_feature)), so their clears are
// dropped with it (stackReset/stackPush). Port of mcfish fa04404. 0 satisfies any alignment,
// and the slot base is nnue_align'd, so the ThreatDiffView load stays aligned.
pub const threat_diff_offset = 0;
pub const psq_state_stride = accumulator_state_bytes;
pub const threat_state_stride = roundUp(threat_diff_offset + @sizeOf(ThreatDiffView), nnue_align);
pub const psq_array_bytes = psq_state_stride * max_stack_size;
pub const threat_array_offset = psq_array_bytes;
pub const threat_array_bytes = threat_state_stride * max_stack_size;
pub const stack_size_offset = threat_array_offset + threat_array_bytes;
// The arena's total footprint: both state arrays, the trailing size field, rounded to the
// arena alignment. The Worker embeds a buffer of exactly this many bytes -- search_id
// cross-asserts worker_layout.accumulator_stack_size against this so the two layouts
// cannot drift apart again (the threat-slot shrink left the old reservation behind once,
// parking the constructor's size-sentinel write in dead space).
pub const arena_bytes = roundUp(stack_size_offset + @sizeOf(usize), nnue_align);
pub const threat_refresh_diff_offset = threat_diff_offset + @sizeOf(DirtyThreatListView);

// Assert what the accessors' @alignCasts assume. Every state base is reached as
// `base + stride * index`, so each stride must carry the arena's 64-byte alignment forward or
// the i16/i32 views below are unaligned -- which x86 tolerates and aarch64 does not. These are
// arithmetic facts today; pin them so a change to half_dimensions, psqt_buckets or
// max_stack_size fails the build instead of the target.
comptime {
    if (psq_state_stride % nnue_align != 0)
        @compileError("psq_state_stride must keep the arena's nnue_align");
    if (threat_state_stride % nnue_align != 0)
        @compileError("threat_state_stride must keep the arena's nnue_align");
    if (threat_array_offset % nnue_align != 0)
        @compileError("threat_array_offset must keep the arena's nnue_align");
    if (threat_diff_offset % @alignOf(ThreatDiffView) != 0)
        @compileError("threat_diff_offset must satisfy ThreatDiffView's alignment");
    // psq_diff_offset is deliberately NOT rounded: HalfDiff is all-u8, so it needs no
    // alignment. Pin that, since rounding it would silently move every psq diff.
    if (@alignOf(HalfDiff) != 1)
        @compileError("HalfDiff must stay alignment-free for the unrounded psq_diff_offset");
    // threatRequiresRefresh reads us/prev_ksq/ksq at threat_refresh_diff_offset + 0/1/2, so
    // that offset must land on ThreatDiffView's trailing scalars, not inside its list.
    if (threat_refresh_diff_offset - threat_diff_offset != @offsetOf(ThreatDiffView, "us"))
        @compileError("threat_refresh_diff_offset must address ThreatDiffView.us");
}

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

// Return a POINTER into the (stable) accumulator state bytes, not a by-value copy: the view
// embeds a [96]DirtyThreatRaw list (~392 B), so `.*` was a per-node compiler_rt memcpy (776k/
// search). Callers only read, and the state bytes outlive the read, so the pointer is safe.
pub fn threatDiff(bytes: [*]const u8) *const ThreatDiffView {
    return @ptrCast(@alignCast(bytes + threat_diff_offset));
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
