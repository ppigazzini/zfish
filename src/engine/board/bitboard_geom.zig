// Bitboard geometry + magic-index helpers: the pure square/file/rank math
// and from-scratch attack generators used to build the runtime tables. std-only,
// no table state -- bitboard.zig aliases these back. Identical behaviour (bench 2466447).

const std = @import("std");

pub const PieceType = enum(u8) {
    bishop = 3,
    rook = 4,
};

const file_a_bb: u64 = 0x0101010101010101;
const rank_1_bb: u64 = 0xff;
const north: i8 = 8;
const east: i8 = 1;
const south: i8 = -8;
const west: i8 = -1;
const north_east: i8 = 9;
const south_east: i8 = -7;
const south_west: i8 = -9;
const north_west: i8 = 7;

pub fn betweenSquares(from: usize, to: usize) u64 {
    var result = squareBb(to);
    if (from == to) {
        return result;
    }

    const step = lineStep(from, to) orelse return result;
    var current = from;
    while (true) {
        const destination = safeDestination(current, step);
        if (destination == 0) {
            return result;
        }

        result |= destination;
        current = lsb(destination);
        if (current == to) {
            return result;
        }
    }
}

pub fn lineStep(from: usize, to: usize) ?i8 {
    const from_file = fileOf(from);
    const to_file = fileOf(to);
    const from_rank = rankOf(from);
    const to_rank = rankOf(to);

    if (from_file == to_file) {
        return if (to_rank > from_rank) north else south;
    }

    if (from_rank == to_rank) {
        return if (to_file > from_file) east else west;
    }

    if (absDiff(from_file, to_file) != absDiff(from_rank, to_rank)) {
        return null;
    }

    if (to_rank > from_rank) {
        return if (to_file > from_file) north_east else north_west;
    }

    return if (to_file > from_file) south_east else south_west;
}

pub fn knightAttacks(square: usize) u64 {
    var result: u64 = 0;
    const file = @as(i32, @intCast(fileOf(square)));
    const rank = @as(i32, @intCast(rankOf(square)));
    const offsets = [_][2]i32{
        .{ -2, -1 }, .{ -2, 1 }, .{ -1, -2 }, .{ -1, 2 },
        .{ 1, -2 },  .{ 1, 2 },  .{ 2, -1 },  .{ 2, 1 },
    };

    for (offsets) |offset| {
        result |= squareAt(file + offset[0], rank + offset[1]);
    }

    return result;
}

pub fn kingAttacks(square: usize) u64 {
    var result: u64 = 0;
    const file = @as(i32, @intCast(fileOf(square)));
    const rank = @as(i32, @intCast(rankOf(square)));
    const offsets = [_][2]i32{
        .{ -1, -1 }, .{ -1, 0 }, .{ -1, 1 },
        .{ 0, -1 },  .{ 0, 1 },  .{ 1, -1 },
        .{ 1, 0 },   .{ 1, 1 },
    };

    for (offsets) |offset| {
        result |= squareAt(file + offset[0], rank + offset[1]);
    }

    return result;
}

pub fn squareAt(file: i32, rank: i32) u64 {
    if (file < 0 or file >= 8 or rank < 0 or rank >= 8) {
        return 0;
    }

    return squareBb(@as(usize, @intCast(rank * 8 + file)));
}

pub fn safeDestination(square: usize, step: i8) u64 {
    const target = @as(i32, @intCast(square)) + step;
    if (target < 0 or target >= 64) {
        return 0;
    }

    const diff = absDiff(fileOf(square), fileOf(@intCast(target)));
    if (diff > 2) {
        return 0;
    }

    return squareBb(@intCast(target));
}

pub fn fileBb(square: usize) u64 {
    return file_a_bb << @as(u6, @intCast(fileOf(square)));
}

pub fn rankBb(square: usize) u64 {
    return rank_1_bb << @as(u6, @intCast(8 * rankOf(square)));
}

pub fn squareBb(square: usize) u64 {
    return @as(u64, 1) << @intCast(square);
}

pub fn rankOf(square: usize) usize {
    return square / 8;
}

pub fn fileOf(square: usize) usize {
    return square % 8;
}

pub fn absDiff(left: usize, right: usize) usize {
    return if (left > right) left - right else right - left;
}

pub fn magicIndexForPiece(pt: PieceType) usize {
    return @intFromEnum(pt) - @intFromEnum(PieceType.bishop);
}

pub fn lsb(bitboard: u64) usize {
    return @ctz(bitboard);
}

test {
    @import("std").testing.refAllDecls(@This());
}
