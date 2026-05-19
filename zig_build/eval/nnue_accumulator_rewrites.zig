const std = @import("std");

const psq_feature: u8 = 0;
const threat_feature: u8 = 1;
const white: u8 = 0;
const black: u8 = 1;
const king_piece: u8 = 6;
const max_stack_size: usize = 247;
const nnue_align: usize = 64;
const color_count: usize = 2;
const half_dimensions: usize = 1024;
const psqt_buckets: usize = 8;
const dirty_threat_capacity: usize = 96;

const HalfDiff = extern struct {
    pc: u8,
    from: u8,
    to: u8,
    remove_sq: u8,
    add_sq: u8,
    remove_pc: u8,
    add_pc: u8,
};

const DirtyThreatRaw = extern struct {
    data: u32,
};

const DirtyThreatListView = extern struct {
    values: [dirty_threat_capacity]DirtyThreatRaw,
    size_: usize,
};

const ThreatDiffView = extern struct {
    list: DirtyThreatListView,
    us: u8,
    prev_ksq: u8,
    ksq: u8,
};

extern fn zfish_accumulator_incremental_step(
    stack: *anyopaque,
    feature_kind: u8,
    forward: bool,
    perspective: u8,
    pos: *const anyopaque,
    feature_transformer: *const anyopaque,
    target_index: usize,
    computed_index: usize,
) void;
extern fn zfish_accumulator_refresh_latest(
    stack: *anyopaque,
    feature_kind: u8,
    perspective: u8,
    pos: *const anyopaque,
    feature_transformer: *const anyopaque,
    cache: *anyopaque,
) void;

const accumulator_bytes = color_count * half_dimensions * @sizeOf(i16) + color_count * psqt_buckets * @sizeOf(i32) + color_count * @sizeOf(bool);
const computed_offset = color_count * half_dimensions * @sizeOf(i16) + color_count * psqt_buckets * @sizeOf(i32);
const accumulator_state_bytes = roundUp(accumulator_bytes, nnue_align);
const psq_diff_offset = accumulator_bytes;
const threat_diff_offset = roundUp(accumulator_bytes, @alignOf(ThreatDiffView));
const psq_state_stride = accumulator_state_bytes;
const threat_state_stride = roundUp(threat_diff_offset + @sizeOf(ThreatDiffView), nnue_align);
const psq_array_bytes = psq_state_stride * max_stack_size;
const threat_array_offset = psq_array_bytes;
const threat_array_bytes = threat_state_stride * max_stack_size;
const stack_size_offset = threat_array_offset + threat_array_bytes;
const threat_refresh_diff_offset = threat_diff_offset + @sizeOf(DirtyThreatListView);

pub fn evaluate(
    stack: *anyopaque,
    pos: *const anyopaque,
    feature_transformer: *const anyopaque,
    cache: *anyopaque,
) void {
    evaluateSide(psq_feature, white, stack, pos, feature_transformer, cache);
    evaluateSide(psq_feature, black, stack, pos, feature_transformer, cache);
    evaluateSide(threat_feature, white, stack, pos, feature_transformer, cache);
    evaluateSide(threat_feature, black, stack, pos, feature_transformer, cache);
}

fn evaluateSide(
    feature_kind: u8,
    perspective: u8,
    stack: *anyopaque,
    pos: *const anyopaque,
    feature_transformer: *const anyopaque,
    cache: *anyopaque,
) void {
    const last_usable = findLastUsable(feature_kind, stack, perspective);
    const size = stackSize(stack);

    if (stateComputed(stack, feature_kind, last_usable, perspective)) {
        var next = last_usable + 1;
        while (next < size) : (next += 1) {
            zfish_accumulator_incremental_step(
                stack,
                feature_kind,
                true,
                perspective,
                pos,
                feature_transformer,
                next,
                next - 1,
            );
        }
    } else {
        zfish_accumulator_refresh_latest(
            stack,
            feature_kind,
            perspective,
            pos,
            feature_transformer,
            cache,
        );

        var computed_index = size - 1;
        while (computed_index > last_usable) : (computed_index -= 1) {
            zfish_accumulator_incremental_step(
                stack,
                feature_kind,
                false,
                perspective,
                pos,
                feature_transformer,
                computed_index - 1,
                computed_index,
            );
        }
    }
}

fn findLastUsable(feature_kind: u8, stack: *const anyopaque, perspective: u8) usize {
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

fn roundUp(value: usize, alignment: usize) usize {
    return ((value + alignment - 1) / alignment) * alignment;
}

fn stackBytes(stack: *const anyopaque) [*]const u8 {
    return @ptrCast(stack);
}

fn stackSize(stack: *const anyopaque) usize {
    const bytes = stackBytes(stack);
    return std.mem.readInt(usize, bytes[stack_size_offset..][0..@sizeOf(usize)], .little);
}

fn stateComputed(stack: *const anyopaque, feature_kind: u8, index: usize, perspective: u8) bool {
    const bytes = stackBytes(stack);
    return bytes[stateOffset(feature_kind, index) + computed_offset + perspective] != 0;
}

fn stateRequiresRefresh(stack: *const anyopaque, feature_kind: u8, index: usize, perspective: u8) bool {
    const bytes = stackBytes(stack);
    return switch (feature_kind) {
        psq_feature => psqRequiresRefresh(bytes, index, perspective),
        threat_feature => threatRequiresRefresh(bytes, index, perspective),
        else => unreachable,
    };
}

fn stateOffset(feature_kind: u8, index: usize) usize {
    return switch (feature_kind) {
        psq_feature => index * psq_state_stride,
        threat_feature => threat_array_offset + index * threat_state_stride,
        else => unreachable,
    };
}

fn psqRequiresRefresh(bytes: [*]const u8, index: usize, perspective: u8) bool {
    const offset = stateOffset(psq_feature, index) + psq_diff_offset;
    return bytes[offset] == kingPiece(perspective);
}

fn threatRequiresRefresh(bytes: [*]const u8, index: usize, perspective: u8) bool {
    const offset = stateOffset(threat_feature, index) + threat_refresh_diff_offset;
    return perspective == bytes[offset] and
        (((@as(i8, @bitCast(bytes[offset + 2])) & 0b100) != (@as(i8, @bitCast(bytes[offset + 1])) & 0b100)));
}

fn kingPiece(perspective: u8) u8 {
    return king_piece + 8 * perspective;
}
