// NNUE feature-index bitboard math: the pure square/piece/attack helpers +
// the two per-piece index-table generators, split out of nnue_feature.zig so the
// feature core stays under the file-size budget. std-only, no NNUE state -- the
// parent aliases these back in. Behaviour is identical (bench 2067208).

const std = @import("std");

const white: u8 = 0;
const black: u8 = 1;
const pawn_piece_type: u8 = 1;
const knight_piece_type: u8 = 2;
const bishop_piece_type: u8 = 3;
const rook_piece_type: u8 = 4;
const queen_piece_type: u8 = 5;
const king_piece_type: u8 = 6;
const no_piece: u8 = 0;
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

pub fn makePiece(color: u8, piece_type: u8) u8 {
    return @intCast((color << 3) + piece_type);
}

pub fn constexprPopcount(bitboard: u64) u8 {
    return @intCast(@popCount(bitboard));
}

pub fn typeOf(piece: u8) u8 {
    return piece & 7;
}

pub fn colorOf(piece: u8) u8 {
    return piece >> 3;
}

pub fn shift(dir: i8, bitboard: u64) u64 {
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

pub fn pawnPushOrAttacks(color: u8, square: usize) u64 {
    const one = squareBb(square);
    return if (color == white)
        shift(north, one) | shift(north_west, one) | shift(north_east, one)
    else
        shift(south, one) | shift(south_west, one) | shift(south_east, one);
}

pub fn safeDestination(square: usize, step: i8) u64 {
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

pub fn attacksBb(piece_type: u8, square: usize, occupied: u64) u64 {
    return switch (piece_type) {
        knight_piece_type => knightAttack(square),
        bishop_piece_type => slidingAttack(bishop_piece_type, square, occupied),
        rook_piece_type => slidingAttack(rook_piece_type, square, occupied),
        queen_piece_type => slidingAttack(queen_piece_type, square, occupied),
        else => 0,
    };
}

pub fn piecesOfExact(pieces: []const u8, wanted: u8) u64 {
    var bitboard: u64 = 0;
    var square: usize = 0;
    while (square < pieces.len) : (square += 1) {
        if (pieces[square] == wanted) {
            bitboard |= squareBb(square);
        }
    }
    return bitboard;
}

pub fn piecesOfType(pieces: []const u8, wanted_type: u8) u64 {
    var bitboard: u64 = 0;
    var square: usize = 0;
    while (square < pieces.len) : (square += 1) {
        const piece = pieces[square];
        if (piece != no_piece and typeOf(piece) == wanted_type) {
            bitboard |= squareBb(square);
        }
    }
    return bitboard;
}

pub fn occupiedFromPieces(pieces: []const u8) u64 {
    var bitboard: u64 = 0;
    var square: usize = 0;
    while (square < pieces.len) : (square += 1) {
        if (pieces[square] != no_piece) {
            bitboard |= squareBb(square);
        }
    }
    return bitboard;
}

pub fn pawnSinglePush(color: u8, bitboard: u64) u64 {
    return if (color == white)
        shift(north, bitboard)
    else
        shift(south, bitboard);
}

pub fn popLsb(bitboard: *u64) usize {
    const square: usize = @intCast(@ctz(bitboard.*));
    bitboard.* &= bitboard.* - 1;
    return square;
}

pub fn slidingAttack(piece_type: u8, square: usize, occupied: u64) u64 {
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

pub fn knightAttack(square: usize) u64 {
    var bitboard: u64 = 0;
    for (knight_steps) |step| {
        bitboard |= safeDestination(square, step);
    }
    return bitboard;
}

pub fn kingAttack(square: usize) u64 {
    var bitboard: u64 = 0;
    for (king_steps) |step| {
        bitboard |= safeDestination(square, step);
    }
    return bitboard;
}

pub fn pseudoAttacks(piece_type: u8, square: usize) u64 {
    return switch (piece_type) {
        knight_piece_type => knightAttack(square),
        bishop_piece_type => slidingAttack(bishop_piece_type, square, 0),
        rook_piece_type => slidingAttack(rook_piece_type, square, 0),
        queen_piece_type => slidingAttack(queen_piece_type, square, 0),
        king_piece_type => kingAttack(square),
        else => 0,
    };
}

pub fn squareBb(square: usize) u64 {
    return @as(u64, 1) << @as(u6, @intCast(square));
}

pub fn makePieceIndicesType(comptime piece_type: u8) [64][64]u8 {
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

pub fn makePieceIndicesPawn(comptime piece: u8) [64][64]u8 {
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

test {
    @import("std").testing.refAllDecls(@This());
}
