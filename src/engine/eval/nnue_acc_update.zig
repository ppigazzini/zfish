// Run the NNUE accumulator update algorithm, split out of nnue_accumulator.zig: the
// per-side refresh + incremental step machinery (evaluateSide, refreshCombined,
// applyCombined, appendHalfChange). Reads/writes accumulator states through the nnue_acc_layout accessors
// and the ft/rowops/refresh-cache/feature leaves; the facade calls evaluateSide,
// never the reverse, so this stays a one-way leaf.

const std = @import("std");
const build_options = @import("build_options");
const position_snapshot = @import("position_snapshot");
const position_types = @import("position_types");
const Position = position_types.Position;
const nnue_feature = @import("nnue_feature");

// Alias the vectorized FT weight-row add/sub kernels from the nnue_acc_rowops leaf
// so the refresh/incremental core stays unqualified.
const nnue_acc_rowops = @import("nnue_acc_rowops");
const applyRefreshFusedI16 = nnue_acc_rowops.applyRefreshFusedI16;
const applyRefreshFusedPsqt = nnue_acc_rowops.applyRefreshFusedPsqt;
const applyCombinedDelta = nnue_acc_rowops.applyCombinedDelta;
const applyCombinedPsqtDelta = nnue_acc_rowops.applyCombinedPsqtDelta;
const applyHybridDelta = nnue_acc_rowops.applyHybridDelta;
const applyHybridPsqtDelta = nnue_acc_rowops.applyHybridPsqtDelta;

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
const cacheEntryPieceBb = nnue_refresh_cache.cacheEntryPieceBb;
const setCacheEntryPieceBb = nnue_refresh_cache.setCacheEntryPieceBb;

// Alias back the accumulator-stack layout + accessors, which live in the
// nnue_acc_layout leaf now, so the facade + update call sites are unqualified
// (AccumulatorStack re-exported pub for external callers).
const nnue_acc_both = @import("nnue_acc_both.zig");
const applyCombinedBoth = nnue_acc_both.applyCombinedBoth;

const nnue_acc_entry = @import("nnue_acc_entry.zig");
const entryDiffIndices = nnue_acc_entry.entryDiffIndices;
const hybridApplicable = nnue_acc_entry.hybridApplicable;
const updateHybrid = nnue_acc_entry.updateHybrid;

const layout = @import("nnue_acc_layout.zig");
const psq_feature = layout.psq_feature;
const threat_feature = layout.threat_feature;
const white = layout.white;
const black = layout.black;
const pawn_piece_type = layout.pawn_piece_type;
const sq_none = layout.sq_none;
const no_piece = layout.no_piece;
const square_count = layout.square_count;
const psq_index_capacity = layout.psq_index_capacity;
const PsqIndex = layout.PsqIndex;
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

// Call nnue_feature.halfMakeIndex per changed square and nnue_feature directly for the
// full-threats active append; index parameters pass as an anonymous struct literal, which
// a direct Zig call marshals correctly on every ABI (see the import note above).

// Walk the stack once per perspective over the combined HalfKA + Threats accumulator --
// a direct port of upstream Stockfish's AccumulatorStack::evaluate_side. The single
// combined accumulator lives in the psq_feature storage slot (the threat_feature
// accumulation slot is now unused); find_last_usable uses ONLY the PSQ (HalfKA)
// refresh condition, because a threat refresh (king move across the center) is a
// subset of a HalfKA refresh, so the combined accumulator always refreshes together.
/// Count which route to the top slot each walk took. Every route AGREES on every
/// value they produce -- that is the whole point of them -- and it is exactly what makes
/// a dead one invisible: a route that stops running is answered correctly by the route
/// that replaces it, so the values never move and neither does the node count. The bench
/// anchor, every UCI golden, arch-determinism and the upstream node differential all stay
/// green while a whole branch is unreachable. Only a counter can see it.
///
/// Compiled in under `builtin.is_test` only, so the shipped ReleaseFast binary carries no
/// increment in the hottest function in the engine -- the branch folds away at comptime.
pub const PathCounts = struct {
    /// The last usable slot was computed: walk forward applying each ply's diff.
    forward: u64 = 0,
    /// It was not: rebuild the top slot from the board through the refresh cache.
    refresh: u64 = 0,
    /// Slots below a refreshed top, filled by walking back down.
    backward: u64 = 0,
    /// A same-half king move, taken off the previous slot instead of refreshed.
    hybrid: u64 = 0,
    /// A ply of the common suffix, taken for both perspectives in one step.
    shared: u64 = 0,
};
pub var path_counts: PathCounts = .{};

pub fn resetPathCounts() void {
    path_counts = .{};
}

inline fn countPath(comptime field: std.meta.FieldEnum(PathCounts)) void {
    if (comptime !@import("builtin").is_test) return;
    @field(path_counts, @tagName(field)) += 1;
}

/// Bring BOTH perspectives up to date -- upstream AccumulatorStack::evaluate. When
/// neither side needs a refresh the whole update is a forward walk, and above the later
/// of the two starting points the two walks visit the same plies. Catch the lagging side
/// up alone, then take that common suffix once, reading each ply's diff a single time.
pub fn evaluate(
    stack: *AccumulatorStack,
    pos: *const Position,
    feature_transformer: *const FeatureTransformer,
    cache: *RefreshCache,
) void {
    const last_white = findLastUsable(psq_feature, stack, white);
    const last_black = findLastUsable(psq_feature, stack, black);

    // The shared-suffix route walks incrementally without reaching evaluateSide, so the
    // refresh-only ablation has to skip it here as well -- gating one entry point and not
    // the other leaves the records live on this path, which the node count catches.
    if (comptime !build_options.acc_refresh_only) {
        if (stateComputed(stack, psq_feature, last_white, white) and
            stateComputed(stack, psq_feature, last_black, black))
        {
            forwardUpdateBoth(stack, pos, feature_transformer, last_white, last_black);
            return;
        }
    }
    evaluateSide(white, stack, pos, feature_transformer, cache, last_white);
    evaluateSide(black, stack, pos, feature_transformer, cache, last_black);
}

// Catch the lagging perspective up on its own, then walk the shared suffix once.
fn forwardUpdateBoth(
    stack: *AccumulatorStack,
    pos: *const Position,
    feature_transformer: *const FeatureTransformer,
    white_begin: usize,
    black_begin: usize,
) void {
    const size = stackSize(stack);
    const white_ksq = kingSquare(pos, white);
    const black_ksq = kingSquare(pos, black);
    const shared_begin = @max(white_begin, black_begin);

    const white_mask = nnue_feature.threatRouteMask(white, white_ksq, true);
    const black_mask = nnue_feature.threatRouteMask(black, black_ksq, true);

    var next = white_begin + 1;
    while (next <= shared_begin) : (next += 1) {
        countPath(.forward);
        applyCombined(stack, white, feature_transformer, white_ksq, white_mask, next, next - 1, true);
    }
    next = black_begin + 1;
    while (next <= shared_begin) : (next += 1) {
        countPath(.forward);
        applyCombined(stack, black, feature_transformer, black_ksq, black_mask, next, next - 1, true);
    }

    next = shared_begin + 1;
    while (next < size) : (next += 1) {
        countPath(.shared);
        applyCombinedBoth(stack, feature_transformer, white_ksq, black_ksq, white_mask, black_mask, next, next - 1);
    }
}

pub fn evaluateSide(
    perspective: u8,
    stack: *AccumulatorStack,
    pos: *const Position,
    feature_transformer: *const FeatureTransformer,
    cache: *RefreshCache,
    last_usable: usize,
) void {
    const size = stackSize(stack);
    const king_square = kingSquare(pos, perspective);

    // Ablation (-Dacc-refresh-only): rebuild from the board every evaluation. Bit-exact by
    // the invariant the incremental chain rests on -- a refresh and a walk compute the same
    // accumulator -- so the node count is unchanged and the two builds are the same work.
    // Measures what the incremental path is worth, and, with -Dno-threat-record, what
    // do_move's recording costs: the records are dead on this path.
    if (comptime build_options.acc_refresh_only) {
        refreshCombined(perspective, king_square, stack, pos, feature_transformer, cache);
        return;
    }

    // Build the threat route mask once per walk (it depends only on
    // perspective, king square and direction), so no per-ply step re-derives
    // the orientation.
    if (stateComputed(stack, psq_feature, last_usable, perspective)) {
        const route_mask = nnue_feature.threatRouteMask(perspective, king_square, true);
        var next = last_usable + 1;
        while (next < size) : (next += 1) {
            countPath(.forward);
            applyCombined(stack, perspective, feature_transformer, king_square, route_mask, next, next - 1, true);
        }
    } else {
        // A king move that stayed on its half of the board keeps the whole threat and
        // pawn-pair accumulation, so it can be taken incrementally off the previous slot
        // instead of refreshed from the board.
        const latest_index = size - 1;
        if (size >= 2 and hybridApplicable(stack, pos, perspective, latest_index)) {
            countPath(.hybrid);
            updateHybrid(perspective, king_square, stack, pos, feature_transformer, cache, latest_index);
            return;
        }

        countPath(.refresh);
        refreshCombined(perspective, king_square, stack, pos, feature_transformer, cache);

        const route_mask = nnue_feature.threatRouteMask(perspective, king_square, false);
        var computed_index = size - 1;
        while (computed_index > last_usable) : (computed_index -= 1) {
            countPath(.backward);
            applyCombined(stack, perspective, feature_transformer, king_square, route_mask, computed_index - 1, computed_index, false);
        }
    }
}

// Perform the fused refresh -- upstream's update_accumulator_refresh_cache: compute the
// HalfKA changed rows against the finny cache entry and the active Threat rows, then
// apply everything in ONE tiled pass. The cache entry receives the psq-only
// accumulation (in place, for next time) and the stack state receives psq + threats
// (the combined accumulator), with no second pass over the 2 KB row and no
// cache-to-state @memcpy.
fn refreshCombined(
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

    var removed: [psq_index_capacity]PsqIndex = undefined;
    var added: [psq_index_capacity]PsqIndex = undefined;
    const diff = entryDiffIndices(
        entry_pieces,
        cacheEntryPieceBb(entry_ptr),
        &pos.board,
        pos.by_type_bb[0],
        perspective,
        king_square,
        &removed,
        &added,
    );
    const removed_len = diff.removed_len;
    const added_len = diff.added_len;

    var active: nnue_feature.FullAppendResult = undefined;
    nnue_feature.fullAppendActive(&active, perspective, king_square, &pos.board, &pos.by_type_bb, &pos.by_color_bb);
    // Append the pawn-pair (PP_3Wide) active rows onto the same list -- they index the shared
    // threatAndPp weight rows, so the one tiled apply pass below covers both feature sets.
    const white_pawns = pos.by_color_bb[white] & pos.by_type_bb[pawn_piece_type];
    const black_pawns = pos.by_color_bb[black] & pos.by_type_bb[pawn_piece_type];
    nnue_feature.ppAppendActive(&active, perspective, king_square, white_pawns, black_pawns);

    // Apply the finny-cache delta and the active threat rows in one tiled pass: the
    // cache entry gets the psq-only tile stored back mid-pass, the stack state gets
    // psq + threats -- no reload of the 2 KB row a separate accumulate pass would cost.
    applyRefreshFusedI16(
        cacheEntryAccumulationMut(entry_ptr),
        stateAccumulationMut(psq_feature, latest_index, stack, perspective),
        removed[0..removed_len],
        added[0..added_len],
        active.indices[0..active.len],
        featureTransformerPsqWeights(feature_transformer),
        featureTransformerThreatWeights(feature_transformer),
    );
    applyRefreshFusedPsqt(
        cacheEntryPsqtMut(entry_ptr),
        statePsqtMut(psq_feature, latest_index, stack, perspective),
        removed[0..removed_len],
        added[0..added_len],
        active.indices[0..active.len],
        featureTransformerPsqPsqtWeights(feature_transformer),
        featureTransformerThreatPsqtWeights(feature_transformer),
    );

    @memcpy(entry_pieces, pos.board[0..]);
    setCacheEntryPieceBb(entry_ptr, pos.by_type_bb[0]);

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
    route_mask: u32,
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

    var psq_removed: [psq_index_capacity]PsqIndex = undefined;
    var psq_added: [psq_index_capacity]PsqIndex = undefined;
    var psq_removed_len: usize = 0;
    var psq_added_len: usize = 0;

    // Route each changed square's feature index straight into removed/added at its
    // routing site -- upstream append_changed_indices' shape: each diff condition is
    // tested once, with no intermediate index buffer. Same per-list order.
    appendHalfChange(&psq_removed, &psq_removed_len, &psq_added, &psq_added_len, nnue_feature.halfMakeIndex(.{
        .perspective = perspective,
        .square = psq_diff.from,
        .piece = psq_diff.pc,
        .king_square = king_square,
    }), forward);
    if (psq_diff.to != sq_none) {
        appendHalfChange(&psq_removed, &psq_removed_len, &psq_added, &psq_added_len, nnue_feature.halfMakeIndex(.{
            .perspective = perspective,
            .square = psq_diff.to,
            .piece = psq_diff.pc,
            .king_square = king_square,
        }), !forward);
    }
    if (psq_diff.remove_sq != sq_none) {
        appendHalfChange(&psq_removed, &psq_removed_len, &psq_added, &psq_added_len, nnue_feature.halfMakeIndex(.{
            .perspective = perspective,
            .square = psq_diff.remove_sq,
            .piece = psq_diff.remove_pc,
            .king_square = king_square,
        }), forward);
    }
    if (psq_diff.add_sq != sq_none) {
        appendHalfChange(&psq_removed, &psq_removed_len, &psq_added, &psq_added_len, nnue_feature.halfMakeIndex(.{
            .perspective = perspective,
            .square = psq_diff.add_sq,
            .piece = psq_diff.add_pc,
            .king_square = king_square,
        }), !forward);
    }

    // --- Threat changed-feature indices ---
    const thr_diff = if (forward)
        threatDiff(stateBytesConst(threat_feature, target_index, stack))
    else
        threatDiff(stateBytesConst(threat_feature, computed_index, stack));

    var thr_removed: [threat_index_capacity]u32 = undefined;
    var thr_added: [threat_index_capacity]u32 = undefined;

    // Route each dirty threat's feature index into removed/added as it is computed --
    // upstream append_changed_indices' `insert = add ? added : removed` shape -- with
    // the routing loop out of line exactly as upstream keeps it (see
    // fullAppendChanged for why inlining it here costs more than the call). The
    // records are single-u32 DirtyThreatRaw wrappers; pass them as the bare words.
    const thr_lens = nnue_feature.fullAppendChanged(
        @as([*]const u32, @ptrCast(&thr_diff.list.values))[0..thr_diff.list.size_],
        route_mask,
        &thr_removed,
        &thr_added,
    );

    // Append the pawn-pair (PP_3Wide) changed rows onto the SAME lists -- they index the
    // shared threatAndPp weight rows. ppAppendChanged puts appearing pairs into its "added"
    // out-list and disappearing pairs into its "removed" out-list; for a backward walk the
    // two out-lists swap (mirroring upstream's swapped append_changed_indices arguments), so
    // the appearing pairs land in thr_removed and the disappearing ones in thr_added.
    var thr_removed_len = thr_lens.removed;
    var thr_added_len = thr_lens.added;
    if (forward) {
        const pp = nnue_feature.ppAppendChanged(perspective, king_square, &thr_diff.pp_before, &thr_diff.pp_after, &thr_removed, thr_removed_len, &thr_added, thr_added_len);
        thr_removed_len = pp.removed;
        thr_added_len = pp.added;
    } else {
        const pp = nnue_feature.ppAppendChanged(perspective, king_square, &thr_diff.pp_before, &thr_diff.pp_after, &thr_added, thr_added_len, &thr_removed, thr_removed_len);
        thr_added_len = pp.removed;
        thr_removed_len = pp.added;
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
    removed: *[psq_index_capacity]PsqIndex,
    removed_len: *usize,
    added: *[psq_index_capacity]PsqIndex,
    added_len: *usize,
    index: u32,
    is_removed: bool,
) void {
    // Narrow on the store, the way upstream's ValueList<u16> converts on push_back:
    // halfMakeIndex computes in the full index space and the list holds PsqIndex.
    const narrowed: PsqIndex = @intCast(index);
    if (is_removed) {
        removed[removed_len.*] = narrowed;
        removed_len.* += 1;
    } else {
        added[added_len.*] = narrowed;
        added_len.* += 1;
    }
}

test {
    @import("std").testing.refAllDecls(@This());
}
