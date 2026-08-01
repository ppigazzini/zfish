//! Take one ply for BOTH perspectives in a single step -- upstream's
//! update_accumulator_incremental_both. Split out of nnue_acc_update.zig for the
//! god-file gate; one-way, that file imports this one.
//!
//! What is SHARED is what does not depend on the perspective: the dirty-threat records
//! and their add/remove routing, and the pawn-pair topology -- which squares changed,
//! which partners each pairs with, and in what order. What stays PER-PERSPECTIVE is the
//! orientation every index is computed under, the HalfKA indices, and the accumulator
//! arithmetic. Every list ends up holding exactly what two separate walks produced, in
//! the same order, so the evaluation is unchanged -- which is also why no value gate can
//! tell whether this step ran (see nnue_acc_update.PathCounts).

const std = @import("std");
const nnue_feature = @import("nnue_feature");

const nnue_acc_rowops = @import("nnue_acc_rowops");
const applyCombinedDelta = nnue_acc_rowops.applyCombinedDelta;
const applyCombinedPsqtDelta = nnue_acc_rowops.applyCombinedPsqtDelta;

const nnue_ft = @import("nnue_ft");
const FeatureTransformer = nnue_ft.FeatureTransformer;
const featureTransformerPsqWeights = nnue_ft.featureTransformerPsqWeights;
const featureTransformerThreatWeights = nnue_ft.featureTransformerThreatWeights;
const featureTransformerPsqPsqtWeights = nnue_ft.featureTransformerPsqPsqtWeights;
const featureTransformerThreatPsqtWeights = nnue_ft.featureTransformerThreatPsqtWeights;

const layout = @import("nnue_acc_layout.zig");
const psq_feature = layout.psq_feature;
const threat_feature = layout.threat_feature;
const white = layout.white;
const black = layout.black;
const sq_none = layout.sq_none;
const psq_index_capacity = layout.psq_index_capacity;
const threat_index_capacity = layout.threat_index_capacity;
const AccumulatorStack = layout.AccumulatorStack;
const computed_offset = layout.computed_offset;
const stateBytesConst = layout.stateBytesConst;
const stateBytesMut = layout.stateBytesMut;
const stateAccumulationConst = layout.stateAccumulationConst;
const stateAccumulationMut = layout.stateAccumulationMut;
const statePsqtConst = layout.statePsqtConst;
const statePsqtMut = layout.statePsqtMut;
const psqDiff = layout.psqDiff;
const threatDiff = layout.threatDiff;

// Route one square's HalfKA index into removed or added. Forward only -- the shared walk
// has no backward direction -- so `is_removed` reads literally.
inline fn appendHalf(removed: [*]u32, removed_len: *usize, added: [*]u32, added_len: *usize, index: u32, is_removed: bool) void {
    if (is_removed) {
        removed[removed_len.*] = index;
        removed_len.* += 1;
    } else {
        added[added_len.*] = index;
        added_len.* += 1;
    }
}

// Build one perspective's HalfKA changed-index lists from this ply's piece diff. Kept
// per-perspective exactly as upstream keeps it: only the orientation differs, but the
// index formula is cheap and sharing it would buy nothing.
fn psqChangedIndices(
    diff: layout.HalfDiff,
    perspective: u8,
    king_square: u8,
    removed: [*]u32,
    added: [*]u32,
) nnue_feature.FullAppendChangedLens {
    var removed_len: usize = 0;
    var added_len: usize = 0;
    appendHalf(removed, &removed_len, added, &added_len, nnue_feature.halfMakeIndex(.{
        .perspective = perspective,
        .square = diff.from,
        .piece = diff.pc,
        .king_square = king_square,
    }), true);
    if (diff.to != sq_none) {
        appendHalf(removed, &removed_len, added, &added_len, nnue_feature.halfMakeIndex(.{
            .perspective = perspective,
            .square = diff.to,
            .piece = diff.pc,
            .king_square = king_square,
        }), false);
    }
    if (diff.remove_sq != sq_none) {
        appendHalf(removed, &removed_len, added, &added_len, nnue_feature.halfMakeIndex(.{
            .perspective = perspective,
            .square = diff.remove_sq,
            .piece = diff.remove_pc,
            .king_square = king_square,
        }), true);
    }
    if (diff.add_sq != sq_none) {
        appendHalf(removed, &removed_len, added, &added_len, nnue_feature.halfMakeIndex(.{
            .perspective = perspective,
            .square = diff.add_sq,
            .piece = diff.add_pc,
            .king_square = king_square,
        }), false);
    }
    return .{ .removed = removed_len, .added = added_len };
}

pub fn applyCombinedBoth(
    stack: *AccumulatorStack,
    feature_transformer: *const FeatureTransformer,
    white_ksq: u8,
    black_ksq: u8,
    white_mask: u32,
    black_mask: u32,
    target_index: usize,
    computed_index: usize,
) void {
    const thr_diff = threatDiff(stateBytesConst(threat_feature, target_index, stack));

    // Decode the dirty-threat records once, index them twice.
    var w_thr_removed: [threat_index_capacity]u32 = undefined;
    var w_thr_added: [threat_index_capacity]u32 = undefined;
    var b_thr_removed: [threat_index_capacity]u32 = undefined;
    var b_thr_added: [threat_index_capacity]u32 = undefined;
    const thr = nnue_feature.fullAppendChangedBoth(
        @as([*]const u32, @ptrCast(&thr_diff.list.values))[0..thr_diff.list.size_],
        white_mask,
        black_mask,
        &w_thr_removed,
        &w_thr_added,
        &b_thr_removed,
        &b_thr_added,
    );

    // Enumerate the pawn-pair topology once, index it twice, onto the SAME lists.
    const pp = nnue_feature.ppAppendChangedBoth(
        white_ksq,
        black_ksq,
        &thr_diff.pp_before,
        &thr_diff.pp_after,
        &w_thr_removed,
        thr.w.removed,
        &w_thr_added,
        thr.w.added,
        &b_thr_removed,
        thr.b.removed,
        &b_thr_added,
        thr.b.added,
    );

    const psq_diff = psqDiff(stateBytesConst(psq_feature, target_index, stack));
    var w_psq_removed: [psq_index_capacity]u32 = undefined;
    var w_psq_added: [psq_index_capacity]u32 = undefined;
    var b_psq_removed: [psq_index_capacity]u32 = undefined;
    var b_psq_added: [psq_index_capacity]u32 = undefined;
    const w_psq = psqChangedIndices(psq_diff, white, white_ksq, &w_psq_removed, &w_psq_added);
    const b_psq = psqChangedIndices(psq_diff, black, black_ksq, &b_psq_removed, &b_psq_added);

    applySide(stack, feature_transformer, white, target_index, computed_index, w_psq_removed[0..w_psq.removed], w_psq_added[0..w_psq.added], w_thr_removed[0..pp.w.removed], w_thr_added[0..pp.w.added]);
    applySide(stack, feature_transformer, black, target_index, computed_index, b_psq_removed[0..b_psq.removed], b_psq_added[0..b_psq.added], b_thr_removed[0..pp.b.removed], b_thr_added[0..pp.b.added]);
}

fn applySide(
    stack: *AccumulatorStack,
    feature_transformer: *const FeatureTransformer,
    perspective: u8,
    target_index: usize,
    computed_index: usize,
    psq_removed: []const u32,
    psq_added: []const u32,
    thr_removed: []const u32,
    thr_added: []const u32,
) void {
    applyCombinedDelta(
        stateAccumulationMut(psq_feature, target_index, stack, perspective),
        stateAccumulationConst(psq_feature, computed_index, stack, perspective),
        psq_removed,
        psq_added,
        thr_removed,
        thr_added,
        featureTransformerPsqWeights(feature_transformer),
        featureTransformerThreatWeights(feature_transformer),
    );
    applyCombinedPsqtDelta(
        statePsqtMut(psq_feature, target_index, stack, perspective),
        statePsqtConst(psq_feature, computed_index, stack, perspective),
        psq_removed,
        psq_added,
        thr_removed,
        thr_added,
        featureTransformerPsqPsqtWeights(feature_transformer),
        featureTransformerThreatPsqtWeights(feature_transformer),
    );
    stateBytesMut(psq_feature, target_index, stack)[computed_offset + perspective] = 1;
}
