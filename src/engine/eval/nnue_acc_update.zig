// NNUE accumulator update algorithm, split out of nnue_accumulator.zig: the
// per-side refresh + incremental step machinery (evaluateSide, refreshLatest*,
// incrementalStep*, apply*Delta, appendHalfChange) and its append-diff record
// types. Reads/writes accumulator states through the nnue_acc_layout accessors
// and the ft/rowops/refresh-cache/feature leaves; the facade calls evaluateSide,
// never the reverse, so this stays a one-way leaf.

const std = @import("std");
const position_snapshot = @import("position_snapshot");
const position_types = @import("position_types");
const Position = position_types.Position;
const nnue_feature = @import("nnue_feature");

// Vectorized FT weight-row add/sub kernels live in the nnue_acc_rowops leaf
// aliased so the refresh/incremental core stays unqualified.
const nnue_acc_rowops = @import("nnue_acc_rowops");
const applyAccumulatorDeltaI16 = nnue_acc_rowops.applyAccumulatorDeltaI16;
const applyAccumulatorDeltaInPlaceI16 = nnue_acc_rowops.applyAccumulatorDeltaInPlaceI16;
const applyAccumulatorDeltaI8 = nnue_acc_rowops.applyAccumulatorDeltaI8;
const accumulateRowsI8 = nnue_acc_rowops.accumulateRowsI8;
const applyPsqtDelta = nnue_acc_rowops.applyPsqtDelta;
const applyPsqtDeltaInPlace = nnue_acc_rowops.applyPsqtDeltaInPlace;
const accumulatePsqtRows = nnue_acc_rowops.accumulatePsqtRows;

// FeatureTransformer weight-blob layout + accessors live in the nnue_ft leaf
// aliased for the refresh/apply-delta core.
const nnue_ft = @import("nnue_ft");
pub const FeatureTransformer = nnue_ft.FeatureTransformer;
const featureTransformerPsqWeights = nnue_ft.featureTransformerPsqWeights;
const featureTransformerThreatWeights = nnue_ft.featureTransformerThreatWeights;
const featureTransformerPsqPsqtWeights = nnue_ft.featureTransformerPsqPsqtWeights;
const featureTransformerThreatPsqtWeights = nnue_ft.featureTransformerThreatPsqtWeights;

// Refresh cache / finny tables live in the nnue_refresh_cache leaf;
// accessors aliased for the refresh path, clearRefreshCache re-exported (external).
const nnue_refresh_cache = @import("nnue_refresh_cache");
pub const RefreshCache = nnue_refresh_cache.RefreshCache;
pub const clearRefreshCache = nnue_refresh_cache.clearRefreshCache;
const cacheEntry = nnue_refresh_cache.cacheEntry;
const cacheEntryAccumulationConst = nnue_refresh_cache.cacheEntryAccumulationConst;
const cacheEntryAccumulationMut = nnue_refresh_cache.cacheEntryAccumulationMut;
const cacheEntryPsqtConst = nnue_refresh_cache.cacheEntryPsqtConst;
const cacheEntryPsqtMut = nnue_refresh_cache.cacheEntryPsqtMut;
const cacheEntryPiecesMut = nnue_refresh_cache.cacheEntryPiecesMut;
const setCacheEntryPieceBb = nnue_refresh_cache.setCacheEntryPieceBb;

// The accumulator-stack layout + accessors live in the nnue_acc_layout leaf
// now; alias the whole foundation back so the facade + update call sites are
// unqualified (AccumulatorStack re-exported pub for external callers).
const layout = @import("nnue_acc_layout.zig");
const psq_feature = layout.psq_feature;
const threat_feature = layout.threat_feature;
const no_piece = layout.no_piece;
const sq_none = layout.sq_none;
const square_count = layout.square_count;
const psq_index_capacity = layout.psq_index_capacity;
const threat_index_capacity = layout.threat_index_capacity;
const threat_dimensions = layout.threat_dimensions;
const HalfDiff = layout.HalfDiff;
const ThreatDiffView = layout.ThreatDiffView;
pub const AccumulatorStack = layout.AccumulatorStack;
const computed_offset = layout.computed_offset;
const findLastUsable = layout.findLastUsable;
const stackSize = layout.stackSize;
const stateComputed = layout.stateComputed;
const stateBytesConst = layout.stateBytesConst;
const stateBytesMut = layout.stateBytesMut;
const positionSnapshot = layout.positionSnapshot;
const loadBridgeSnapshot = layout.loadBridgeSnapshot;
const stateAccumulationConst = layout.stateAccumulationConst;
const stateAccumulationMut = layout.stateAccumulationMut;
const statePsqtConst = layout.statePsqtConst;
const statePsqtMut = layout.statePsqtMut;
const psqDiff = layout.psqDiff;
const threatDiff = layout.threatDiff;

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
// nnue_feature.halfMakeIndex / halfAppendChanged (see the import note above); a
// direct Zig call avoids the by-value struct passing that is mis-marshaled on aarch64.
// full-threats append (changed/active) call nnue_feature directly.

pub fn evaluateSide(
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

    var removed: [psq_index_capacity]u32 = undefined;
    var added: [psq_index_capacity]u32 = undefined;
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

    var removed: [psq_index_capacity]u32 = undefined;
    var added: [psq_index_capacity]u32 = undefined;
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

    var removed: [threat_index_capacity]u32 = undefined;
    var added: [threat_index_capacity]u32 = undefined;
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

test {
    @import("std").testing.refAllDecls(@This());
}
