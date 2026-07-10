const std = @import("std");
const position_snapshot = @import("position_snapshot");
const position_types = @import("position_types");
// The dirty-piece / dirty-threats slots that stackPush hands to doMove are the
// board's typed records (position_types); the accumulator's local HalfDiff /
// ThreatDiffView are layout-identical views of the same bytes (M18.4-B4).
const DirtyPiece = position_types.DirtyPiece;
const DirtyThreats = position_types.DirtyThreats;
// The `pos` threaded through the accumulator path is the board's typed record
// (M18.7): every use either hands it onward or feeds position_snapshot.fill(),
// whose registration boundary is the sole remaining erasure. The concrete
// *const Position coerces to the hook's *const anyopaque at that one call.
const Position = position_types.Position;
// Call the pure-Zig feature-index helpers directly instead of round-tripping
// through the C-ABI exports in main.zig. Passing a small `extern struct` BY VALUE
// across is mis-marshaled by Zig 0.16 on aarch64 (the 4-byte
// HalfThreatParams / 7-byte HalfDiff arrive scrambled), which silently corrupted
// the psq feature indices off-x86 (bench diverged: 6860970 vs 2067208). A direct
// Zig call has no C-ABI marshaling, so it is correct on every target and bit-
// identical on x86.
const nnue_feature = @import("nnue_feature");

// Vectorized FT weight-row add/sub kernels live in the nnue_acc_rowops leaf
// (M17.4d); aliased so the refresh/incremental core stays unqualified.
const nnue_acc_rowops = @import("nnue_acc_rowops");
const applyAccumulatorDeltaI16 = nnue_acc_rowops.applyAccumulatorDeltaI16;
const applyAccumulatorDeltaInPlaceI16 = nnue_acc_rowops.applyAccumulatorDeltaInPlaceI16;
const applyAccumulatorDeltaI8 = nnue_acc_rowops.applyAccumulatorDeltaI8;
const accumulateRowsI8 = nnue_acc_rowops.accumulateRowsI8;
const applyPsqtDelta = nnue_acc_rowops.applyPsqtDelta;
const applyPsqtDeltaInPlace = nnue_acc_rowops.applyPsqtDeltaInPlace;
const accumulatePsqtRows = nnue_acc_rowops.accumulatePsqtRows;

// FeatureTransformer weight-blob layout + accessors live in the nnue_ft leaf
// (M17.4e); aliased for the refresh/apply-delta core.
const nnue_ft = @import("nnue_ft");
/// Re-export the opaque FT handle so callers (network.zig) can type the pointer they
/// hand in without importing nnue_ft directly (M18.4-B4).
pub const FeatureTransformer = nnue_ft.FeatureTransformer;
const featureTransformerPsqWeights = nnue_ft.featureTransformerPsqWeights;
const featureTransformerThreatWeights = nnue_ft.featureTransformerThreatWeights;
const featureTransformerPsqPsqtWeights = nnue_ft.featureTransformerPsqPsqtWeights;
const featureTransformerThreatPsqtWeights = nnue_ft.featureTransformerThreatPsqtWeights;

// Refresh cache / finny tables live in the nnue_refresh_cache leaf (M17.4f);
// accessors aliased for the refresh path, clearRefreshCache re-exported (external).
const nnue_refresh_cache = @import("nnue_refresh_cache");
/// Re-export the opaque cache handle so callers can type it (M18.4-B4).
pub const RefreshCache = nnue_refresh_cache.RefreshCache;
pub const clearRefreshCache = nnue_refresh_cache.clearRefreshCache;
const cacheEntry = nnue_refresh_cache.cacheEntry;
const cacheEntryAccumulationConst = nnue_refresh_cache.cacheEntryAccumulationConst;
const cacheEntryAccumulationMut = nnue_refresh_cache.cacheEntryAccumulationMut;
const cacheEntryPsqtConst = nnue_refresh_cache.cacheEntryPsqtConst;
const cacheEntryPsqtMut = nnue_refresh_cache.cacheEntryPsqtMut;
const cacheEntryPiecesMut = nnue_refresh_cache.cacheEntryPiecesMut;
const setCacheEntryPieceBb = nnue_refresh_cache.setCacheEntryPieceBb;

const psq_feature: u8 = 0;
const threat_feature: u8 = 1;
const white: u8 = 0;
const black: u8 = 1;
const king_piece: u8 = 6;
const pawn_piece_type: u8 = 1;
const no_piece: u8 = 0;
const sq_none: u8 = 64;
const square_count: usize = 64;
const max_stack_size: usize = 247;
const nnue_align: usize = 64;
const color_count: usize = 2;
const half_dimensions: usize = 1024;
const psqt_buckets: usize = 8;
const acc_vec_width: usize = 32; // SIMD width, also used by transformBucket's ReLU
const dirty_threat_capacity: usize = 96;
const psq_index_capacity: usize = 32;
const threat_index_capacity: usize = 128;
const threat_dimensions: u32 = 60720;
const psq_feature_dimensions: usize = 22528;

const HalfDiff = struct {
    pc: u8,
    from: u8,
    to: u8,
    remove_sq: u8,
    add_sq: u8,
    remove_pc: u8,
    add_pc: u8,
};

const DirtyThreatRaw = struct {
    data: u32,
};

const DirtyThreatListView = struct {
    values: [dirty_threat_capacity]DirtyThreatRaw,
    size_: usize,
};

const ThreatDiffView = struct {
    list: DirtyThreatListView,
    us: u8,
    prev_ksq: u8,
    ksq: u8,
};

/// Opaque handle to the per-Worker accumulator stack arena (M18.4-B4). A raw
/// 64-aligned byte buffer of accumulator_stack_size bytes (embedded in the Worker /
/// malloc'd for the eval trace); the state/diff byte-offset accessors below
/// reinterpret it. A distinct handle type, not a bare *anyopaque, so it can't be
/// confused with the FT / refresh-cache handles.
pub const AccumulatorStack = opaque {};

pub const StackPushOutput = struct {
    dirty_piece: *DirtyPiece,
    dirty_threats: *DirtyThreats,
};

const HalfAppendDiff = struct {
    from: u8,
    to: u8,
    pc: u8,
    remove_sq: u8,
    add_sq: u8,
    remove_pc: u8,
    add_pc: u8,
};

const FullAppendDiff = struct {
    us: u8,
    prev_ksq: u8,
    ksq: u8,
};

const HalfMakeIndexParams = struct {
    perspective: u8,
    square: u8,
    piece: u8,
    king_square: u8,
};

const HalfAppendResult = struct {
    len: usize,
    indices: [psq_index_capacity]u32,
};

const FullAppendResult = struct {
    len: usize,
    indices: [threat_index_capacity]u32,
};

// The half-KA make-index / append-changed helpers are called directly as
// nnue_feature.halfMakeIndex / halfAppendChanged (see the import note above); the
// former C-ABI extern decls were removed because the by-value struct passing they
// used is mis-marshaled on aarch64.
// full-threats append (changed/active) call nnue_feature directly (M16.7).

const BridgePositionSnapshot = position_snapshot.PositionSnapshot;

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

const PositionSnapshot = struct {
    pieces: [square_count]u8,
    occupied: u64,
};

pub fn evaluate(
    stack: *AccumulatorStack,
    pos: *const Position,
    feature_transformer: *const FeatureTransformer,
    cache: *RefreshCache,
) void {
    evaluateSide(psq_feature, white, stack, pos, feature_transformer, cache);
    evaluateSide(psq_feature, black, stack, pos, feature_transformer, cache);
    evaluateSide(threat_feature, white, stack, pos, feature_transformer, cache);
    evaluateSide(threat_feature, black, stack, pos, feature_transformer, cache);
}

pub fn stackLatestPsq(stack: *const AccumulatorStack) *const anyopaque {
    return @ptrCast(stateBytesConst(psq_feature, stackSize(stack) - 1, stack));
}

pub fn stackLatestThreat(stack: *const AccumulatorStack) *const anyopaque {
    return @ptrCast(stateBytesConst(threat_feature, stackSize(stack) - 1, stack));
}

// FeatureTransformer::transform (src/nnue/nnue_feature_transformer.h scalar path),
// ported to Zig. After the (Zig) accumulator evaluate, read the latest PSQ +
// Threat accumulator states and produce the int8 transformed output plus the
// perspective-differenced psqt. BiasType is int16, so the accumulation sum wraps
// in int16 before the [0,255] clamp; the pairwise product is /512.
const state_psqt_offset: usize = color_count * half_dimensions * @sizeOf(i16);

pub fn transformBucket(
    stack: *AccumulatorStack,
    pos: *const Position,
    feature_transformer: *const FeatureTransformer,
    cache: *RefreshCache,
    bucket: usize,
    stm: u8,
    output: [*]u8,
) c_int {
    evaluate(stack, pos, feature_transformer, cache);

    const psq_bytes: [*]const u8 = @ptrCast(stackLatestPsq(stack));
    const thr_bytes: [*]const u8 = @ptrCast(stackLatestThreat(stack));
    const psq_acc: [*]const i16 = @ptrCast(@alignCast(psq_bytes));
    const thr_acc: [*]const i16 = @ptrCast(@alignCast(thr_bytes));
    const psq_psqt: [*]const i32 = @ptrCast(@alignCast(psq_bytes + state_psqt_offset));
    const thr_psqt: [*]const i32 = @ptrCast(@alignCast(thr_bytes + state_psqt_offset));

    const p0: usize = stm;
    const p1: usize = stm ^ 1;

    var psqt: c_int = psq_psqt[p0 * psqt_buckets + bucket] - psq_psqt[p1 * psqt_buckets + bucket];
    psqt = @divTrunc(psqt + thr_psqt[p0 * psqt_buckets + bucket] - thr_psqt[p1 * psqt_buckets + bucket], 2);

    // Pairwise clipped-ReLU output (M15.3), vectorized. Per element: sum psq+threat
    // accumulators (i16 wrap), clamp to [0,255], multiply the two halves, /512 -> u8.
    // Same element-wise ops as the scalar loop, so bit-exact (signature 2067208).
    const half = half_dimensions / 2;
    const V = acc_vec_width;
    const Vi16 = @Vector(V, i16);
    const Vi32 = @Vector(V, i32);
    const zero: Vi32 = @splat(0);
    const c255: Vi32 = @splat(255);
    const d512: @Vector(V, u32) = @splat(512);
    var p: usize = 0;
    while (p < 2) : (p += 1) {
        const pp: usize = if (p == 0) p0 else p1;
        const offset = half * p;
        const base = pp * half_dimensions;
        var j: usize = 0;
        while (j < half) : (j += V) {
            const s0i: Vi16 = @as(Vi16, psq_acc[base + j ..][0..V].*) +% @as(Vi16, thr_acc[base + j ..][0..V].*);
            const s1i: Vi16 = @as(Vi16, psq_acc[base + j + half ..][0..V].*) +% @as(Vi16, thr_acc[base + j + half ..][0..V].*);
            const c0: Vi32 = @max(zero, @min(c255, @as(Vi32, s0i)));
            const c1: Vi32 = @max(zero, @min(c255, @as(Vi32, s1i)));
            const q: @Vector(V, u32) = @as(@Vector(V, u32), @intCast(c0 * c1)) / d512;
            output[offset + j ..][0..V].* = @as(@Vector(V, u8), @intCast(q));
        }
    }
    return psqt;
}

pub fn stackReset(stack: *AccumulatorStack) void {
    const bytes = stackBytesMut(stack);

    clearComputed(bytes, psq_feature, 0);
    zeroDiff(bytes, psq_feature, 0, @sizeOf(HalfDiff));

    clearComputed(bytes, threat_feature, 0);
    zeroDiff(bytes, threat_feature, 0, @sizeOf(ThreatDiffView));

    setStackSize(bytes, 1);
}

pub fn stackPush(stack: *AccumulatorStack) StackPushOutput {
    const bytes = stackBytesMut(stack);
    const index = stackSize(stack);
    std.debug.assert(index < max_stack_size);

    clearComputed(bytes, psq_feature, index);
    clearComputed(bytes, threat_feature, index);

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

fn evaluateSide(
    feature_kind: u8,
    perspective: u8,
    stack: *AccumulatorStack,
    pos: *const Position,
    feature_transformer: *const FeatureTransformer,
    cache: *RefreshCache,
) void {
    const last_usable = findLastUsable(feature_kind, stack, perspective);
    const size = stackSize(stack);

    if (stateComputed(stack, feature_kind, last_usable, perspective)) {
        var next = last_usable + 1;
        while (next < size) : (next += 1) {
            incrementalStep(
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
        refreshLatest(
            feature_kind,
            perspective,
            stack,
            pos,
            feature_transformer,
            cache,
        );

        var computed_index = size - 1;
        while (computed_index > last_usable) : (computed_index -= 1) {
            incrementalStep(
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

fn refreshLatest(
    feature_kind: u8,
    perspective: u8,
    stack: *AccumulatorStack,
    pos: *const Position,
    feature_transformer: *const FeatureTransformer,
    cache: *RefreshCache,
) void {
    const king_square = loadBridgeSnapshot(pos).king_square[perspective];

    switch (feature_kind) {
        psq_feature => refreshLatestPsq(perspective, king_square, stack, pos, feature_transformer, cache),
        threat_feature => refreshLatestThreat(perspective, king_square, stack, pos, feature_transformer),
        else => unreachable,
    }
}

fn refreshLatestPsq(
    perspective: u8,
    king_square: u8,
    stack: *AccumulatorStack,
    pos: *const Position,
    feature_transformer: *const FeatureTransformer,
    cache: *RefreshCache,
) void {
    const latest_index = stackSize(stack) - 1;
    const entry_ptr = cacheEntry(cache, king_square, perspective);
    const snapshot = positionSnapshot(pos);
    const entry_pieces = cacheEntryPiecesMut(entry_ptr);

    var removed = [_]u32{0} ** psq_index_capacity;
    var added = [_]u32{0} ** psq_index_capacity;
    var removed_len: usize = 0;
    var added_len: usize = 0;
    var square: usize = 0;

    while (square < square_count) : (square += 1) {
        const old_piece = entry_pieces[square];
        const new_piece = snapshot.pieces[square];
        if (old_piece != new_piece and old_piece != no_piece) {
            removed[removed_len] = nnue_feature.halfMakeIndex(.{
                .perspective = perspective,
                .square = @intCast(square),
                .piece = old_piece,
                .king_square = king_square,
            });
            removed_len += 1;
        }
    }

    square = 0;
    while (square < square_count) : (square += 1) {
        const old_piece = entry_pieces[square];
        const new_piece = snapshot.pieces[square];
        if (old_piece != new_piece and new_piece != no_piece) {
            added[added_len] = nnue_feature.halfMakeIndex(.{
                .perspective = perspective,
                .square = @intCast(square),
                .piece = new_piece,
                .king_square = king_square,
            });
            added_len += 1;
        }
    }

    applyAccumulatorDeltaInPlaceI16(
        cacheEntryAccumulationMut(entry_ptr),
        removed[0..removed_len],
        added[0..added_len],
        featureTransformerPsqWeights(feature_transformer),
    );
    applyPsqtDeltaInPlace(
        cacheEntryPsqtMut(entry_ptr),
        removed[0..removed_len],
        added[0..added_len],
        featureTransformerPsqPsqtWeights(feature_transformer),
    );

    @memcpy(entry_pieces, snapshot.pieces[0..]);
    setCacheEntryPieceBb(entry_ptr, snapshot.occupied);

    @memcpy(
        stateAccumulationMut(psq_feature, latest_index, stack, perspective),
        cacheEntryAccumulationConst(entry_ptr),
    );
    @memcpy(
        statePsqtMut(psq_feature, latest_index, stack, perspective),
        cacheEntryPsqtConst(entry_ptr),
    );
    stateBytesMut(psq_feature, latest_index, stack)[computed_offset + perspective] = 1;
}

fn refreshLatestThreat(
    perspective: u8,
    king_square: u8,
    stack: *AccumulatorStack,
    pos: *const Position,
    feature_transformer: *const FeatureTransformer,
) void {
    const latest_index = stackSize(stack) - 1;
    const snapshot = positionSnapshot(pos);
    const active = nnue_feature.fullAppendActive(perspective, king_square, @ptrCast(&snapshot.pieces));
    const accumulation = stateAccumulationMut(threat_feature, latest_index, stack, perspective);
    const psqt = statePsqtMut(threat_feature, latest_index, stack, perspective);

    @memset(accumulation, 0);
    @memset(psqt, 0);

    accumulateRowsI8(accumulation, active.indices[0..active.len], featureTransformerThreatWeights(feature_transformer));
    accumulatePsqtRows(psqt, active.indices[0..active.len], featureTransformerThreatPsqtWeights(feature_transformer));
    stateBytesMut(threat_feature, latest_index, stack)[computed_offset + perspective] = 1;
}

fn incrementalStep(
    stack: *AccumulatorStack,
    feature_kind: u8,
    forward: bool,
    perspective: u8,
    pos: *const Position,
    feature_transformer: *const FeatureTransformer,
    target_index: usize,
    computed_index: usize,
) void {
    const king_square = loadBridgeSnapshot(pos).king_square[perspective];

    switch (feature_kind) {
        psq_feature => incrementalStepPsq(
            stack,
            forward,
            perspective,
            king_square,
            feature_transformer,
            target_index,
            computed_index,
        ),
        threat_feature => incrementalStepThreat(
            stack,
            forward,
            perspective,
            king_square,
            feature_transformer,
            target_index,
            computed_index,
        ),
        else => unreachable,
    }
}

fn incrementalStepPsq(
    stack: *AccumulatorStack,
    forward: bool,
    perspective: u8,
    king_square: u8,
    feature_transformer: *const FeatureTransformer,
    target_index: usize,
    computed_index: usize,
) void {
    std.debug.assert(stateComputed(stack, psq_feature, computed_index, perspective));
    std.debug.assert(!stateComputed(stack, psq_feature, target_index, perspective));

    const diff = if (forward)
        psqDiff(stateBytesConst(psq_feature, target_index, stack))
    else
        psqDiff(stateBytesConst(psq_feature, computed_index, stack));

    const append = nnue_feature.halfAppendChanged(perspective, king_square, .{
        .from = diff.from,
        .to = diff.to,
        .pc = diff.pc,
        .remove_sq = diff.remove_sq,
        .add_sq = diff.add_sq,
        .remove_pc = diff.remove_pc,
        .add_pc = diff.add_pc,
    });

    var removed = [_]u32{0} ** psq_index_capacity;
    var added = [_]u32{0} ** psq_index_capacity;
    var removed_len: usize = 0;
    var added_len: usize = 0;
    var cursor: usize = 0;

    appendHalfChange(&removed, &removed_len, &added, &added_len, append.indices[cursor], forward);
    cursor += 1;

    if (diff.to != sq_none) {
        appendHalfChange(&removed, &removed_len, &added, &added_len, append.indices[cursor], !forward);
        cursor += 1;
    }
    if (diff.remove_sq != sq_none) {
        appendHalfChange(&removed, &removed_len, &added, &added_len, append.indices[cursor], forward);
        cursor += 1;
    }
    if (diff.add_sq != sq_none) {
        appendHalfChange(&removed, &removed_len, &added, &added_len, append.indices[cursor], !forward);
    }

    applyPsqDelta(
        stack,
        perspective,
        feature_transformer,
        target_index,
        computed_index,
        removed[0..removed_len],
        added[0..added_len],
    );
}

fn incrementalStepThreat(
    stack: *AccumulatorStack,
    forward: bool,
    perspective: u8,
    king_square: u8,
    feature_transformer: *const FeatureTransformer,
    target_index: usize,
    computed_index: usize,
) void {
    std.debug.assert(stateComputed(stack, threat_feature, computed_index, perspective));
    std.debug.assert(!stateComputed(stack, threat_feature, target_index, perspective));

    const diff = if (forward)
        threatDiff(stateBytesConst(threat_feature, target_index, stack))
    else
        threatDiff(stateBytesConst(threat_feature, computed_index, stack));

    const append = nnue_feature.fullAppendChanged(
        perspective,
        king_square,
        @ptrCast(&diff.list.values),
        diff.list.size_,
    );

    var removed = [_]u32{0} ** threat_index_capacity;
    var added = [_]u32{0} ** threat_index_capacity;
    var removed_len: usize = 0;
    var added_len: usize = 0;

    for (append.indices[0..append.len], 0..) |index, list_index| {
        if (index >= threat_dimensions) {
            continue;
        }
        const is_add = (diff.list.values[list_index].data >> 31) != 0;
        if (is_add == forward) {
            added[added_len] = index;
            added_len += 1;
        } else {
            removed[removed_len] = index;
            removed_len += 1;
        }
    }

    applyThreatDelta(
        stack,
        perspective,
        feature_transformer,
        target_index,
        computed_index,
        removed[0..removed_len],
        added[0..added_len],
    );
}

fn appendHalfChange(
    removed: *[psq_index_capacity]u32,
    removed_len: *usize,
    added: *[psq_index_capacity]u32,
    added_len: *usize,
    index: u32,
    is_removed: bool,
) void {
    if (is_removed) {
        removed[removed_len.*] = index;
        removed_len.* += 1;
    } else {
        added[added_len.*] = index;
        added_len.* += 1;
    }
}

fn applyPsqDelta(
    stack: *AccumulatorStack,
    perspective: u8,
    feature_transformer: *const FeatureTransformer,
    target_index: usize,
    computed_index: usize,
    removed: []const u32,
    added: []const u32,
) void {
    applyAccumulatorDeltaI16(
        stateAccumulationMut(psq_feature, target_index, stack, perspective),
        stateAccumulationConst(psq_feature, computed_index, stack, perspective),
        removed,
        added,
        featureTransformerPsqWeights(feature_transformer),
    );
    applyPsqtDelta(
        statePsqtMut(psq_feature, target_index, stack, perspective),
        statePsqtConst(psq_feature, computed_index, stack, perspective),
        removed,
        added,
        featureTransformerPsqPsqtWeights(feature_transformer),
    );
    stateBytesMut(psq_feature, target_index, stack)[computed_offset + perspective] = 1;
}

fn applyThreatDelta(
    stack: *AccumulatorStack,
    perspective: u8,
    feature_transformer: *const FeatureTransformer,
    target_index: usize,
    computed_index: usize,
    removed: []const u32,
    added: []const u32,
) void {
    applyAccumulatorDeltaI8(
        stateAccumulationMut(threat_feature, target_index, stack, perspective),
        stateAccumulationConst(threat_feature, computed_index, stack, perspective),
        removed,
        added,
        featureTransformerThreatWeights(feature_transformer),
    );
    applyPsqtDelta(
        statePsqtMut(threat_feature, target_index, stack, perspective),
        statePsqtConst(threat_feature, computed_index, stack, perspective),
        removed,
        added,
        featureTransformerThreatPsqtWeights(feature_transformer),
    );
    stateBytesMut(threat_feature, target_index, stack)[computed_offset + perspective] = 1;
}

fn findLastUsable(feature_kind: u8, stack: *const AccumulatorStack, perspective: u8) usize {
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

fn stackBytes(stack: *const AccumulatorStack) [*]const u8 {
    return @ptrCast(stack);
}

fn stackBytesMut(stack: *AccumulatorStack) [*]u8 {
    return @ptrCast(stack);
}

fn stackSize(stack: *const AccumulatorStack) usize {
    const bytes = stackBytes(stack);
    return std.mem.readInt(usize, bytes[stack_size_offset..][0..@sizeOf(usize)], .little);
}

fn setStackSize(bytes: [*]u8, size: usize) void {
    std.mem.writeInt(usize, bytes[stack_size_offset..][0..@sizeOf(usize)], size, .little);
}

fn stateComputed(stack: *const AccumulatorStack, feature_kind: u8, index: usize, perspective: u8) bool {
    const bytes = stackBytes(stack);
    return bytes[stateOffset(feature_kind, index) + computed_offset + perspective] != 0;
}

fn clearComputed(bytes: [*]u8, feature_kind: u8, index: usize) void {
    @memset(bytes[stateOffset(feature_kind, index) + computed_offset ..][0..color_count], 0);
}

fn stateRequiresRefresh(stack: *const AccumulatorStack, feature_kind: u8, index: usize, perspective: u8) bool {
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

fn diffOffset(feature_kind: u8) usize {
    return switch (feature_kind) {
        psq_feature => psq_diff_offset,
        threat_feature => threat_diff_offset,
        else => unreachable,
    };
}

fn stateBytesConst(feature_kind: u8, index: usize, stack: *const AccumulatorStack) [*]const u8 {
    return stackBytes(stack) + stateOffset(feature_kind, index);
}

fn stateBytesMut(feature_kind: u8, index: usize, stack: *AccumulatorStack) [*]u8 {
    return stackBytesMut(stack) + stateOffset(feature_kind, index);
}

fn positionSnapshot(pos: *const Position) PositionSnapshot {
    const bridge = loadBridgeSnapshot(pos);
    var snapshot = PositionSnapshot{
        .pieces = [_]u8{0} ** square_count,
        .occupied = 0,
    };

    snapshot.occupied = bridge.pieces_all;
    @memcpy(snapshot.pieces[0..], bridge.board[0..]);

    return snapshot;
}

fn loadBridgeSnapshot(pos: *const Position) BridgePositionSnapshot {
    var snapshot = std.mem.zeroes(BridgePositionSnapshot);
    position_snapshot.fill(pos, &snapshot);
    return snapshot;
}

fn stateAccumulationConst(feature_kind: u8, index: usize, stack: *const AccumulatorStack, perspective: u8) []const i16 {
    const offset = perspective * half_dimensions * @sizeOf(i16);
    const ptr: [*]const i16 = @ptrCast(@alignCast(stateBytesConst(feature_kind, index, stack) + offset));
    return ptr[0..half_dimensions];
}

fn stateAccumulationMut(feature_kind: u8, index: usize, stack: *AccumulatorStack, perspective: u8) []i16 {
    const offset = perspective * half_dimensions * @sizeOf(i16);
    const ptr: [*]i16 = @ptrCast(@alignCast(stateBytesMut(feature_kind, index, stack) + offset));
    return ptr[0..half_dimensions];
}

fn statePsqtConst(feature_kind: u8, index: usize, stack: *const AccumulatorStack, perspective: u8) []const i32 {
    const offset = color_count * half_dimensions * @sizeOf(i16) + perspective * psqt_buckets * @sizeOf(i32);
    const ptr: [*]const i32 = @ptrCast(@alignCast(stateBytesConst(feature_kind, index, stack) + offset));
    return ptr[0..psqt_buckets];
}

fn statePsqtMut(feature_kind: u8, index: usize, stack: *AccumulatorStack, perspective: u8) []i32 {
    const offset = color_count * half_dimensions * @sizeOf(i16) + perspective * psqt_buckets * @sizeOf(i32);
    const ptr: [*]i32 = @ptrCast(@alignCast(stateBytesMut(feature_kind, index, stack) + offset));
    return ptr[0..psqt_buckets];
}

fn diffBytesMut(feature_kind: u8, index: usize, stack: *AccumulatorStack) [*]u8 {
    return stateBytesMut(feature_kind, index, stack) + diffOffset(feature_kind);
}

fn psqDiff(bytes: [*]const u8) HalfDiff {
    return @as(*const HalfDiff, @ptrCast(@alignCast(bytes + psq_diff_offset))).*;
}

fn threatDiff(bytes: [*]const u8) ThreatDiffView {
    return @as(*const ThreatDiffView, @ptrCast(@alignCast(bytes + threat_diff_offset))).*;
}

fn zeroDiff(bytes: [*]u8, feature_kind: u8, index: usize, len: usize) void {
    @memset(bytes[stateOffset(feature_kind, index) + diffOffset(feature_kind) ..][0..len], 0);
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
