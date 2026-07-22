const std = @import("std");
const position_snapshot = @import("position_snapshot");
const position_types = @import("position_types");
// Type the dirty-piece / dirty-threats slots that stackPush hands to doMove as the
// board's typed records (position_types); the accumulator's local HalfDiff /
// ThreatDiffView are layout-identical views of the same bytes.
const DirtyPiece = position_types.DirtyPiece;
const DirtyThreats = position_types.DirtyThreats;
// Thread `pos` through the accumulator path as the board's typed record: every use
// either hands it onward or feeds position_snapshot.fill(),
// whose registration boundary is the sole remaining erasure. The concrete
// *const Position coerces to the hook's *const anyopaque at that one call.
const Position = position_types.Position;
// Call the pure-Zig feature-index helpers directly rather than across a C-ABI
// boundary. Passing a small `extern struct` BY VALUE
// across is mis-marshaled by Zig 0.16 on aarch64 (the 4-byte
// HalfThreatParams / 7-byte HalfDiff arrive scrambled), which silently corrupted
// the psq feature indices off-x86 (the bench diverged from the anchor). A direct
// Zig call has no C-ABI marshaling, so it is correct on every target and bit-
// identical on x86.
const nnue_feature = @import("nnue_feature");

// Alias the vectorized FT weight-row add/sub kernels from the nnue_acc_rowops leaf
// so the refresh/incremental core stays unqualified.
const nnue_acc_rowops = @import("nnue_acc_rowops");
const applyAccumulatorDeltaI16 = nnue_acc_rowops.applyAccumulatorDeltaI16;
const applyAccumulatorDeltaInPlaceI16 = nnue_acc_rowops.applyAccumulatorDeltaInPlaceI16;
const applyAccumulatorDeltaI8 = nnue_acc_rowops.applyAccumulatorDeltaI8;
const accumulateRowsI8 = nnue_acc_rowops.accumulateRowsI8;
const applyPsqtDelta = nnue_acc_rowops.applyPsqtDelta;
const applyPsqtDeltaInPlace = nnue_acc_rowops.applyPsqtDeltaInPlace;
const accumulatePsqtRows = nnue_acc_rowops.accumulatePsqtRows;

// Alias the FeatureTransformer weight-blob layout + accessors from the nnue_ft leaf
// for the refresh/apply-delta core.
const nnue_ft = @import("nnue_ft");
/// Re-export the opaque FT handle so callers (network.zig) can type the pointer they
/// hand in without importing nnue_ft directly.
pub const FeatureTransformer = nnue_ft.FeatureTransformer;
const featureTransformerPsqWeights = nnue_ft.featureTransformerPsqWeights;
const featureTransformerThreatWeights = nnue_ft.featureTransformerThreatWeights;
const featureTransformerPsqPsqtWeights = nnue_ft.featureTransformerPsqPsqtWeights;
const featureTransformerThreatPsqtWeights = nnue_ft.featureTransformerThreatPsqtWeights;

// Alias the refresh cache / finny tables from the nnue_refresh_cache leaf for the
// refresh path; re-export clearRefreshCache (external).
const nnue_refresh_cache = @import("nnue_refresh_cache");
/// Re-export the opaque cache handle so callers can type it.
pub const RefreshCache = nnue_refresh_cache.RefreshCache;
pub const clearRefreshCache = nnue_refresh_cache.clearRefreshCache;
const cacheEntry = nnue_refresh_cache.cacheEntry;
const cacheEntryAccumulationConst = nnue_refresh_cache.cacheEntryAccumulationConst;
const cacheEntryAccumulationMut = nnue_refresh_cache.cacheEntryAccumulationMut;
const cacheEntryPsqtConst = nnue_refresh_cache.cacheEntryPsqtConst;
const cacheEntryPsqtMut = nnue_refresh_cache.cacheEntryPsqtMut;
const cacheEntryPiecesMut = nnue_refresh_cache.cacheEntryPiecesMut;
const setCacheEntryPieceBb = nnue_refresh_cache.setCacheEntryPieceBb;

// Alias back the accumulator-stack layout + accessors, which live in the
// nnue_acc_layout leaf now, so the facade + update call sites are unqualified
// (AccumulatorStack re-exported pub for external callers).
const layout = @import("nnue_acc_layout.zig");
const psq_feature = layout.psq_feature;
const threat_feature = layout.threat_feature;
const white = layout.white;
const black = layout.black;
const king_piece = layout.king_piece;
const pawn_piece_type = layout.pawn_piece_type;
const no_piece = layout.no_piece;
const sq_none = layout.sq_none;
const square_count = layout.square_count;
const max_stack_size = layout.max_stack_size;
const nnue_align = layout.nnue_align;
const color_count = layout.color_count;
const half_dimensions = layout.half_dimensions;
const psqt_buckets = layout.psqt_buckets;
const transform_vec_width = layout.transform_vec_width;
const dirty_threat_capacity = layout.dirty_threat_capacity;
const psq_index_capacity = layout.psq_index_capacity;
const threat_index_capacity = layout.threat_index_capacity;
const threat_dimensions = layout.threat_dimensions;
const psq_feature_dimensions = layout.psq_feature_dimensions;
const HalfDiff = layout.HalfDiff;
const DirtyThreatRaw = layout.DirtyThreatRaw;
const DirtyThreatListView = layout.DirtyThreatListView;
const ThreatDiffView = layout.ThreatDiffView;
pub const AccumulatorStack = layout.AccumulatorStack;
const BridgePositionSnapshot = layout.BridgePositionSnapshot;
const accumulator_bytes = layout.accumulator_bytes;
const computed_offset = layout.computed_offset;
const accumulator_state_bytes = layout.accumulator_state_bytes;
const psq_diff_offset = layout.psq_diff_offset;
const threat_diff_offset = layout.threat_diff_offset;
const psq_state_stride = layout.psq_state_stride;
const threat_state_stride = layout.threat_state_stride;
const psq_array_bytes = layout.psq_array_bytes;
const threat_array_offset = layout.threat_array_offset;
const threat_array_bytes = layout.threat_array_bytes;
const stack_size_offset = layout.stack_size_offset;
const threat_refresh_diff_offset = layout.threat_refresh_diff_offset;
const findLastUsable = layout.findLastUsable;
const roundUp = layout.roundUp;
const stackBytes = layout.stackBytes;
const stackBytesMut = layout.stackBytesMut;
const stackSize = layout.stackSize;
const setStackSize = layout.setStackSize;
const stateComputed = layout.stateComputed;
const clearComputed = layout.clearComputed;
const stateRequiresRefresh = layout.stateRequiresRefresh;
const stateOffset = layout.stateOffset;
const diffOffset = layout.diffOffset;
const stateBytesConst = layout.stateBytesConst;
const stateBytesMut = layout.stateBytesMut;
const stateAccumulationConst = layout.stateAccumulationConst;
const stateAccumulationMut = layout.stateAccumulationMut;
const statePsqtConst = layout.statePsqtConst;
const statePsqtMut = layout.statePsqtMut;
const diffBytesMut = layout.diffBytesMut;
const psqDiff = layout.psqDiff;
const threatDiff = layout.threatDiff;
const zeroDiff = layout.zeroDiff;
const psqRequiresRefresh = layout.psqRequiresRefresh;
const threatRequiresRefresh = layout.threatRequiresRefresh;
const kingPiece = layout.kingPiece;

// Alias the refresh/incremental update algorithm from the nnue_acc_update leaf
// now; the facade calls evaluateSide (4x from evaluate).
const nnue_acc_update = @import("nnue_acc_update.zig");
const evaluateSide = nnue_acc_update.evaluateSide;
pub const StackPushOutput = struct {
    dirty_piece: *DirtyPiece,
    dirty_threats: *DirtyThreats,
};

pub fn evaluate(
    stack: *AccumulatorStack,
    pos: *const Position,
    feature_transformer: *const FeatureTransformer,
    cache: *RefreshCache,
) void {
    // Match upstream AccumulatorStack::evaluate: one combined (HalfKA + Threats) pass per
    // perspective, not one per (feature, perspective). The combined accumulator lives
    // in the psq_feature storage slot.
    evaluateSide(white, stack, pos, feature_transformer, cache);
    evaluateSide(black, stack, pos, feature_transformer, cache);
}

pub fn stackLatestPsq(stack: *const AccumulatorStack) [*]const u8 {
    return stateBytesConst(psq_feature, stackSize(stack) - 1, stack);
}

pub fn stackLatestThreat(stack: *const AccumulatorStack) [*]const u8 {
    return stateBytesConst(threat_feature, stackSize(stack) - 1, stack);
}

// Port FeatureTransformer::transform (src/nnue/nnue_feature_transformer.h scalar path)
// to Zig. After the (Zig) accumulator evaluate, read the latest PSQ +
// Threat accumulator states and produce the int8 transformed output plus the
// perspective-differenced psqt. BiasType is int16, so the accumulation sum wraps
// in int16 before the [0,255] clamp; the pairwise product is /512.
const state_psqt_offset: usize = color_count * half_dimensions * @sizeOf(i16);

/// Set one bit per 4-byte output chunk when that chunk is non-zero. Upstream's NNZInfo
/// (nnz_helper.h), recorded here rather than re-derived by a later pass: the values are
/// already in a register at the point they are packed.
// half_dimensions output bytes / 4 (bytes per chunk) / 64 (bits per word): the transform
// emits half_dimensions bytes = half_dimensions/4 non-zero-chunk bits, so 4 u64 words cover
// the 256 chunks. (The former `* 2` sized it for 2048 output bytes, twice the real width.)
pub const nnz_word_count: usize = half_dimensions / 4 / 64;
pub const NnzBitset = [nnz_word_count]u64;

pub fn transformBucket(
    stack: *AccumulatorStack,
    pos: *const Position,
    feature_transformer: *const FeatureTransformer,
    cache: *RefreshCache,
    bucket: usize,
    stm: u8,
    output: [*]u8,
    nnz: *NnzBitset,
) i32 {
    evaluate(stack, pos, feature_transformer, cache);

    // Read the single combined (HalfKA + Threats) accumulator from the psq_feature slot.
    // Carry the state's 64-byte alignment (arena base + nnue_align'd strides, pinned by
    // nnue_acc_layout's comptime asserts) in the type: non-VEX SSE folds the accumulator
    // loads into pminsw's m128 operand only when 16-byte alignment is provable.
    const comb_bytes: [*]const u8 = stackLatestPsq(stack);
    const comb_acc: [*]align(nnue_align) const i16 = @ptrCast(@alignCast(comb_bytes));
    const comb_psqt: [*]const i32 = @ptrCast(@alignCast(comb_bytes + state_psqt_offset));

    const p0: usize = stm;
    const p1: usize = stm ^ 1;

    // (psq_diff + thr_diff)/2 == (combined_diff)/2 since combined = psq + threat.
    const psqt: i32 = @divTrunc(comb_psqt[p0 * psqt_buckets + bucket] - comb_psqt[p1 * psqt_buckets + bucket], 2);

    // Produce the pairwise squared-clipped-ReLU output (port of upstream FeatureTransformer::
    // transform). Per element: sum psq+threat accumulators (i16 wrap), ClippedReLU to
    // [0,255], multiply the two halves and divide by 512 -> u8. Stays in 16-bit via
    // SF's mulhi identity  (c0*c1) >> 9  ==  ((c0<<7) * c1) >> 16  ==  pmulhuw(c0<<7, c1),
    // which avoids the i32 widening so each vector register holds twice the lanes. The
    // scaled product 128*c0*c1 is exact and >>16 is floor, so this is bit-identical to
    // the i32 clamp*mul>>9 path (integer, no rounding): signature 2792255.
    const half = half_dimensions / 2;
    const V = transform_vec_width;
    const Vi16 = @Vector(V, i16);
    const Vu16 = @Vector(V, u16);
    const Vu32 = @Vector(V, u32);
    const zero: Vi16 = @splat(0);
    const c255: Vi16 = @splat(255);
    const shl7: @Vector(V, u4) = @splat(7);
    const shr16: @Vector(V, u5) = @splat(16);
    const groups_per_step = V / 4;
    const Vg = @Vector(groups_per_step, u32);
    const GMask = @Int(.unsigned, groups_per_step);
    const Vgm = @Vector(groups_per_step, GMask);
    // Weight each lane by its bit position, so @select + @reduce(.Or) builds the movemask from
    // defined operations. @bitCast of the @Vector(N, bool) would be shorter, but it assumes the
    // bit-packed layout LLVM gives <N x i1>, and Zig leaves vector memory layout target-defined
    // -- a backend using one byte per lane reads a few lanes' bytes as the whole mask, which
    // corrupts the nnz bitset into a wrong POSITIONAL eval rather than a crash. std.simd builds
    // every bool-vector result this way for the same reason.
    const lane_bits: Vgm = comptime blk: {
        var w: [groups_per_step]GMask = undefined;
        for (&w, 0..) |*bit, i| bit.* = @as(GMask, 1) << @intCast(i);
        break :blk w;
    };
    const no_bits: Vgm = @splat(0);
    @memset(nnz, 0);
    var p: usize = 0;
    while (p < 2) : (p += 1) {
        const pp: usize = if (p == 0) p0 else p1;
        const offset = half * p;
        const base = pp * half_dimensions;
        var j: usize = 0;
        while (j < half) : (j += V) {
            // Assert the state's alignment on the loads themselves (a runtime-offset slice
            // degrades to align(2)): base, j and half are all multiples of V lanes, so each
            // load's byte offset is a multiple of min(64, V*2) from the 64-aligned state and
            // non-VEX SSE can fold it into pminsw's m128. Derive the assert from V so a
            // narrower sweep of transform_vec_width stays sound rather than tripping it.
            const A = comptime @min(64, V * @sizeOf(i16));
            const s0i: Vi16 = @as(*align(A) const [V]i16, @ptrCast(@alignCast(comb_acc + base + j))).*;
            const s1i: Vi16 = @as(*align(A) const [V]i16, @ptrCast(@alignCast(comb_acc + base + j + half))).*;
            const c0: Vu16 = @intCast(@max(zero, @min(c255, s0i))); // ClippedReLU [0,255]
            const c1: Vu16 = @intCast(@max(zero, @min(c255, s1i)));
            // pmulhuw(c0<<7, c1) == (c0*c1) >> 9
            const q: Vu16 = @intCast((@as(Vu32, c0 << shl7) * @as(Vu32, c1)) >> shr16);
            const bytes: @Vector(V, u8) = @intCast(q);
            output[offset + j ..][0..V].* = bytes;
            // Record which 4-byte chunks are non-zero while they are still in a register:
            // a vector compare plus a movemask, no reload of what was just stored.
            const nonzero = @as(Vg, @bitCast(bytes)) != @as(Vg, @splat(0));
            // On x86 the <N x i1> compare result lives in a mask register (vptestmd -> k, avx512)
            // or maps to pmovmskb (sse/avx2), so bitcasting it to the N-bit integer IS the
            // movemask: lane i -> bit i, matching the @select+@reduce weighting exactly. That
            // avoids LLVM rebuilding a value vector and running a ~14-op horizontal OR-reduce to
            // collapse @reduce(.Or) back to a scalar (disasm-confirmed: vptestmd then vpord +
            // vextracti + vpshufd chain). Guarded to x86, where the i1-vector packing is
            // bit-per-lane; other backends keep the portable path (the layout note above). The
            // signature pins that the two produce the identical mask. Port of mcfish be1d576.
            const mask: GMask = if (comptime @import("builtin").cpu.arch == .x86_64)
                @bitCast(nonzero)
            else
                @reduce(.Or, @select(GMask, nonzero, lane_bits, no_bits));
            const bit = (offset + j) / 4;
            nnz[bit / 64] |= @as(u64, mask) << @intCast(bit % 64);
        }
    }
    return psqt;
}

pub fn stackReset(stack: *AccumulatorStack) void {
    const bytes = stackBytesMut(stack);

    clearComputed(bytes, psq_feature, 0);
    zeroDiff(bytes, psq_feature, 0, @sizeOf(HalfDiff));

    // No clearComputed for threat_feature: its computed flags are write-only (nothing reads
    // stateComputed(threat_feature)), and after threat_diff_offset=0 that slot no longer has a
    // computed region -- writing one would be out of bounds. See nnue_acc_layout.zig.
    zeroDiff(bytes, threat_feature, 0, @sizeOf(ThreatDiffView));

    setStackSize(bytes, 1);
}

pub fn stackPush(stack: *AccumulatorStack) StackPushOutput {
    const bytes = stackBytesMut(stack);
    const index = stackSize(stack);
    std.debug.assert(index < max_stack_size);

    clearComputed(bytes, psq_feature, index);
    // threat_feature computed is write-only dead (see stackReset) -- no clear, no region.

    const dirty_threats: *ThreatDiffView = @ptrCast(@alignCast(diffBytesMut(threat_feature, index, stack)));
    dirty_threats.list.size_ = 0;

    setStackSize(bytes, index + 1);

    return .{
        .dirty_piece = @ptrCast(diffBytesMut(psq_feature, index, stack)),
        .dirty_threats = @ptrCast(dirty_threats),
    };
}

pub fn stackPop(stack: *AccumulatorStack) void {
    const bytes = stackBytesMut(stack);
    const size = stackSize(stack);
    std.debug.assert(size > 1);
    setStackSize(bytes, size - 1);
}

test {
    @import("std").testing.refAllDecls(@This());
}
