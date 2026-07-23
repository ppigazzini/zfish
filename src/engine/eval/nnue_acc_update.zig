// Run the NNUE accumulator update algorithm, split out of nnue_accumulator.zig: the
// per-side refresh + incremental step machinery (evaluateSide, refreshCombined,
// applyCombined, appendHalfChange). Reads/writes accumulator states through the nnue_acc_layout accessors
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
const applyRefreshFusedI16 = nnue_acc_rowops.applyRefreshFusedI16;
const applyRefreshFusedPsqt = nnue_acc_rowops.applyRefreshFusedPsqt;
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
const cacheEntryPieceBb = nnue_refresh_cache.cacheEntryPieceBb;
const setCacheEntryPieceBb = nnue_refresh_cache.setCacheEntryPieceBb;

// Alias back the accumulator-stack layout + accessors, which live in the
// nnue_acc_layout leaf now, so the facade + update call sites are unqualified
// (AccumulatorStack re-exported pub for external callers).
const layout = @import("nnue_acc_layout.zig");
const psq_feature = layout.psq_feature;
const threat_feature = layout.threat_feature;
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

// Call nnue_feature.halfMakeIndex per changed square and nnue_feature directly for the
// full-threats active append; index parameters pass as an anonymous struct literal, which
// a direct Zig call marshals correctly on every ABI (see the import note above).

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

    // Build the threat route mask once per walk (it depends only on
    // perspective, king square and direction), so no per-ply step re-derives
    // the orientation.
    if (stateComputed(stack, psq_feature, last_usable, perspective)) {
        const route_mask = nnue_feature.threatRouteMask(perspective, king_square, true);
        var next = last_usable + 1;
        while (next < size) : (next += 1) {
            applyCombined(stack, perspective, feature_transformer, king_square, route_mask, next, next - 1, true);
        }
    } else {
        refreshCombined(perspective, king_square, stack, pos, feature_transformer, cache);

        const route_mask = nnue_feature.threatRouteMask(perspective, king_square, false);
        var computed_index = size - 1;
        while (computed_index > last_usable) : (computed_index -= 1) {
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

    var removed: [psq_index_capacity]u32 = undefined;
    var added: [psq_index_capacity]u32 = undefined;
    var removed_len: usize = 0;
    var added_len: usize = 0;

    // Build the changed-square bitboard upstream's way (get_changed_pieces): compare 32
    // board bytes at a time against the cached pieces, movemask each compare into 32 mask
    // bits, and OR the two halves into one u64 -- no per-square loop touches an unchanged
    // square. On x86 the <32 x i1> compare result maps to pmovmskb, so bitcasting it to
    // u32 IS the movemask (lane i -> bit i); other backends keep the defined-ops
    // @select + @reduce form (vector memory layout is target-defined -- see the nnz mask
    // note in nnue_accumulator.zig).
    var changed_bb: u64 = 0;
    inline for (0..2) |chunk| {
        const off = chunk * 32;
        const old_v: @Vector(32, u8) = entry_pieces[off..][0..32].*;
        const new_v: @Vector(32, u8) = pos.board[off..][0..32].*;
        const differs = old_v != new_v;
        const mask: u32 = if (comptime @import("builtin").cpu.arch == .x86_64)
            @bitCast(differs)
        else blk: {
            const lane_bits: @Vector(32, u32) = comptime bits: {
                var w: [32]u32 = undefined;
                for (&w, 0..) |*bit, i| bit.* = @as(u32, 1) << @intCast(i);
                break :bits w;
            };
            break :blk @reduce(.Or, @select(u32, differs, lane_bits, @as(@Vector(32, u32), @splat(0))));
        };
        changed_bb |= @as(u64, mask) << (chunk * 32);
    }

    // Split changed into removed/added by occupancy -- upstream's
    // `removedBB = changedBB & entry.pieceBB` / `addedBB = changedBB & pos.pieces()` --
    // then pop only the set bits: no piece-vs-no_piece branch per square, and a square
    // whose piece changed type or color lands in both lists. Each pop_lsb loop visits
    // squares in ascending order, so both lists match the retired per-square scan
    // byte-for-byte.
    var removed_bb = changed_bb & cacheEntryPieceBb(entry_ptr);
    var added_bb = changed_bb & pos.by_type_bb[0];
    while (removed_bb != 0) : (removed_bb &= removed_bb - 1) {
        const sq: u8 = @intCast(@ctz(removed_bb));
        removed[removed_len] = nnue_feature.halfMakeIndex(.{
            .perspective = perspective,
            .square = sq,
            .piece = entry_pieces[sq],
            .king_square = king_square,
        });
        removed_len += 1;
    }
    while (added_bb != 0) : (added_bb &= added_bb - 1) {
        const sq: u8 = @intCast(@ctz(added_bb));
        added[added_len] = nnue_feature.halfMakeIndex(.{
            .perspective = perspective,
            .square = sq,
            .piece = pos.board[sq],
            .king_square = king_square,
        });
        added_len += 1;
    }

    var active: nnue_feature.FullAppendResult = undefined;
    nnue_feature.fullAppendActive(&active, perspective, king_square, &pos.board, &pos.by_type_bb, &pos.by_color_bb);

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

    var psq_removed: [psq_index_capacity]u32 = undefined;
    var psq_added: [psq_index_capacity]u32 = undefined;
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
    const thr_removed_len = thr_lens.removed;
    const thr_added_len = thr_lens.added;

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
