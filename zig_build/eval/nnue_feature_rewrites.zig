const std = @import("std");

comptime {
    @setEvalBranchQuota(200000);
}

pub const HalfDiff = extern struct {
    from: u8,
    to: u8,
    pc: u8,
    remove_sq: u8,
    add_sq: u8,
    remove_pc: u8,
    add_pc: u8,
};

pub const DirtyThreatRaw = extern struct {
    data: u32,
};

pub const FullDiff = extern struct {
    us: u8,
    prev_ksq: u8,
    ksq: u8,
};

pub const HalfAppendResult = extern struct {
    len: usize,
    indices: [32]u32,
};

pub const FullAppendResult = extern struct {
    len: usize,
    indices: [128]u32,
};

pub const HalfThreatParams = extern struct {
    perspective: u8,
    square: u8,
    piece: u8,
    king_square: u8,
};

pub const FullThreatParams = extern struct {
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
    var result: HalfAppendResult = .{ .len = 0, .indices = [_]u32{0} ** 32 };
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
    var result: FullAppendResult = .{ .len = 0, .indices = [_]u32{0} ** 128 };
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
    const idx = fullMakeIndex(.{
        .perspective = perspective,
        .attacker = attacker,
        .from_sq = from_sq,
        .to_sq = to_sq,
        .attacked = attacked,
        .king_square = king_square,
    });
    if (idx < full_dimensions) {
        result.indices[result.len] = idx;
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

fn makePiece(color: u8, piece_type: u8) u8 {
    return @intCast((color << 3) + piece_type);
}

fn constexprPopcount(bitboard: u64) u8 {
    return @intCast(@popCount(bitboard));
}

fn typeOf(piece: u8) u8 {
    return piece & 7;
}

fn colorOf(piece: u8) u8 {
    return piece >> 3;
}

fn shift(dir: i8, bitboard: u64) u64 {
    return switch (dir) {
        north => bitboard << 8,
        south => bitboard >> 8,
        east => (bitboard & ~file_h_bb) << 1,
        west => (bitboard & ~file_a_bb) >> 1,
        north_east => (bitboard & ~file_h_bb) << 9,
        north_west => (bitboard & ~file_a_bb) << 7,
        south_east => (bitboard & ~file_h_bb) >> 7,
        south_west => (bitboard & ~file_a_bb) >> 9,
        else => 0,
    };
}

fn pawnPushOrAttacks(color: u8, square: usize) u64 {
    const one = squareBb(square);
    return if (color == white)
        shift(north, one) | shift(north_west, one) | shift(north_east, one)
    else
        shift(south, one) | shift(south_west, one) | shift(south_east, one);
}

fn safeDestination(square: usize, step: i8) u64 {
    const target = @as(i32, @intCast(square)) + step;
    if (target < 0 or target >= 64) {
        return 0;
    }
    const from_file = square % 8;
    const to_file: usize = @intCast(@mod(target, 8));
    const diff = if (from_file > to_file) from_file - to_file else to_file - from_file;
    if (diff > 2) {
        return 0;
    }
    return squareBb(@intCast(target));
}

fn slidingAttack(piece_type: u8, square: usize, occupied: u64) u64 {
    var attacks: u64 = 0;
    const dirs = switch (piece_type) {
        bishop_piece_type => bishop_dirs[0..],
        rook_piece_type => rook_dirs[0..],
        queen_piece_type => queen_dirs[0..],
        else => &[_]i8{},
    };
    for (dirs) |dir| {
        var current = square;
        while (true) {
            const dest = safeDestination(current, dir);
            if (dest == 0) break;
            attacks |= dest;
            current = @ctz(dest);
            if ((occupied & dest) != 0) break;
        }
    }
    return attacks;
}

fn knightAttack(square: usize) u64 {
    var bitboard: u64 = 0;
    for (knight_steps) |step| {
        bitboard |= safeDestination(square, step);
    }
    return bitboard;
}

fn kingAttack(square: usize) u64 {
    var bitboard: u64 = 0;
    for (king_steps) |step| {
        bitboard |= safeDestination(square, step);
    }
    return bitboard;
}

fn pseudoAttacks(piece_type: u8, square: usize) u64 {
    return switch (piece_type) {
        knight_piece_type => knightAttack(square),
        bishop_piece_type => slidingAttack(bishop_piece_type, square, 0),
        rook_piece_type => slidingAttack(rook_piece_type, square, 0),
        queen_piece_type => slidingAttack(queen_piece_type, square, 0),
        king_piece_type => kingAttack(square),
        else => 0,
    };
}

fn squareBb(square: usize) u64 {
    return @as(u64, 1) << @as(u6, @intCast(square));
}

fn makePieceIndicesType(comptime piece_type: u8) [64][64]u8 {
    @setEvalBranchQuota(200000);
    var out = std.mem.zeroes([64][64]u8);
    var from: usize = 0;
    while (from < 64) : (from += 1) {
        const attacks = pseudoAttacks(piece_type, from);
        var to: usize = 0;
        while (to < 64) : (to += 1) {
            out[from][to] = constexprPopcount(((squareBb(to) - 1) & attacks));
        }
    }
    return out;
}

fn makePieceIndicesPawn(comptime piece: u8) [64][64]u8 {
    @setEvalBranchQuota(200000);
    var out = std.mem.zeroes([64][64]u8);
    const color = colorOf(piece);
    var from: usize = 0;
    while (from < 64) : (from += 1) {
        const attacks = pawnPushOrAttacks(color, from);
        var to: usize = 0;
        while (to < 64) : (to += 1) {
            out[from][to] = constexprPopcount(((squareBb(to) - 1) & attacks));
        }
    }
    return out;
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

const sq_none: u8 = 64;
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
