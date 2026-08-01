//! Own the PP_3Wide (pawn-pair) feature set -- upstream Features::PP_3Wide. Every pair of
//! pawns on the same or an adjacent file (ranks 2-7) is one feature. Its indices are
//! concatenated onto the threats -- base pp_index_base -- so they share the threatAndPp
//! weight rows and merge into the same removed/added/active index lists the threat kernels
//! consume.
//!
//! Split out of nnue_feature.zig, which the god-file gate put over its line when the
//! both-perspectives producer landed. One feature set per file; nnue_feature re-exports
//! this surface, so no caller moved.

const nnue_feature_bb = @import("nnue_feature_bb.zig");
const squareBb = nnue_feature_bb.squareBb;

const luts = @import("nnue_feature_luts.zig");
const orient_tbl_full = luts.orient_tbl_full;
const pp_index_base = luts.pp_index_base;
const pawn_pair_bb = luts.pawn_pair_bb;
const white = luts.white;
const black = luts.black;
const sq_a2 = luts.sq_a2;
pub const FullAppendResult = luts.FullAppendResult;
pub const FullAppendChangedLens = luts.FullAppendChangedLens;

// make_pawn_id: 48*color + (square - SQ_A2). Pawns live on the 48 squares of ranks 2-7.
fn makePawnId(color: u32, square: u32) u32 {
    return 48 * color + square - @as(u32, sq_a2);
}

// PP_3Wide::make_index -- the triangular index of the unordered pawn-id pair, plus the base.
pub fn ppMakeIndex(perspective: u8, color: u8, from: u8, to: u8, paired_color: u8, king_square: u8) u32 {
    const orientation: u8 = @as(u8, @bitCast(orient_tbl_full[king_square])) ^ (56 *% @as(u8, perspective));
    const from_o: u32 = @as(u32, from ^ orientation);
    const to_o: u32 = @as(u32, to ^ orientation);
    const color_o: u32 = color ^ perspective;
    const paired_o: u32 = paired_color ^ perspective;
    const id_a = makePawnId(color_o, from_o);
    const id_b = makePawnId(paired_o, to_o);
    const hi = @max(id_a, id_b);
    const lo = @min(id_a, id_b);
    return hi * (hi - 1) / 2 + lo + pp_index_base;
}

// PP_3Wide::append_active_indices -- every pawn pair, once, into the shared active list.
pub fn ppAppendActive(result: *FullAppendResult, perspective: u8, king_square: u8, white_pawns: u64, black_pawns: u64) void {
    var bb = white_pawns;
    while (bb != 0) {
        const from: u8 = @intCast(@ctz(bb));
        bb &= bb - 1;
        const band = pawn_pair_bb[from];
        var ww = band & bb; // remaining white pawns -> each white-white pair once
        while (ww != 0) {
            const to: u8 = @intCast(@ctz(ww));
            ww &= ww - 1;
            result.indices[result.len] = ppMakeIndex(perspective, white, from, to, white, king_square);
            result.len += 1;
        }
        var wb = band & black_pawns;
        while (wb != 0) {
            const to: u8 = @intCast(@ctz(wb));
            wb &= wb - 1;
            result.indices[result.len] = ppMakeIndex(perspective, white, from, to, black, king_square);
            result.len += 1;
        }
    }
    bb = black_pawns;
    while (bb != 0) {
        const from: u8 = @intCast(@ctz(bb));
        bb &= bb - 1;
        const band = pawn_pair_bb[from];
        var bk = band & bb; // remaining black pawns -> each black-black pair once
        while (bk != 0) {
            const to: u8 = @intCast(@ctz(bk));
            bk &= bk - 1;
            result.indices[result.len] = ppMakeIndex(perspective, black, from, to, black, king_square);
            result.len += 1;
        }
    }
}

// The generate() lambda from PP_3Wide::append_changed_indices (non-AVX512 path): emit every
// pair touching a changed pawn -- partners drawn from the unchanged pawns plus the not-yet-
// processed changed pawns (so an updated-updated pair is emitted exactly once).
fn ppGenerate(perspective: u8, king_square: u8, updated_w: u64, updated_b: u64, pawns_w: u64, pawns_b: u64, out: [*]u32, len_in: usize) usize {
    var len = len_in;
    const unchanged = (pawns_w | pawns_b) & ~(updated_w | updated_b);
    var u = updated_w | updated_b;
    while (u != 0) {
        const a: u8 = @intCast(@ctz(u));
        u &= u - 1;
        const mask = pawn_pair_bb[a] & (unchanged | u);
        const a_col: u8 = if ((pawns_b & squareBb(a)) != 0) black else white;
        var pb = pawns_b & mask;
        while (pb != 0) {
            const to: u8 = @intCast(@ctz(pb));
            pb &= pb - 1;
            out[len] = ppMakeIndex(perspective, a_col, a, to, black, king_square);
            len += 1;
        }
        var pw = pawns_w & mask;
        while (pw != 0) {
            const to: u8 = @intCast(@ctz(pw));
            pw &= pw - 1;
            out[len] = ppMakeIndex(perspective, a_col, a, to, white, king_square);
            len += 1;
        }
    }
    return len;
}

// PP_3Wide::append_changed_indices -- append the pawn-pair delta onto the SAME removed/added
// lists the threat delta already filled (both index the shared threatAndPp weight rows).
// added <- pairs that appear (after&~before, drawn against the after pawns);
// removed <- pairs that disappear (before&~after, against the before pawns). The caller
// swaps the two out-lists for a backward walk, exactly as upstream swaps the arguments.
pub fn ppAppendChanged(
    perspective: u8,
    king_square: u8,
    before: *const [2]u64,
    after: *const [2]u64,
    removed_out: [*]u32,
    removed_len_in: usize,
    added_out: [*]u32,
    added_len_in: usize,
) FullAppendChangedLens {
    const white_before = before[white];
    const black_before = before[black];
    const white_after = after[white];
    const black_after = after[black];
    if (white_before == white_after and black_before == black_after)
        return .{ .removed = removed_len_in, .added = added_len_in };

    const added_len = ppGenerate(perspective, king_square, white_after & ~white_before, black_after & ~black_before, white_after, black_after, added_out, added_len_in);
    const removed_len = ppGenerate(perspective, king_square, white_before & ~white_after, black_before & ~black_after, white_before, black_before, removed_out, removed_len_in);
    return .{ .removed = removed_len, .added = added_len };
}

/// Enumerate the pawn-pair topology ONCE and index it for both perspectives --
/// PP_3Wide::append_changed_indices_both's non-AVX512 arm. Which squares changed, which
/// partners each pairs with, and in what order are all perspective-INDEPENDENT; only
/// ppMakeIndex's orientation is not. So walk the bitboards once and push two indices per
/// partner, which is what keeps each list in the order its own separate walk produced.
fn ppGenerateBoth(
    white_ksq: u8,
    black_ksq: u8,
    updated_w: u64,
    updated_b: u64,
    pawns_w: u64,
    pawns_b: u64,
    w_out: [*]u32,
    w_len_in: usize,
    b_out: [*]u32,
    b_len_in: usize,
) struct { w: usize, b: usize } {
    var w_len = w_len_in;
    var b_len = b_len_in;
    const unchanged = (pawns_w | pawns_b) & ~(updated_w | updated_b);
    var u = updated_w | updated_b;
    while (u != 0) {
        const a: u8 = @intCast(@ctz(u));
        u &= u - 1;
        const mask = pawn_pair_bb[a] & (unchanged | u);
        const a_col: u8 = if ((pawns_b & squareBb(a)) != 0) black else white;
        var pb = pawns_b & mask;
        while (pb != 0) {
            const to: u8 = @intCast(@ctz(pb));
            pb &= pb - 1;
            w_out[w_len] = ppMakeIndex(white, a_col, a, to, black, white_ksq);
            w_len += 1;
            b_out[b_len] = ppMakeIndex(black, a_col, a, to, black, black_ksq);
            b_len += 1;
        }
        var pw = pawns_w & mask;
        while (pw != 0) {
            const to: u8 = @intCast(@ctz(pw));
            pw &= pw - 1;
            w_out[w_len] = ppMakeIndex(white, a_col, a, to, white, white_ksq);
            w_len += 1;
            b_out[b_len] = ppMakeIndex(black, a_col, a, to, white, black_ksq);
            b_len += 1;
        }
    }
    return .{ .w = w_len, .b = b_len };
}

/// The both-perspectives form of ppAppendChanged. FORWARD ONLY: the shared walk runs only
/// in the forward direction, so appearing pairs always land in `added` and disappearing
/// ones in `removed` for both sides, and there is no out-list swap to make.
pub fn ppAppendChangedBoth(
    white_ksq: u8,
    black_ksq: u8,
    before: *const [2]u64,
    after: *const [2]u64,
    w_removed_out: [*]u32,
    w_removed_len_in: usize,
    w_added_out: [*]u32,
    w_added_len_in: usize,
    b_removed_out: [*]u32,
    b_removed_len_in: usize,
    b_added_out: [*]u32,
    b_added_len_in: usize,
) struct { w: FullAppendChangedLens, b: FullAppendChangedLens } {
    const white_before = before[white];
    const black_before = before[black];
    const white_after = after[white];
    const black_after = after[black];
    if (white_before == white_after and black_before == black_after)
        return .{
            .w = .{ .removed = w_removed_len_in, .added = w_added_len_in },
            .b = .{ .removed = b_removed_len_in, .added = b_added_len_in },
        };

    const add = ppGenerateBoth(white_ksq, black_ksq, white_after & ~white_before, black_after & ~black_before, white_after, black_after, w_added_out, w_added_len_in, b_added_out, b_added_len_in);
    const rem = ppGenerateBoth(white_ksq, black_ksq, white_before & ~white_after, black_before & ~black_after, white_before, black_before, w_removed_out, w_removed_len_in, b_removed_out, b_removed_len_in);
    return .{
        .w = .{ .removed = rem.w, .added = add.w },
        .b = .{ .removed = rem.b, .added = add.b },
    };
}
