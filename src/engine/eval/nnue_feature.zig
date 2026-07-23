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

fn indexLut2Array() [16][64][64]u8 {
    @setEvalBranchQuota(200000);
    const knight_attacks = makePieceIndicesType(knight_piece_type);
    const bishop_attacks = makePieceIndicesType(bishop_piece_type);
    const rook_attacks = makePieceIndicesType(rook_piece_type);
    const queen_attacks = makePieceIndicesType(queen_piece_type);
    const king_attacks = makePieceIndicesType(king_piece_type);

    var indices = std.mem.zeroes([16][64][64]u8);
    indices[w_pawn] = makePieceIndicesPawn(w_pawn);
    indices[b_pawn] = makePieceIndicesPawn(b_pawn);
    indices[w_knight] = knight_attacks;
    indices[b_knight] = knight_attacks;
    indices[w_bishop] = bishop_attacks;
    indices[b_bishop] = bishop_attacks;
    indices[w_rook] = rook_attacks;
    indices[b_rook] = rook_attacks;
    indices[w_queen] = queen_attacks;
    indices[b_queen] = queen_attacks;
    indices[w_king] = king_attacks;
    indices[b_king] = king_attacks;
    return indices;
}

const HelperOffsets = struct {
    cumulative_piece_offset: u32,
    cumulative_offset: u32,
};

fn initThreatOffsets() struct { first: [16]HelperOffsets, second: [16][64]u32 } {
    @setEvalBranchQuota(200000);
    var indices = std.mem.zeroes([16]HelperOffsets);
    var local_offsets = std.mem.zeroes([16][64]u32);
    var cumulative_offset: u32 = 0;
    var piece_index: usize = 0;
    while (piece_index < all_pieces.len) : (piece_index += 1) {
        const piece = all_pieces[piece_index];
        var cumulative_piece_offset: u32 = 0;
        var from: usize = 0;
        while (from < 64) : (from += 1) {
            local_offsets[piece][from] = cumulative_piece_offset;
            if (typeOf(piece) != pawn_piece_type) {
                cumulative_piece_offset += constexprPopcount(pseudoAttacks(typeOf(piece), from));
            } else if (from >= sq_a2 and from <= sq_h7) {
                const attacks = if (piece < 8) pawnPushOrAttacks(white, from) else pawnPushOrAttacks(black, from);
                cumulative_piece_offset += constexprPopcount(attacks);
            }
        }
        indices[piece] = .{
            .cumulative_piece_offset = cumulative_piece_offset,
            .cumulative_offset = cumulative_offset,
        };
        cumulative_offset += @as(u32, num_valid_targets[piece]) * cumulative_piece_offset;
    }
    return .{ .first = indices, .second = local_offsets };
}

fn initIndexLuts() [16][16][2]u32 {
    @setEvalBranchQuota(200000);
    var indices = std.mem.zeroes([16][16][2]u32);
    var attacker_idx: usize = 0;
    while (attacker_idx < all_pieces.len) : (attacker_idx += 1) {
        const attacker = all_pieces[attacker_idx];
        var attacked_idx: usize = 0;
        while (attacked_idx < all_pieces.len) : (attacked_idx += 1) {
            const attacked = all_pieces[attacked_idx];
            const enemy = (attacker ^ attacked) == 8;
            const attacker_type = typeOf(attacker);
            const attacked_type = typeOf(attacked);
            const map_value = full_map[attacker_type - 1][attacked_type - 1];
            const semi_excluded = attacker_type == attacked_type and (enemy or attacker_type != pawn_piece_type);
            const excluded = map_value < 0;
            if (excluded) {
                indices[attacker][attacked][0] = full_dimensions;
                indices[attacker][attacked][1] = full_dimensions;
                continue;
            }

            const feature_slot: u32 = @intCast(colorOf(attacked) * (num_valid_targets[attacker] / 2) + map_value);
            const feature = helper_offsets[attacker].cumulative_offset + feature_slot * helper_offsets[attacker].cumulative_piece_offset;

            indices[attacker][attacked][0] = feature;
            indices[attacker][attacked][1] = if (semi_excluded) full_dimensions else feature;
        }
    }
    return indices;
}

const piece_square_index = [2][16]u32{
    .{ 0, 0, 128, 256, 384, 512, 640, 0, 0, 64, 192, 320, 448, 576, 640, 0 },
    .{ 0, 64, 192, 320, 448, 576, 640, 0, 0, 0, 128, 256, 384, 512, 640, 0 },
};

const king_buckets = [64]u32{
    28 * ps_nb, 29 * ps_nb, 30 * ps_nb, 31 * ps_nb, 31 * ps_nb, 30 * ps_nb, 29 * ps_nb, 28 * ps_nb,
    24 * ps_nb, 25 * ps_nb, 26 * ps_nb, 27 * ps_nb, 27 * ps_nb, 26 * ps_nb, 25 * ps_nb, 24 * ps_nb,
    20 * ps_nb, 21 * ps_nb, 22 * ps_nb, 23 * ps_nb, 23 * ps_nb, 22 * ps_nb, 21 * ps_nb, 20 * ps_nb,
    16 * ps_nb, 17 * ps_nb, 18 * ps_nb, 19 * ps_nb, 19 * ps_nb, 18 * ps_nb, 17 * ps_nb, 16 * ps_nb,
    12 * ps_nb, 13 * ps_nb, 14 * ps_nb, 15 * ps_nb, 15 * ps_nb, 14 * ps_nb, 13 * ps_nb, 12 * ps_nb,
    8 * ps_nb,  9 * ps_nb,  10 * ps_nb, 11 * ps_nb, 11 * ps_nb, 10 * ps_nb, 9 * ps_nb,  8 * ps_nb,
    4 * ps_nb,  5 * ps_nb,  6 * ps_nb,  7 * ps_nb,  7 * ps_nb,  6 * ps_nb,  5 * ps_nb,  4 * ps_nb,
    0 * ps_nb,  1 * ps_nb,  2 * ps_nb,  3 * ps_nb,  3 * ps_nb,  2 * ps_nb,  1 * ps_nb,  0 * ps_nb,
};

const orient_tbl_half = [64]u32{
    7, 7, 7, 7, 0, 0, 0, 0,
    7, 7, 7, 7, 0, 0, 0, 0,
    7, 7, 7, 7, 0, 0, 0, 0,
    7, 7, 7, 7, 0, 0, 0, 0,
    7, 7, 7, 7, 0, 0, 0, 0,
    7, 7, 7, 7, 0, 0, 0, 0,
    7, 7, 7, 7, 0, 0, 0, 0,
    7, 7, 7, 7, 0, 0, 0, 0,
};

const orient_tbl_full = [64]i8{
    0, 0, 0, 0, 7, 7, 7, 7,
    0, 0, 0, 0, 7, 7, 7, 7,
    0, 0, 0, 0, 7, 7, 7, 7,
    0, 0, 0, 0, 7, 7, 7, 7,
    0, 0, 0, 0, 7, 7, 7, 7,
    0, 0, 0, 0, 7, 7, 7, 7,
    0, 0, 0, 0, 7, 7, 7, 7,
    0, 0, 0, 0, 7, 7, 7, 7,
};

const num_valid_targets = [16]i32{ 0, 6, 10, 8, 8, 10, 0, 0, 0, 6, 10, 8, 8, 10, 0, 0 };

const full_map = [6][6]i32{
    .{ 0, 1, -1, 2, -1, -1 },
    .{ 0, 1, 2, 3, 4, -1 },
    .{ 0, 1, 2, 3, -1, -1 },
    .{ 0, 1, 2, 3, -1, -1 },
    .{ 0, 1, 2, 3, 4, -1 },
    .{ -1, -1, -1, -1, -1, -1 },
};

const helper_offsets_and_offsets = initThreatOffsets();
const helper_offsets = helper_offsets_and_offsets.first;
const offsets = helper_offsets_and_offsets.second;
const index_lut1 = initIndexLuts();
const index_lut2 = indexLut2Array();

// Colocate one attacker's whole lookup state -- its flattened index_lut1 row
// ([attacked * 2 + less] addresses one element with one scaled index) and a
// merged u16 `offsets[from] + index_lut2[from][to]` plane -- so a threat index
// costs one block base plus two loads instead of three loads behind three
// separately scaled bases. The merge fits u16 with a wide margin: the largest
// per-from offset (queen, 1455) plus the largest within-from index still sits
// far below 65535, and the builder asserts every sum. The source tables above
// remain the comptime input; only the blocks are referenced at runtime.
const ThreatRouteBlock = extern struct {
    lut1: [32]u32,
    comb: [64 * 64]u16,
};

fn buildThreatRouteBlocks() [16]ThreatRouteBlock {
    @setEvalBranchQuota(4000000);
    var blocks = std.mem.zeroes([16]ThreatRouteBlock);
    for (&blocks, 0..) |*block, attacker| {
        block.lut1 = @bitCast(index_lut1[attacker]);
        for (0..64) |from| {
            for (0..64) |to| {
                const merged: u32 = offsets[attacker][from] + index_lut2[attacker][from][to];
                std.debug.assert(merged <= std.math.maxInt(u16));
                block.comb[from * 64 + to] = @intCast(merged);
            }
        }
    }
    return blocks;
}

const threat_route_blocks = buildThreatRouteBlocks();

const ps_nb: u32 = 11 * 64;
const full_dimensions: u32 = 60720;

const white: u8 = 0;
const black: u8 = 1;

const pawn_piece_type: u8 = 1;
const knight_piece_type: u8 = 2;
const bishop_piece_type: u8 = 3;
const rook_piece_type: u8 = 4;
const queen_piece_type: u8 = 5;
const king_piece_type: u8 = 6;

const w_pawn: usize = 1;
const w_knight: usize = 2;
const w_bishop: usize = 3;
const w_rook: usize = 4;
const w_queen: usize = 5;
const w_king: usize = 6;
const b_pawn: usize = 9;
const b_knight: usize = 10;
const b_bishop: usize = 11;
const b_rook: usize = 12;
const b_queen: usize = 13;
const b_king: usize = 14;

const all_pieces = [_]usize{ w_pawn, w_knight, w_bishop, w_rook, w_queen, w_king, b_pawn, b_knight, b_bishop, b_rook, b_queen, b_king };

const no_piece: u8 = 0;
const sq_none: u8 = 64;
const square_count: usize = 64;
const sq_a2: usize = 8;
const sq_h7: usize = 55;

const file_a_bb: u64 = 0x0101010101010101;
const file_h_bb: u64 = file_a_bb << 7;

const north: i8 = 8;
const east: i8 = 1;
const south: i8 = -8;
const west: i8 = -1;
const north_east: i8 = 9;
const north_west: i8 = 7;
const south_east: i8 = -7;
const south_west: i8 = -9;

const rook_dirs = [_]i8{ north, south, east, west };
const bishop_dirs = [_]i8{ north_east, south_east, south_west, north_west };
const queen_dirs = [_]i8{ north, south, east, west, north_east, south_east, south_west, north_west };
const knight_steps = [_]i8{ -17, -15, -10, -6, 6, 10, 15, 17 };
const king_steps = [_]i8{ -9, -8, -7, -1, 1, 7, 8, 9 };

test {
    @import("std").testing.refAllDecls(@This());
}
