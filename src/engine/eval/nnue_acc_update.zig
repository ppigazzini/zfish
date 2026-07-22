// Run the NNUE accumulator update algorithm, split out of nnue_accumulator.zig: the
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

// Alias the vectorized FT weight-row add/sub kernels from the nnue_acc_rowops leaf
// so the refresh/incremental core stays unqualified.
const nnue_acc_rowops = @import("nnue_acc_rowops");
const applyAccumulatorDeltaDualStoreI16 = nnue_acc_rowops.applyAccumulatorDeltaDualStoreI16;
const accumulateRowsI8 = nnue_acc_rowops.accumulateRowsI8;
const applyPsqtDeltaDualStore = nnue_acc_rowops.applyPsqtDeltaDualStore;
const accumulatePsqtRows = nnue_acc_rowops.accumulatePsqtRows;
const applyCombinedDelta = nnue_acc_rowops.applyCombinedDelta;
const applyCombinedPsqtDelta = nnue_acc_rowops.applyCombinedPsqtDelta;

// Alias the FeatureTransformer weight-blob layout + accessors from the nnue_ft leaf
// for the refresh/apply-delta core.
const nnue_ft = @import("nnue_ft");
pub const FeatureTransformer = nnue_ft.FeatureTransformer;
const featureTransformerPsqWeights = nnue_ft.featureTransformerPsqWeights;
const featureTransformerThreatWeights = nnue_ft.featureTransformerThreatWeights;
const featureTransformerPsqPsqtWeights = nnue_ft.featureTransformerPsqPsqtWeights;
const featureTransformerThreatPsqtWeights = nnue_ft.featureTransformerThreatPsqtWeights;

// Alias the refresh cache / finny tables from the nnue_refresh_cache leaf for the
// refresh path; re-export clearRefreshCache (external).
const nnue_refresh_cache = @import("nnue_refresh_cache");
pub const RefreshCache = nnue_refresh_cache.RefreshCache;
pub const clearRefreshCache = nnue_refresh_cache.clearRefreshCache;
const cacheEntry = nnue_refresh_cache.cacheEntry;
const cacheEntryAccumulationMut = nnue_refresh_cache.cacheEntryAccumulationMut;
const cacheEntryPsqtMut = nnue_refresh_cache.cacheEntryPsqtMut;
const cacheEntryPiecesMut = nnue_refresh_cache.cacheEntryPiecesMut;

// Alias back the accumulator-stack layout + accessors, which live in the
// nnue_acc_layout leaf now, so the facade + update call sites are unqualified
// (AccumulatorStack re-exported pub for external callers).
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
const kingSquare = layout.kingSquare;
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

// Call the half-KA make-index / append-changed helpers directly as
// nnue_feature.halfMakeIndex / halfAppendChanged (see the import note above); a
// direct Zig call avoids the by-value struct passing that is mis-marshaled on aarch64.
// Call nnue_feature directly for full-threats append (changed/active).

// Walk the stack once per perspective over the combined HalfKA + Threats accumulator --
// a direct port of upstream Stockfish's AccumulatorStack::evaluate_side. The single
// combined accumulator lives in the psq_feature storage slot (the threat_feature
// accumulation slot is now unused); find_last_usable uses ONLY the PSQ (HalfKA)
// refresh condition, because a threat refresh (king move across the center) is a
// subset of a HalfKA refresh, so the combined accumulator always refreshes together.
pub fn evaluateSide(
    perspective: u8,
    stack: *AccumulatorStack,
    pos: *const Position,
    feature_transformer: *const FeatureTransformer,
    cache: *RefreshCache,
) void {
    const last_usable = findLastUsable(psq_feature, stack, perspective);
    const size = stackSize(stack);
    const king_square = kingSquare(pos, perspective);

    if (stateComputed(stack, psq_feature, last_usable, perspective)) {
        var next = last_usable + 1;
        while (next < size) : (next += 1) {
            applyCombined(stack, perspective, feature_transformer, king_square, next, next - 1, true);
        }
    } else {
        refreshCombined(perspective, king_square, stack, pos, feature_transformer, cache);

        var computed_index = size - 1;
        while (computed_index > last_usable) : (computed_index -= 1) {
            applyCombined(stack, perspective, feature_transformer, king_square, computed_index - 1, computed_index, false);
        }
    }
}

// Perform the fused refresh: PSQ (HalfKA) via the finny refresh cache fills the combined
// accumulation + psqt and sets computed; the Threat features are then ADDED on top
// (additive accumulate, no zeroing), so the combined = psq + threat -- the refresh
// half of apply_combined.
fn refreshCombined(
    perspective: u8,
    king_square: u8,
    stack: *AccumulatorStack,
    pos: *const Position,
    feature_transformer: *const FeatureTransformer,
    cache: *RefreshCache,
) void {
    refreshLatestPsq(perspective, king_square, stack, pos, feature_transformer, cache);

    const latest_index = stackSize(stack) - 1;
    var active: nnue_feature.FullAppendResult = undefined;
    nnue_feature.fullAppendActive(&active, perspective, king_square, &pos.board, &pos.by_type_bb, &pos.by_color_bb);
    accumulateRowsI8(
        stateAccumulationMut(psq_feature, latest_index, stack, perspective),
        active.indices[0..active.len],
        featureTransformerThreatWeights(feature_transformer),
    );
    accumulatePsqtRows(
        statePsqtMut(psq_feature, latest_index, stack, perspective),
        active.indices[0..active.len],
        featureTransformerThreatPsqtWeights(feature_transformer),
    );
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
    const entry_pieces = cacheEntryPiecesMut(entry_ptr);

    var removed: [psq_index_capacity]u32 = undefined;
    var added: [psq_index_capacity]u32 = undefined;
    var removed_len: usize = 0;
    var added_len: usize = 0;
    var square: usize = 0;

    // Find the changed squares upstream's way (get_changed_pieces): compare 8 squares at a
    // time as one u64 and skip a fully-unchanged chunk with a single test, instead of eight
    // per-square compares. After a refresh most of the 64 squares match the cache, so nearly
    // every chunk skips; only a chunk that holds a change falls to the per-square routing.
    // Bit-identical to the scalar scan -- the per-square logic and ascending-square order are
    // unchanged, the u64 guard only elides squares proven equal. square_count (64) is a
    // multiple of 8, so the chunk loop covers the board exactly.
    while (square < square_count) : (square += 8) {
        const old8: u64 = @bitCast(entry_pieces[square..][0..8].*);
        const new8: u64 = @bitCast(pos.board[square..][0..8].*);
        if (old8 == new8) continue;
        inline for (0..8) |k| {
            const sq = square + k;
            const old_piece = entry_pieces[sq];
            const new_piece = pos.board[sq];
            if (old_piece != new_piece) {
                if (old_piece != no_piece) {
                    removed[removed_len] = nnue_feature.halfMakeIndex(.{
                        .perspective = perspective,
                        .square = @intCast(sq),
                        .piece = old_piece,
                        .king_square = king_square,
                    });
                    removed_len += 1;
                }
                if (new_piece != no_piece) {
                    added[added_len] = nnue_feature.halfMakeIndex(.{
                        .perspective = perspective,
                        .square = @intCast(sq),
                        .piece = new_piece,
                        .king_square = king_square,
                    });
                    added_len += 1;
                }
            }
        }
    }

    // Apply the finny-cache delta and write the refreshed row into BOTH the cache entry
    // (in place, for next time) and the stack state (the copy this ply needs) in one
    // tiled pass -- upstream stores the tiled refresh straight into the accumulator, so
    // the cache-to-state copy is a register store, not a separate compiler_rt @memcpy.
    applyAccumulatorDeltaDualStoreI16(
        cacheEntryAccumulationMut(entry_ptr),
        stateAccumulationMut(psq_feature, latest_index, stack, perspective),
        removed[0..removed_len],
        added[0..added_len],
        featureTransformerPsqWeights(feature_transformer),
    );
    applyPsqtDeltaDualStore(
        cacheEntryPsqtMut(entry_ptr),
        statePsqtMut(psq_feature, latest_index, stack, perspective),
        removed[0..removed_len],
        added[0..added_len],
        featureTransformerPsqPsqtWeights(feature_transformer),
    );

    @memcpy(entry_pieces, pos.board[0..]);

    stateBytesMut(psq_feature, latest_index, stack)[computed_offset + perspective] = 1;
}

// Take one fused incremental step onto the combined accumulator -- a port of upstream's
// update_accumulator_incremental + apply_combined. Computes the PSQ (HalfKA) and
// Threat changed-feature index lists for this ply, then applies both to the single
// combined accumulation (psq_feature slot) in one load/store per tile.
fn applyCombined(
    stack: *AccumulatorStack,
    perspective: u8,
    feature_transformer: *const FeatureTransformer,
    king_square: u8,
    target_index: usize,
    computed_index: usize,
    forward: bool,
) void {
    std.debug.assert(stateComputed(stack, psq_feature, computed_index, perspective));
    std.debug.assert(!stateComputed(stack, psq_feature, target_index, perspective));

    // --- PSQ (HalfKA) changed-feature indices ---
    const psq_diff = if (forward)
        psqDiff(stateBytesConst(psq_feature, target_index, stack))
    else
        psqDiff(stateBytesConst(psq_feature, computed_index, stack));

    var psq_append: nnue_feature.HalfAppendResult = undefined;
    nnue_feature.halfAppendChanged(&psq_append, perspective, king_square, .{
        .from = psq_diff.from,
        .to = psq_diff.to,
        .pc = psq_diff.pc,
        .remove_sq = psq_diff.remove_sq,
        .add_sq = psq_diff.add_sq,
        .remove_pc = psq_diff.remove_pc,
        .add_pc = psq_diff.add_pc,
    });

    var psq_removed: [psq_index_capacity]u32 = undefined;
    var psq_added: [psq_index_capacity]u32 = undefined;
    var psq_removed_len: usize = 0;
    var psq_added_len: usize = 0;
    var cursor: usize = 0;

    appendHalfChange(&psq_removed, &psq_removed_len, &psq_added, &psq_added_len, psq_append.indices[cursor], forward);
    cursor += 1;
    if (psq_diff.to != sq_none) {
        appendHalfChange(&psq_removed, &psq_removed_len, &psq_added, &psq_added_len, psq_append.indices[cursor], !forward);
        cursor += 1;
    }
    if (psq_diff.remove_sq != sq_none) {
        appendHalfChange(&psq_removed, &psq_removed_len, &psq_added, &psq_added_len, psq_append.indices[cursor], forward);
        cursor += 1;
    }
    if (psq_diff.add_sq != sq_none) {
        appendHalfChange(&psq_removed, &psq_removed_len, &psq_added, &psq_added_len, psq_append.indices[cursor], !forward);
    }

    // --- Threat changed-feature indices ---
    const thr_diff = if (forward)
        threatDiff(stateBytesConst(threat_feature, target_index, stack))
    else
        threatDiff(stateBytesConst(threat_feature, computed_index, stack));

    var thr_append: nnue_feature.FullAppendResult = undefined;
    nnue_feature.fullAppendChanged(
        &thr_append,
        perspective,
        king_square,
        @ptrCast(&thr_diff.list.values),
        thr_diff.list.size_,
    );

    var thr_removed: [threat_index_capacity]u32 = undefined;
    var thr_added: [threat_index_capacity]u32 = undefined;
    var thr_removed_len: usize = 0;
    var thr_added_len: usize = 0;

    for (thr_append.indices[0..thr_append.len], 0..) |index, list_index| {
        if (index >= threat_dimensions) continue;
        const is_add = (thr_diff.list.values[list_index].data >> 31) != 0;
        if (is_add == forward) {
            thr_added[thr_added_len] = index;
            thr_added_len += 1;
        } else {
            thr_removed[thr_removed_len] = index;
            thr_removed_len += 1;
        }
    }

    // --- fused apply onto the ONE combined accumulator (psq_feature slot) ---
    applyCombinedDelta(
        stateAccumulationMut(psq_feature, target_index, stack, perspective),
        stateAccumulationConst(psq_feature, computed_index, stack, perspective),
        psq_removed[0..psq_removed_len],
        psq_added[0..psq_added_len],
        thr_removed[0..thr_removed_len],
        thr_added[0..thr_added_len],
        featureTransformerPsqWeights(feature_transformer),
        featureTransformerThreatWeights(feature_transformer),
    );
    applyCombinedPsqtDelta(
        statePsqtMut(psq_feature, target_index, stack, perspective),
        statePsqtConst(psq_feature, computed_index, stack, perspective),
        psq_removed[0..psq_removed_len],
        psq_added[0..psq_added_len],
        thr_removed[0..thr_removed_len],
        thr_added[0..thr_added_len],
        featureTransformerPsqPsqtWeights(feature_transformer),
        featureTransformerThreatPsqtWeights(feature_transformer),
    );
    stateBytesMut(psq_feature, target_index, stack)[computed_offset + perspective] = 1;
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

test {
    @import("std").testing.refAllDecls(@This());
}
