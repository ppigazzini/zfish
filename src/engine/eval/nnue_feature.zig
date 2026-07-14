const std = @import("std");

// The pure bitboard-math helpers live in a std-only leaf now; alias them
// back (Zig top-level decls are order-independent, so callers above are unaffected).
const nnue_feature_bb = @import("nnue_feature_bb.zig");
const makePiece = nnue_feature_bb.makePiece;
const constexprPopcount = nnue_feature_bb.constexprPopcount;
const typeOf = nnue_feature_bb.typeOf;
const colorOf = nnue_feature_bb.colorOf;
const shift = nnue_feature_bb.shift;
const pawnPushOrAttacks = nnue_feature_bb.pawnPushOrAttacks;
const safeDestination = nnue_feature_bb.safeDestination;
const attacksBb = nnue_feature_bb.attacksBb;
const piecesOfExact = nnue_feature_bb.piecesOfExact;
const piecesOfType = nnue_feature_bb.piecesOfType;
const occupiedFromPieces = nnue_feature_bb.occupiedFromPieces;
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

pub const HalfAppendResult = struct {
    len: usize,
    indices: [32]u32,
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

pub fn halfAppendChanged(perspective: u8, king_square: u8, diff: HalfDiff) HalfAppendResult {
    var result: HalfAppendResult = .{ .len = 0, .indices = undefined };
    appendHalfIndex(&result, perspective, diff.from, diff.pc, king_square);
    if (diff.to != sq_none) {
        appendHalfIndex(&result, perspective, diff.to, diff.pc, king_square);
    }
    if (diff.remove_sq != sq_none) {
        appendHalfIndex(&result, perspective, diff.remove_sq, diff.remove_pc, king_square);
    }
    if (diff.add_sq != sq_none) {
        appendHalfIndex(&result, perspective, diff.add_sq, diff.add_pc, king_square);
    }
    return result;
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
    return index_lut1[attacker_oriented][attacked_oriented][less] + offsets[attacker_oriented][from_oriented] + index_lut2[attacker_oriented][from_oriented][to_oriented];
}

pub fn fullAppendChanged(
    perspective: u8,
    king_square: u8,
    list_ptr: [*]const DirtyThreatRaw,
    list_len: usize,
) FullAppendResult {
    var result: FullAppendResult = .{ .len = 0, .indices = undefined };
    var index: usize = 0;
    while (index < list_len) : (index += 1) {
        const dirty = list_ptr[index].data;
        const threat = decodeThreat(dirty);
        appendFullIndex(
            &result,
            perspective,
            threat.attacker,
            threat.from_sq,
            threat.to_sq,
            threat.attacked,
            king_square,
        );
    }
    return result;
}

pub fn fullAppendActive(
    perspective: u8,
    king_square: u8,
    piece_array: [*]const u8,
) FullAppendResult {
    const pieces = piece_array[0..square_count];
    const occupied = occupiedFromPieces(pieces);
    const pawns = piecesOfType(pieces, pawn_piece_type);

    var result: FullAppendResult = .{ .len = 0, .indices = undefined };
    var color_index: u8 = 0;

    while (color_index < 2) : (color_index += 1) {
        const color = perspective ^ color_index;
        appendActivePawnThreats(&result, pieces, occupied, pawns, perspective, color, king_square);

        var piece_type: u8 = knight_piece_type;
        while (piece_type < king_piece_type) : (piece_type += 1) {
            const attacker = makePiece(color, piece_type);
            var attackers = piecesOfExact(pieces, attacker);
            while (attackers != 0) {
                const from = popLsb(&attackers);
                var attacks = attacksBb(piece_type, from, occupied) & occupied;
                while (attacks != 0) {
                    const to = popLsb(&attacks);
                    appendFullActiveIndex(&result, perspective, attacker, from, to, pieces[to], king_square);
                }
            }
        }
    }

    return result;
}

pub fn fullRequiresRefresh(diff: FullDiff, perspective: u8) bool {
    return perspective == diff.us and (((@as(i8, @bitCast(diff.ksq)) & 0b100) != (@as(i8, @bitCast(diff.prev_ksq)) & 0b100)));
}

fn appendHalfIndex(result: *HalfAppendResult, perspective: u8, square: u8, piece: u8, king_square: u8) void {
    result.indices[result.len] = halfMakeIndex(.{
        .perspective = perspective,
        .square = square,
        .piece = piece,
        .king_square = king_square,
    });
    result.len += 1;
}

fn appendFullIndex(
    result: *FullAppendResult,
    perspective: u8,
    attacker: u8,
    from_sq: u8,
    to_sq: u8,
    attacked: u8,
    king_square: u8,
) void {
    result.indices[result.len] = fullMakeIndex(.{
        .perspective = perspective,
        .attacker = attacker,
        .from_sq = from_sq,
        .to_sq = to_sq,
        .attacked = attacked,
        .king_square = king_square,
    });
    result.len += 1;
}

fn appendActivePawnThreats(
    result: *FullAppendResult,
    pieces: []const u8,
    occupied: u64,
    pawns: u64,
    perspective: u8,
    color: u8,
    king_square: u8,
) void {
    const attacker = makePiece(color, pawn_piece_type);
    const color_pawns = piecesOfExact(pieces, attacker);
    const pushers = pawnSinglePush(color ^ 1, pawns) & color_pawns;

    if (color == white) {
        processPawnAttacks(result, perspective, attacker, king_square, pieces, shift(north_east, color_pawns) & occupied, north_east);
        processPawnAttacks(result, perspective, attacker, king_square, pieces, shift(north_west, color_pawns) & occupied, north_west);
        processPawnAttacks(result, perspective, attacker, king_square, pieces, shift(north, pushers), north);
    } else {
        processPawnAttacks(result, perspective, attacker, king_square, pieces, shift(south_west, color_pawns) & occupied, south_west);
        processPawnAttacks(result, perspective, attacker, king_square, pieces, shift(south_east, color_pawns) & occupied, south_east);
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

const DecodedThreat = struct {
    attacker: u8,
    attacked: u8,
    from_sq: u8,
    to_sq: u8,
};

fn decodeThreat(raw: u32) DecodedThreat {
    return .{
        .attacker = @intCast((raw >> dirty_threat_pc_offset) & 0xf),
        .attacked = @intCast((raw >> dirty_threatened_pc_offset) & 0xf),
        .to_sq = @intCast((raw >> dirty_threatened_sq_offset) & 0xff),
        .from_sq = @intCast((raw >> dirty_threat_pc_sq_offset) & 0xff),
    };
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

const dirty_threat_pc_sq_offset: u5 = 0;
const dirty_threatened_sq_offset: u5 = 8;
const dirty_threatened_pc_offset: u5 = 16;
const dirty_threat_pc_offset: u5 = 20;

test {
    @import("std").testing.refAllDecls(@This());
}
