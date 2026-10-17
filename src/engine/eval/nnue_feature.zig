const std = @import("std");

/// Alias back the pure bitboard-math helpers, which live in a std-only leaf now
/// (Zig top-level decls are order-independent, so callers above are unaffected).
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

pub const HalfThreatParams = struct {
    perspective: u8,
    square: u8,
    piece: u8,
    king_square: u8,
    /// Whether the side opposite `perspective` has a queen -- K32Q2's second bucket axis.
    opponent_has_queen: bool,
};

pub const FullThreatParams = struct {
    perspective: u8,
    attacker: u8,
    from_sq: u8,
    to_sq: u8,
    attacked: u8,
    king_square: u8,
};

/// Index a K32Q2 feature -- upstream K32Q2::make_index: the square xor'd with one entry of
/// half_offsets, which folds the orientation, the piece-square base, the king bucket and
/// the opponent-queen block into a single u16.
pub fn halfMakeIndex(params: HalfThreatParams) u32 {
    const row = (@as(usize, @intFromBool(params.opponent_has_queen)) * 2 + params.perspective) * 64 + params.king_square;
    return @as(u32, params.square) ^ half_offsets[row][params.piece];
}

/// Say whether a ply's piece diff forces a K32Q2 refresh for `perspective` -- upstream
/// K32Q2::requires_refresh. Every index is keyed on that side's king square AND on whether
/// the opponent has a queen, so either one changing invalidates the whole accumulation: the
/// king moving, or an opponent queen leaving (captured) or arriving (promoted to). A
/// queen-for-queen capture with a second queen left is refreshed too, the cost of testing
/// the diff rather than the board. `remove_pc` and `add_pc` are read only behind their
/// square, which is what says they were written for this ply.
pub fn halfRequiresRefresh(diff: HalfDiff, perspective: u8) bool {
    if (diff.pc == makePiece(perspective, king_piece_type)) return true;
    const opponent_queen = makePiece(perspective ^ 1, queen_piece_type);
    return (diff.remove_sq != sq_none and diff.remove_pc == opponent_queen) or
        (diff.add_sq != sq_none and diff.add_pc == opponent_queen);
}

pub fn fullMakeIndex(params: FullThreatParams) u32 {
    const orientation: i32 = @as(i32, orient_tbl_full[params.king_square]) ^ @as(i32, 56 * params.perspective);
    const from_oriented: usize = @intCast(@as(u8, params.from_sq) ^ @as(u8, @intCast(orientation)));
    const to_oriented: usize = @intCast(@as(u8, params.to_sq) ^ @as(u8, @intCast(orientation)));
    const swap: u8 = 8 * params.perspective;
    const attacker_oriented: usize = params.attacker ^ swap;
    const attacked_oriented: usize = params.attacked ^ swap;
    const less: usize = @intFromBool(from_oriented < to_oriented);
    return threat_lut1[(attacker_oriented * 16 + attacked_oriented) * 2 + less] +
        threat_lut2[attacker_oriented & 7][from_oriented * 64 + to_oriented];
}

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
        // Read the attacker/attacked byte pre-doubled -- shift one bit less and mask the
        // low bit away -- so [pair2 + less] indexes threat_lut1 without a separate scale.
        const pair2: usize = (x >> 15) & 0x1fe;
        const from: usize = x & 0xff;
        const to: usize = (x >> 8) & 0xff;
        const less: usize = @intFromBool(from < to);
        const index = threat_lut1[pair2 + less] + threat_lut2[(x >> 20) & 7][(from << 6) | to];
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

/// Decode each dirty-threat record ONCE and index it for both perspectives --
/// FullThreats::append_changed_indices_both. The record's fields (from, to, attacker,
/// attacked) and its add/remove polarity are perspective-independent; only the
/// orientation each is read under is not, which is exactly what the two route masks
/// carry. So load `raw` once and xor it twice.
///
/// The routing bit is shared and that is not an accident: bit 31 of a mask is set only
/// for a BACKWARD walk, and the shared walk is forward-only, so `x >> 31 == raw >> 31`
/// on both sides. Each index still gets its OWN bound test -- one perspective can drop
/// a record the other keeps, so the two lists need not be the same length.
pub noinline fn fullAppendChangedBoth(
    values: []const u32,
    white_mask: u32,
    black_mask: u32,
    w_removed_out: [*]u32,
    w_added_out: [*]u32,
    b_removed_out: [*]u32,
    b_added_out: [*]u32,
) struct { w: FullAppendChangedLens, b: FullAppendChangedLens } {
    // Index the two destination lists instead of branching to them. The added/removed flag
    // is the record's sign bit and it is near-random across a ply's threat diff, so the two
    // `if (to_added)` below were an UNPREDICTABLE branch taken twice per record. Selecting
    // `{removed, added}[k]` makes the destination a load, and the flag stops reaching the
    // predictor at all. The bound test on each index is a DIFFERENT branch and stays: one
    // perspective can drop a record the other keeps.
    var w_out = [2][*]u32{ w_removed_out, w_added_out };
    var w_len = [2]usize{ 0, 0 };
    var b_out = [2][*]u32{ b_removed_out, b_added_out };
    var b_len = [2]usize{ 0, 0 };
    for (values) |raw| {
        const k: usize = raw >> 31;

        const xw = raw ^ white_mask;
        const wfrom: usize = xw & 0xff;
        const wto: usize = (xw >> 8) & 0xff;
        const w_index = threat_lut1[((xw >> 15) & 0x1fe) + @intFromBool(wfrom < wto)] + threat_lut2[(xw >> 20) & 7][(wfrom << 6) | wto];
        if (w_index < full_dimensions) {
            w_out[k][w_len[k]] = w_index;
            w_len[k] += 1;
        }

        const xb = raw ^ black_mask;
        const bfrom: usize = xb & 0xff;
        const bto: usize = (xb >> 8) & 0xff;
        const b_index = threat_lut1[((xb >> 15) & 0x1fe) + @intFromBool(bfrom < bto)] + threat_lut2[(xb >> 20) & 7][(bfrom << 6) | bto];
        if (b_index < full_dimensions) {
            b_out[k][b_len[k]] = b_index;
            b_len[k] += 1;
        }
    }
    return .{
        .w = .{ .removed = w_len[0], .added = w_len[1] },
        .b = .{ .removed = b_len[0], .added = b_len[1] },
    };
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

    // Both colours' pawn attacks first, one call per direction -- upstream 68f7925d. The
    // colour loop below is absolute (WHITE, BLACK) rather than perspective-relative: the
    // accumulator SUMS the rows this list names, so the order it names them in is not an
    // observable.
    appendActivePawnThreats(result, pieces, pawn_targets, by_color[white] & pawns, perspective, white, king_square, north_east);
    appendActivePawnThreats(result, pieces, pawn_targets, by_color[white] & pawns, perspective, white, king_square, north_west);
    appendActivePawnThreats(result, pieces, pawn_targets, by_color[black] & pawns, perspective, black, king_square, south_west);
    appendActivePawnThreats(result, pieces, pawn_targets, by_color[black] & pawns, perspective, black, king_square, south_east);

    var color: u8 = 0;

    while (color < 2) : (color += 1) {
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

/// Emit one colour's pawn threats in ONE direction. Only the two diagonal attacks exist now: the
/// pusher (pawn-in-front) input was removed with SFNNv16 -- pawn-pawn relationships live in the
/// PP_3Wide feature set.
fn appendActivePawnThreats(
    result: *FullAppendResult,
    pieces: []const u8,
    pawn_targets: u64,
    color_pawns: u64,
    perspective: u8,
    color: u8,
    king_square: u8,
    attack_dir: i8,
) void {
    const attacker = makePiece(color, pawn_piece_type);
    processPawnAttacks(result, perspective, attacker, king_square, pieces, shift(attack_dir, color_pawns) & pawn_targets, attack_dir);
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

/// Re-export the AVX512VBMI+VBMI2 vector fast path for the refresh-time K32Q2
/// index write (nnue_feature_write_avx512.zig), so nnue_acc_update.zig -- which
/// already imports this module by name -- reaches it without a second relative import
/// of the same file: nnue_feature_write_avx512.zig also relative-imports
/// nnue_feature_luts.zig below, and Zig requires every relative-imported file belong
/// to exactly one module, so nnue_acc_update.zig (a different module, "nnue_accumulator")
/// cannot import it directly without that file ending up claimed by two modules at once.
/// Re-export the PP_3Wide (pawn-pair) feature set, which lives in its own leaf now
/// (nnue_feature_pp.zig). Callers reach it through this module exactly as before.
const nnue_feature_pp = @import("nnue_feature_pp.zig");
pub const ppMakeIndex = nnue_feature_pp.ppMakeIndex;
pub const ppAppendActive = nnue_feature_pp.ppAppendActive;
pub const ppAppendChanged = nnue_feature_pp.ppAppendChanged;
pub const ppAppendChangedBoth = nnue_feature_pp.ppAppendChangedBoth;

const nnue_feature_write_avx512 = @import("nnue_feature_write_avx512.zig");
pub const use_avx512_nnue_feature = nnue_feature_write_avx512.use_avx512_nnue_feature;
pub const writeIndicesAvx512 = nnue_feature_write_avx512.writeIndices;

/// Re-import the split-out LUT tables and shared constants (nnue_feature_luts.zig).
const luts = @import("nnue_feature_luts.zig");
const piece_square_index = luts.piece_square_index;
const king_buckets = luts.king_buckets;
const queen_offset = luts.queen_offset;
const orient_tbl_half = luts.orient_tbl_half;
const orient_tbl_full = luts.orient_tbl_full;
const half_offsets = luts.half_offsets;
const threat_lut1 = luts.threat_lut1;
const threat_lut2 = luts.threat_lut2;
const full_dimensions = luts.full_dimensions;
pub const FullAppendResult = luts.FullAppendResult;
pub const FullAppendChangedLens = luts.FullAppendChangedLens;
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
const sq_none = luts.sq_none;
const sq_a2 = luts.sq_a2;
const north_east = luts.north_east;
const north_west = luts.north_west;
const south_east = luts.south_east;
const south_west = luts.south_west;

test "halfMakeIndex: the offset table agrees with the unfolded formula everywhere" {
    for (0..2) |q| for (0..2) |p| for (0..64) |ksq| for (0..64) |sq| for (0..16) |pc| {
        const flip: u32 = 56 * @as(u32, @intCast(p));
        const unfolded = (@as(u32, @intCast(sq)) ^ orient_tbl_half[ksq] ^ flip) +
            piece_square_index[p][pc] + king_buckets[ksq ^ (p * 56)] + @as(u32, @intCast(q)) * queen_offset;
        try std.testing.expectEqual(unfolded, halfMakeIndex(.{
            .perspective = @intCast(p),
            .square = @intCast(sq),
            .piece = @intCast(pc),
            .king_square = @intCast(ksq),
            .opponent_has_queen = q == 1,
        }));
    };
}

test "halfRequiresRefresh: the own king, or an opponent queen leaving or arriving" {
    const quiet: HalfDiff = .{ .from = 12, .to = 28, .pc = 1, .remove_sq = sq_none, .add_sq = sq_none, .remove_pc = 13, .add_pc = 13 };
    // A stale queen byte behind an empty square is not this ply's capture or promotion.
    try std.testing.expect(!halfRequiresRefresh(quiet, white));
    var king_move = quiet;
    king_move.pc = 6;
    try std.testing.expect(halfRequiresRefresh(king_move, white));
    try std.testing.expect(!halfRequiresRefresh(king_move, black));
    var takes_queen = quiet;
    takes_queen.remove_sq = 28;
    takes_queen.remove_pc = 13; // black queen
    try std.testing.expect(halfRequiresRefresh(takes_queen, white));
    try std.testing.expect(!halfRequiresRefresh(takes_queen, black));
    var promotes = quiet;
    promotes.add_sq = 63;
    promotes.add_pc = 5; // white queen
    try std.testing.expect(halfRequiresRefresh(promotes, black));
    try std.testing.expect(!halfRequiresRefresh(promotes, white));
}

test {
    @import("std").testing.refAllDecls(@This());
}
