// Hold the two accumulator steps that start from a REFRESH-CACHE ENTRY rather than from
// the previous slot: the entry diff itself, and the hybrid king-move step built on two of
// them. Split out of nnue_acc_update.zig, which the god-file gate put over its line when
// the hybrid step landed. One-way: nnue_acc_update imports this, never the reverse.

const std = @import("std");
const position_types = @import("position_types");
const Position = position_types.Position;
const nnue_feature = @import("nnue_feature");

const nnue_acc_rowops = @import("nnue_acc_rowops");
const applyHybridDelta = nnue_acc_rowops.applyHybridDelta;
const applyHybridPsqtDelta = nnue_acc_rowops.applyHybridPsqtDelta;

const nnue_ft = @import("nnue_ft");
const FeatureTransformer = nnue_ft.FeatureTransformer;
const featureTransformerPsqWeights = nnue_ft.featureTransformerPsqWeights;
const featureTransformerThreatWeights = nnue_ft.featureTransformerThreatWeights;
const featureTransformerPsqPsqtWeights = nnue_ft.featureTransformerPsqPsqtWeights;
const featureTransformerThreatPsqtWeights = nnue_ft.featureTransformerThreatPsqtWeights;

const nnue_refresh_cache = @import("nnue_refresh_cache");
const RefreshCache = nnue_refresh_cache.RefreshCache;
const cacheEntry = nnue_refresh_cache.cacheEntry;
const cacheEntryAccumulationMut = nnue_refresh_cache.cacheEntryAccumulationMut;
const cacheEntryPsqtMut = nnue_refresh_cache.cacheEntryPsqtMut;
const cacheEntryPiecesMut = nnue_refresh_cache.cacheEntryPiecesMut;
const cacheEntryPieceBb = nnue_refresh_cache.cacheEntryPieceBb;
const setCacheEntryPieceBb = nnue_refresh_cache.setCacheEntryPieceBb;

const layout = @import("nnue_acc_layout.zig");
const psq_feature = layout.psq_feature;
const threat_feature = layout.threat_feature;
const sq_none = layout.sq_none;
const no_piece = layout.no_piece;
const psq_index_capacity = layout.psq_index_capacity;
const PsqIndex = layout.PsqIndex;
const threat_index_capacity = layout.threat_index_capacity;
const AccumulatorStack = layout.AccumulatorStack;
const computed_offset = layout.computed_offset;
const stateComputed = layout.stateComputed;
const stateBytesConst = layout.stateBytesConst;
const stateBytesMut = layout.stateBytesMut;
const stateAccumulationConst = layout.stateAccumulationConst;
const stateAccumulationMut = layout.stateAccumulationMut;
const statePsqtConst = layout.statePsqtConst;
const statePsqtMut = layout.statePsqtMut;
const psqDiff = layout.psqDiff;
const threatDiff = layout.threatDiff;

// Diff a refresh-cache entry against a board and write the HalfKA removed/added index
// lists -- the first half of upstream's update_accumulator_refresh_cache, split out
// because update_accumulator_hybrid needs the SAME diff twice, against two different
// (entry, board) pairs, and neither of them is `pos` for the old bucket.
pub fn entryDiffIndices(
    entry_pieces: []const u8,
    entry_piece_bb: u64,
    board: *const [64]u8,
    board_piece_bb: u64,
    perspective: u8,
    king_square: u8,
    removed: *[psq_index_capacity]PsqIndex,
    added: *[psq_index_capacity]PsqIndex,
) struct { removed_len: usize, added_len: usize } {
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
        const new_v: @Vector(32, u8) = board[off..][0..32].*;
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
    const removed_bb = changed_bb & entry_piece_bb;
    const added_bb = changed_bb & board_piece_bb;
    var removed_len: usize = 0;
    var added_len: usize = 0;
    if (comptime nnue_feature.use_avx512_nnue_feature) {
        const result = nnue_feature.writeIndicesAvx512(
            entry_pieces,
            board,
            removed_bb,
            added_bb,
            perspective,
            king_square,
            removed,
            added,
        );
        removed_len = result.removed_len;
        added_len = result.added_len;
    } else {
        var removed_scan = removed_bb;
        var added_scan = added_bb;
        while (removed_scan != 0) : (removed_scan &= removed_scan - 1) {
            const sq: u8 = @intCast(@ctz(removed_scan));
            removed[removed_len] = @intCast(nnue_feature.halfMakeIndex(.{
                .perspective = perspective,
                .square = sq,
                .piece = entry_pieces[sq],
                .king_square = king_square,
            }));
            removed_len += 1;
        }
        while (added_scan != 0) : (added_scan &= added_scan - 1) {
            const sq: u8 = @intCast(@ctz(added_scan));
            added[added_len] = @intCast(nnue_feature.halfMakeIndex(.{
                .perspective = perspective,
                .square = sq,
                .piece = board[sq],
                .king_square = king_square,
            }));
            added_len += 1;
        }
    }
    return .{ .removed_len = removed_len, .added_len = added_len };
}

// State upstream's five conditions for the hybrid step in one predicate
// (nnue_accumulator.cpp, evaluate_side). Each one is load-bearing:
//   * the moved piece is THIS perspective's king -- otherwise nothing rebuckets;
//   * the slot below is computed for this perspective -- the step reads it as `computed`;
//   * at least MIN_PC_COUNT_HYBRID pieces -- below that, summing the threat/pair features
//     from scratch is cheaper than reconstructing the source bucket;
//   * the king stayed on its half, i.e. bit 2 of from and to agree -- crossing the centre
//     file re-orients every threat and pair index, which is what the step keeps;
//   * no add_sq, which excludes castling, because that relocates a rook as well.
pub fn hybridApplicable(stack: *const AccumulatorStack, pos: *const Position, perspective: u8, latest_index: usize) bool {
    const min_pc_count_hybrid: u32 = 15;
    const diff = psqDiff(stateBytesConst(psq_feature, latest_index, stack));
    if (diff.pc != layout.kingPiece(perspective)) return false;
    if (!stateComputed(stack, psq_feature, latest_index - 1, perspective)) return false;
    if (@popCount(pos.by_type_bb[0]) < min_pc_count_hybrid) return false;
    if ((diff.from & 0b100) != (diff.to & 0b100)) return false;
    if (diff.add_sq != sq_none) return false;
    return true;
}

// Take a same-half king move incrementally -- upstream's update_accumulator_hybrid.
//
//   target = computed - <old-bucket HalfKA> + <new-bucket HalfKA> + <this ply's thr/pp delta>
//
// Both HalfKA buckets come from the refresh cache. The OLD bucket's board is the position
// BEFORE the move, which does not exist anywhere: reconstruct it by undoing the king move
// on a copy of the piece array. That copy is the only board this file builds rather than
// reads, and it is why the step is bounded by a piece count -- on a sparse board, summing
// the threat/pair features outright beats reconstructing the source bucket.
pub fn updateHybrid(
    perspective: u8,
    king_square: u8,
    stack: *AccumulatorStack,
    pos: *const Position,
    feature_transformer: *const FeatureTransformer,
    cache: *RefreshCache,
    latest_index: usize,
) void {
    const diff = psqDiff(stateBytesConst(psq_feature, latest_index, stack));
    const old_ksq = diff.from;
    const new_ksq = diff.to;
    std.debug.assert(old_ksq != new_ksq);
    std.debug.assert(new_ksq == king_square);

    // Rebuild the pre-move board. The king now stands on `to`; put back whatever `to` held
    // (a captured piece, or nothing) and restore the king to `from`.
    var previous_pieces: [64]u8 align(64) = pos.board;
    var previous_piece_bb = pos.by_type_bb[0];
    // Upstream's own assertions on the reconstruction, and they state what it assumes: the
    // king really is on `to` now, and `from` really is empty. Free in ReleaseFast.
    std.debug.assert(previous_pieces[new_ksq] == diff.pc);
    if (diff.remove_sq != sq_none) {
        std.debug.assert(diff.remove_sq == new_ksq);
        previous_pieces[new_ksq] = diff.remove_pc;
    } else {
        previous_pieces[new_ksq] = no_piece;
        previous_piece_bb &= ~(@as(u64, 1) << @intCast(new_ksq));
    }
    std.debug.assert(previous_pieces[old_ksq] == no_piece);
    previous_pieces[old_ksq] = diff.pc;
    previous_piece_bb |= @as(u64, 1) << @intCast(old_ksq);

    const old_entry_ptr = cacheEntry(cache, old_ksq, perspective);
    const new_entry_ptr = cacheEntry(cache, new_ksq, perspective);

    // "Removed" is what must come OUT of the cache entry, "added" what must go IN, to turn
    // that entry into the accumulator we want -- for each bucket against its own board.
    var old_removed: [psq_index_capacity]PsqIndex = undefined;
    var old_added: [psq_index_capacity]PsqIndex = undefined;
    const old_diff = entryDiffIndices(
        cacheEntryPiecesMut(old_entry_ptr),
        cacheEntryPieceBb(old_entry_ptr),
        &previous_pieces,
        previous_piece_bb,
        perspective,
        old_ksq,
        &old_removed,
        &old_added,
    );

    var new_removed: [psq_index_capacity]PsqIndex = undefined;
    var new_added: [psq_index_capacity]PsqIndex = undefined;
    const new_diff = entryDiffIndices(
        cacheEntryPiecesMut(new_entry_ptr),
        cacheEntryPieceBb(new_entry_ptr),
        &pos.board,
        pos.by_type_bb[0],
        perspective,
        new_ksq,
        &new_removed,
        &new_added,
    );

    // This ply's threat + pawn-pair change, oriented at the NEW king square, forward.
    const thr_diff = threatDiff(stateBytesConst(threat_feature, latest_index, stack));
    const route_mask = nnue_feature.threatRouteMask(perspective, new_ksq, true);
    var thr_removed: [threat_index_capacity]u32 = undefined;
    var thr_added: [threat_index_capacity]u32 = undefined;
    const thr_lens = nnue_feature.fullAppendChanged(
        @as([*]const u32, @ptrCast(&thr_diff.list.values))[0..thr_diff.list.size_],
        route_mask,
        &thr_removed,
        &thr_added,
    );
    const pp = nnue_feature.ppAppendChanged(perspective, new_ksq, &thr_diff.pp_before, &thr_diff.pp_after, &thr_removed, thr_lens.removed, &thr_added, thr_lens.added);

    applyHybridDelta(
        stateAccumulationMut(psq_feature, latest_index, stack, perspective),
        stateAccumulationConst(psq_feature, latest_index - 1, stack, perspective),
        cacheEntryAccumulationMut(new_entry_ptr),
        cacheEntryAccumulationMut(old_entry_ptr),
        new_removed[0..new_diff.removed_len],
        new_added[0..new_diff.added_len],
        old_removed[0..old_diff.removed_len],
        old_added[0..old_diff.added_len],
        thr_removed[0..pp.removed],
        thr_added[0..pp.added],
        featureTransformerPsqWeights(feature_transformer),
        featureTransformerThreatWeights(feature_transformer),
    );
    applyHybridPsqtDelta(
        statePsqtMut(psq_feature, latest_index, stack, perspective),
        statePsqtConst(psq_feature, latest_index - 1, stack, perspective),
        cacheEntryPsqtMut(new_entry_ptr),
        cacheEntryPsqtMut(old_entry_ptr),
        new_removed[0..new_diff.removed_len],
        new_added[0..new_diff.added_len],
        old_removed[0..old_diff.removed_len],
        old_added[0..old_diff.added_len],
        thr_removed[0..pp.removed],
        thr_added[0..pp.added],
        featureTransformerPsqPsqtWeights(feature_transformer),
        featureTransformerThreatPsqtWeights(feature_transformer),
    );

    // Only the DESTINATION entry was refreshed in place; the source entry is untouched.
    @memcpy(cacheEntryPiecesMut(new_entry_ptr), pos.board[0..]);
    setCacheEntryPieceBb(new_entry_ptr, pos.by_type_bb[0]);

    stateBytesMut(psq_feature, latest_index, stack)[computed_offset + perspective] = 1;
}
