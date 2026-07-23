const std = @import("std");

// Alias back the pure bitboard-math helpers, which live in a std-only leaf now
// (Zig top-level decls are order-independent, so callers above are unaffected).
const nnue_feature_bb = @import("nnue_feature_bb.zig");
const makePiece = nnue_feature_bb.makePiece;
const constexprPopcount = nnue_feature_bb.constexprPopcount;
const typeOf = nnue_feature_bb.typeOf;
const colorOf = nnue_feature_bb.colorOf;
const shift = nnue_feature_bb.shift;
const pawnPushOrAttacks = nnue_feature_bb.pawnPushOrAttacks;
const safeDestination = nnue_feature_bb.safeDestination;
const attacksBb = nnue_feature_bb.attacksBb;
const pawnSinglePush = nnue_feature_bb.pawnSinglePush;
const popLsb = nnue_feature_bb.popLsb;
const slidingAttack = nnue_feature_bb.slidingAttack;
const knightAttack = nnue_feature_bb.knightAttack;
const kingAttack = nnue_feature_bb.kingAttack;
const pseudoAttacks = nnue_feature_bb.pseudoAttacks;
const squareBb = nnue_feature_bb.squareBb;
const makePieceIndicesType = nnue_feature_bb.makePieceIndicesType;
const makePieceIndicesPawn = nnue_feature_bb.makePieceIndicesPawn;

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
    indices: [128]u32,
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
    // targets; pawns never threaten bishops or queens; bishops and rooks never
    // threaten queens). The filter still catches the pair-specific exclusions.
    const pawn_targets = pawns | by_type[knight_piece_type] | by_type[rook_piece_type];
    const minor_slider_targets = pawn_targets | by_type[bishop_piece_type];
    const queen_targets = minor_slider_targets | by_type[queen_piece_type];

    result.len = 0;
    var color_index: u8 = 0;

    while (color_index < 2) : (color_index += 1) {
        const color = perspective ^ color_index;
        appendActivePawnThreats(result, pieces, pawn_targets, pawns, by_color[color] & pawns, perspective, color, king_square);

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
    pawns: u64,
    color_pawns: u64,
    perspective: u8,
    color: u8,
    king_square: u8,
) void {
    const attacker = makePiece(color, pawn_piece_type);
    const pushers = pawnSinglePush(color ^ 1, pawns) & color_pawns;

    if (color == white) {
        processPawnAttacks(result, perspective, attacker, king_square, pieces, shift(north_east, color_pawns) & pawn_targets, north_east);
        processPawnAttacks(result, perspective, attacker, king_square, pieces, shift(north_west, color_pawns) & pawn_targets, north_west);
        processPawnAttacks(result, perspective, attacker, king_square, pieces, shift(north, pushers), north);
    } else {
        processPawnAttacks(result, perspective, attacker, king_square, pieces, shift(south_west, color_pawns) & pawn_targets, south_west);
        processPawnAttacks(result, perspective, attacker, king_square, pieces, shift(south_east, color_pawns) & pawn_targets, south_east);
        processPawnAttacks(result, perspective, attacker, king_square, pieces, shift(south, pushers), south);
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

// Re-import the split-out LUT tables and shared constants (nnue_feature_luts.zig).
const luts = @import("nnue_feature_luts.zig");
const piece_square_index = luts.piece_square_index;
const king_buckets = luts.king_buckets;
const orient_tbl_half = luts.orient_tbl_half;
const orient_tbl_full = luts.orient_tbl_full;
const num_valid_targets = luts.num_valid_targets;
const full_map = luts.full_map;
const helper_offsets = luts.helper_offsets;
const offsets = luts.offsets;
const index_lut1 = luts.index_lut1;
const index_lut2 = luts.index_lut2;
const ThreatRouteBlock = luts.ThreatRouteBlock;
const threat_route_blocks = luts.threat_route_blocks;
const ps_nb = luts.ps_nb;
const full_dimensions = luts.full_dimensions;
const white = luts.white;
const black = luts.black;
const pawn_piece_type = luts.pawn_piece_type;
const knight_piece_type = luts.knight_piece_type;
const bishop_piece_type = luts.bishop_piece_type;
const rook_piece_type = luts.rook_piece_type;
const queen_piece_type = luts.queen_piece_type;
const king_piece_type = luts.king_piece_type;
const w_pawn = luts.w_pawn;
const w_knight = luts.w_knight;
const w_bishop = luts.w_bishop;
const w_rook = luts.w_rook;
const w_queen = luts.w_queen;
const w_king = luts.w_king;
const b_pawn = luts.b_pawn;
const b_knight = luts.b_knight;
const b_bishop = luts.b_bishop;
const b_rook = luts.b_rook;
const b_queen = luts.b_queen;
const b_king = luts.b_king;
const all_pieces = luts.all_pieces;
const no_piece = luts.no_piece;
const sq_none = luts.sq_none;
const square_count = luts.square_count;
const sq_a2 = luts.sq_a2;
const sq_h7 = luts.sq_h7;
const file_a_bb = luts.file_a_bb;
const file_h_bb = luts.file_h_bb;
const north = luts.north;
const east = luts.east;
const south = luts.south;
const west = luts.west;
const north_east = luts.north_east;
const north_west = luts.north_west;
const south_east = luts.south_east;
const south_west = luts.south_west;
const rook_dirs = luts.rook_dirs;
const bishop_dirs = luts.bishop_dirs;
const queen_dirs = luts.queen_dirs;
const knight_steps = luts.knight_steps;
const king_steps = luts.king_steps;

test {
    @import("std").testing.refAllDecls(@This());
}
