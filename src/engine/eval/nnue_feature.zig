const std = @import("std");

// Alias back the pure bitboard-math helpers, which live in a std-only leaf now
// (Zig top-level decls are order-independent, so callers above are unaffected).
const nnue_feature_bb = @import("nnue_feature_bb.zig");
const makePiece = nnue_feature_bb.makePiece;
const shift = nnue_feature_bb.shift;
const attacksBb = nnue_feature_bb.attacksBb;
const popLsb = nnue_feature_bb.popLsb;
const squareBb = nnue_feature_bb.squareBb;

comptime {
    @setEvalBranchQuota(200000);
}

pub const HalfDiff = struct {
    from: u8,
    to: u8,
    pc: u8,
    remove_sq: u8,
    add_sq: u8,
    remove_pc: u8,
    add_pc: u8,
};

pub const DirtyThreatRaw = struct {
    data: u32,
};

pub const FullDiff = struct {
    us: u8,
    prev_ksq: u8,
    ksq: u8,
};

pub const FullAppendResult = struct {
    len: usize,
    // Holds threats AND pawn-pair active indices for one perspective's refresh (both feed
    // the shared threatAndPp weight rows). Upstream's IndexList is ValueList<u16, 256>.
    indices: [256]u32,
};

pub const HalfThreatParams = struct {
    perspective: u8,
    square: u8,
    piece: u8,
    king_square: u8,
};

pub const FullThreatParams = struct {
    perspective: u8,
    attacker: u8,
    from_sq: u8,
    to_sq: u8,
    attacked: u8,
    king_square: u8,
};

pub fn halfMakeIndex(params: HalfThreatParams) u32 {
    const flip: u32 = 56 * params.perspective;
    return (@as(u32, params.square) ^ orient_tbl_half[params.king_square] ^ flip) + piece_square_index[params.perspective][params.piece] + king_buckets[params.king_square ^ params.perspective * 56];
}

pub fn halfRequiresRefresh(diff: HalfDiff, perspective: u8) bool {
    return diff.pc == makePiece(perspective, king_piece_type);
}

pub fn fullMakeIndex(params: FullThreatParams) u32 {
    const orientation: i32 = @as(i32, orient_tbl_full[params.king_square]) ^ @as(i32, 56 * params.perspective);
    const from_oriented: usize = @intCast(@as(u8, params.from_sq) ^ @as(u8, @intCast(orientation)));
    const to_oriented: usize = @intCast(@as(u8, params.to_sq) ^ @as(u8, @intCast(orientation)));
    const swap: u8 = 8 * params.perspective;
    const attacker_oriented: usize = params.attacker ^ swap;
    const attacked_oriented: usize = params.attacked ^ swap;
    const less: usize = @intFromBool(from_oriented < to_oriented);
    const block = &threat_route_blocks[attacker_oriented];
    return block.lut1[attacked_oriented * 2 + less] + block.comb[from_oriented * 64 + to_oriented];
}

pub const FullAppendChangedLens = struct {
    removed: usize,
    added: usize,
};

/// Build the mask that orients a whole dirty-threat record in ONE xor: every
/// oriented operand of fullMakeIndex is a per-field xor whose field never
/// crosses its byte lane -- from^orientation (bits 0-7), to^orientation
/// (8-15), attacked^swap (16-19), attacker^swap (20-23) -- so broadcasting
/// orientation and swap onto their field offsets folds the per-entry work to
/// `record ^ mask`. Bit 31 carries the routing polarity: xor it with !forward
/// so a set sign bit always means "append to added" (upstream
/// append_changed_indices' `insert = add ? added : removed` becomes one sign
/// test). The mask is per (perspective, king square, direction) -- invariant
/// across one evaluateSide walk -- so the caller builds it once per walk, not
/// per ply.
pub fn threatRouteMask(perspective: u8, king_square: u8, forward: bool) u32 {
    const orientation: u32 = @as(u8, @bitCast(orient_tbl_full[king_square])) ^ (56 * @as(u32, perspective));
    const swap: u32 = 8 * @as(u32, perspective);
    return orientation * 0x0101 | (swap << 16) | (swap << 20) |
        (if (forward) 0 else @as(u32, 0x8000_0000));
}

/// Route one ply's dirty-threat records into removed/added feature-index lists
/// -- upstream FullThreats::append_changed_indices, and like upstream's it
/// stays OUT of line: inlining this loop into the caller's SIMD apply pass
/// measurably re-shuffles the whole function's register allocation (+35.6 M
/// no-line-info glue Ir at d11), costing more than the call.
///
/// Tables, sum and walk order match the decode-then-index form exactly (see
/// threatRouteMask for the one-xor orientation), so both output lists are
/// byte-identical to it.
pub noinline fn fullAppendChanged(
    values: []const u32,
    route_mask: u32,
    removed_out: [*]u32,
    added_out: [*]u32,
) FullAppendChangedLens {
    const mask = route_mask;
    var removed_len: usize = 0;
    var added_len: usize = 0;
    for (values) |raw| {
        const x = raw ^ mask;
        const attacker: usize = (x >> 20) & 0xf;
        // Read the attacked field pre-doubled -- shift one bit less and mask
        // the low bit away -- so [attacked2 + less] indexes index_lut1's
        // flattened [16][2]u32 rows without a separate scale.
        const attacked2: usize = (x >> 15) & 0x1e;
        const from: usize = x & 0xff;
        const to: usize = (x >> 8) & 0xff;
        const less: usize = @intFromBool(from < to);
        const block = &threat_route_blocks[attacker];
        const index = block.lut1[attacked2 + less] + block.comb[(from << 6) | to];
        if (index >= full_dimensions) continue;
        if ((x >> 31) != 0) {
            added_out[added_len] = index;
            added_len += 1;
        } else {
            removed_out[removed_len] = index;
            removed_len += 1;
        }
    }
    return .{ .removed = removed_len, .added = added_len };
}

pub fn fullAppendActive(
    result: *FullAppendResult,
    perspective: u8,
    king_square: u8,
    piece_array: [*]const u8,
    by_type: *const [8]u64,
    by_color: *const [2]u64,
) void {
    // Read the Position's cached bitboards instead of rebuilding ~10 of them with 64-square
    // board[] scans on every refresh: the nnue piece/square encoding matches the engine's, so
    // all-pieces == by_type[0], all-pawns == by_type[PAWN], and (color,type) sets ==
    // by_color[color] & by_type[type]. board[] is still read for the per-target attacked piece.
    const pieces = piece_array[0..square_count];
    const occupied = by_type[0];
    const pawns = by_type[pawn_piece_type];

    // Restrict each attacker's targets to the piece types its full_map row can
    // ever index in range -- upstream append_active_indices' pawnTargets /
    // minorSliderTargets / queenTargets -- so no fullMakeIndex call is spent on
    // a target the `< full_dimensions` filter would discard (kings are never
    // targets; pawns now threaten only knights and rooks -- pawn-pawn pairs moved
    // to the PP_3Wide feature set; bishops and rooks never threaten queens). The
    // filter still catches the pair-specific exclusions.
    const pawn_targets = by_type[knight_piece_type] | by_type[rook_piece_type];
    const minor_slider_targets = pawns | by_type[knight_piece_type] | by_type[bishop_piece_type] | by_type[rook_piece_type];
    const queen_targets = minor_slider_targets | by_type[queen_piece_type];

    result.len = 0;
    var color_index: u8 = 0;

    while (color_index < 2) : (color_index += 1) {
        const color = perspective ^ color_index;
        appendActivePawnThreats(result, pieces, pawn_targets, by_color[color] & pawns, perspective, color, king_square);

        // Unroll the piece types at comptime so each attacksBb call resolves to its own
        // attack kernel directly -- the runtime-typed form dispatched through a jump
        // table once per attacker, an indirect branch the predictor keeps missing.
        inline for ([_]u8{ knight_piece_type, bishop_piece_type, rook_piece_type, queen_piece_type }) |piece_type| {
            const attacker = makePiece(color, piece_type);
            const targets = if (piece_type == knight_piece_type or piece_type == queen_piece_type) queen_targets else minor_slider_targets;
            var attackers = by_color[color] & by_type[piece_type];
            while (attackers != 0) {
                const from = popLsb(&attackers);
                var attacks = attacksBb(piece_type, from, occupied) & targets;
                while (attacks != 0) {
                    const to = popLsb(&attacks);
                    appendFullActiveIndex(result, perspective, attacker, from, to, pieces[to], king_square);
                }
            }
        }
    }
}

pub fn fullRequiresRefresh(diff: FullDiff, perspective: u8) bool {
    return perspective == diff.us and (((@as(i8, @bitCast(diff.ksq)) & 0b100) != (@as(i8, @bitCast(diff.prev_ksq)) & 0b100)));
}

fn appendActivePawnThreats(
    result: *FullAppendResult,
    pieces: []const u8,
    pawn_targets: u64,
    color_pawns: u64,
    perspective: u8,
    color: u8,
    king_square: u8,
) void {
    // Only the two diagonal pawn attacks now: the pusher (pawn-in-front) input was removed
    // with SFNNv16 -- pawn-pawn relationships live in the PP_3Wide feature set.
    const attacker = makePiece(color, pawn_piece_type);

    if (color == white) {
        processPawnAttacks(result, perspective, attacker, king_square, pieces, shift(north_east, color_pawns) & pawn_targets, north_east);
        processPawnAttacks(result, perspective, attacker, king_square, pieces, shift(north_west, color_pawns) & pawn_targets, north_west);
    } else {
        processPawnAttacks(result, perspective, attacker, king_square, pieces, shift(south_west, color_pawns) & pawn_targets, south_west);
        processPawnAttacks(result, perspective, attacker, king_square, pieces, shift(south_east, color_pawns) & pawn_targets, south_east);
    }
}

fn processPawnAttacks(
    result: *FullAppendResult,
    perspective: u8,
    attacker: u8,
    king_square: u8,
    pieces: []const u8,
    attacks: u64,
    attack_dir: i8,
) void {
    var pending = attacks;
    while (pending != 0) {
        const to = popLsb(&pending);
        const from: usize = @intCast(@as(i32, @intCast(to)) - @as(i32, attack_dir));
        appendFullActiveIndex(result, perspective, attacker, from, to, pieces[to], king_square);
    }
}

fn appendFullActiveIndex(
    result: *FullAppendResult,
    perspective: u8,
    attacker: u8,
    from_sq: usize,
    to_sq: usize,
    attacked: u8,
    king_square: u8,
) void {
    const index = fullMakeIndex(.{
        .perspective = perspective,
        .attacker = attacker,
        .from_sq = @intCast(from_sq),
        .to_sq = @intCast(to_sq),
        .attacked = attacked,
        .king_square = king_square,
    });

    if (index < full_dimensions) {
        std.debug.assert(result.len < result.indices.len);
        result.indices[result.len] = index;
        result.len += 1;
    }
}

// ---- PP_3Wide (pawn-pair) feature set ---------------------------------------
// A second threat-adjacent feature set (upstream Features::PP_3Wide): every pair of pawns
// on the same or an adjacent file (ranks 2-7) is one feature. Its indices are concatenated
// onto the threats -- base pp_index_base -- so they share the threatAndPp weight rows and
// merge into the same removed/added/active index lists the threat kernels consume.

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

// Re-export the AVX512VBMI+VBMI2 vector fast path for the refresh-time HalfKAv2_hm
// index write (nnue_feature_write_avx512.zig), so nnue_acc_update.zig -- which
// already imports this module by name -- reaches it without a second relative import
// of the same file: nnue_feature_write_avx512.zig also relative-imports
// nnue_feature_luts.zig below, and Zig requires every relative-imported file belong
// to exactly one module, so nnue_acc_update.zig (a different module, "nnue_accumulator")
// cannot import it directly without that file ending up claimed by two modules at once.
const nnue_feature_write_avx512 = @import("nnue_feature_write_avx512.zig");
pub const use_avx512_nnue_feature = nnue_feature_write_avx512.use_avx512_nnue_feature;
pub const writeIndicesAvx512 = nnue_feature_write_avx512.writeIndices;

// Re-import the split-out LUT tables and shared constants (nnue_feature_luts.zig).
const luts = @import("nnue_feature_luts.zig");
const piece_square_index = luts.piece_square_index;
const king_buckets = luts.king_buckets;
const orient_tbl_half = luts.orient_tbl_half;
const orient_tbl_full = luts.orient_tbl_full;
const ThreatRouteBlock = luts.ThreatRouteBlock;
const threat_route_blocks = luts.threat_route_blocks;
const full_dimensions = luts.full_dimensions;
const pp_index_base = luts.pp_index_base;
const pawn_pair_bb = luts.pawn_pair_bb;
const white = luts.white;
const black = luts.black;
const pawn_piece_type = luts.pawn_piece_type;
const knight_piece_type = luts.knight_piece_type;
const bishop_piece_type = luts.bishop_piece_type;
const rook_piece_type = luts.rook_piece_type;
const queen_piece_type = luts.queen_piece_type;
const king_piece_type = luts.king_piece_type;
const square_count = luts.square_count;
const sq_a2 = luts.sq_a2;
const north_east = luts.north_east;
const north_west = luts.north_west;
const south_east = luts.south_east;
const south_west = luts.south_west;

test {
    @import("std").testing.refAllDecls(@This());
}
