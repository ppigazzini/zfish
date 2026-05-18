const std = @import("std");

pub const Magic = extern struct {
    mask: u64,
    attacks: [*]u64,
    magic: u64,
    shift: c_uint,
};

pub fn init(
    popcnt16: *[1 << 16]u8,
    square_distance: *[64][64]u8,
    line_bb: *[64][64]u64,
    between_bb: *[64][64]u64,
    ray_pass_bb: *[64][64]u64,
    magics: *[64][2]Magic,
    rook_table: [*]u64,
    bishop_table: [*]u64,
) void {
    for (0..(1 << 16)) |index| {
        popcnt16[index] = @intCast(@popCount(index));
    }

    for (0..64) |s1| {
        for (0..64) |s2| {
            const file_distance = absDiff(fileOf(s1), fileOf(s2));
            const rank_distance = absDiff(rankOf(s1), rankOf(s2));
            square_distance[s1][s2] = @intCast(@max(file_distance, rank_distance));
            line_bb[s1][s2] = 0;
            between_bb[s1][s2] = 0;
            ray_pass_bb[s1][s2] = 0;
        }
    }

    initMagics(PieceType.rook, rook_table[0..0x19000], magics);
    initMagics(PieceType.bishop, bishop_table[0..0x1480], magics);

    for (0..64) |s1| {
        for (piece_types) |pt| {
            for (0..64) |s2| {
                if ((pseudoAttacks(pt, s1) & squareBb(s2)) != 0) {
                    line_bb[s1][s2] =
                        (attacksBb(pt, s1, 0, magics) & attacksBb(pt, s2, 0, magics))
                        | squareBb(s1) | squareBb(s2);
                    between_bb[s1][s2] =
                        attacksBb(pt, s1, squareBb(s2), magics)
                        & attacksBb(pt, s2, squareBb(s1), magics);
                    ray_pass_bb[s1][s2] = attacksBb(pt, s1, 0, magics)
                        & (attacksBb(pt, s2, squareBb(s1), magics) | squareBb(s2));
                }
                between_bb[s1][s2] |= squareBb(s2);
            }
        }
    }
}

pub fn pretty(bitboard: u64) ?[*:0]u8 {
    return prettyAlloc(bitboard) catch null;
}

fn prettyAlloc(bitboard: u64) !?[*:0]u8 {
    const allocator = std.heap.c_allocator;
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(allocator);

    try buffer.appendSlice(allocator, "+---+---+---+---+---+---+---+---+\n");

    var rank: i32 = 7;
    while (true) : (rank -= 1) {
        for (0..8) |file| {
            const square = @as(usize, @intCast(rank * 8 + @as(i32, @intCast(file))));
            try buffer.appendSlice(allocator, if ((bitboard & squareBb(square)) != 0) "| X " else "|   ");
        }

        const label = try std.fmt.allocPrint(allocator, "| {d}\n+---+---+---+---+---+---+---+---+\n", .{rank + 1});
        defer allocator.free(label);
        try buffer.appendSlice(allocator, label);

        if (rank == 0) {
            break;
        }
    }

    try buffer.appendSlice(allocator, "  a   b   c   d   e   f   g   h\n");
    return try allocCString(buffer.items);
}

const PieceType = enum(u8) {
    bishop = 3,
    rook = 4,
};

const file_a_bb: u64 = 0x0101010101010101;
const file_h_bb: u64 = file_a_bb << 7;
const rank_1_bb: u64 = 0xff;
const rank_8_bb: u64 = rank_1_bb << (8 * 7);

const north: i8 = 8;
const east: i8 = 1;
const south: i8 = -north;
const west: i8 = -east;
const north_east: i8 = north + east;
const south_east: i8 = south + east;
const south_west: i8 = south + west;
const north_west: i8 = north + west;

const rook_directions = [_]i8{ north, south, east, west };
const bishop_directions = [_]i8{ north_east, south_east, south_west, north_west };
const piece_types = [_]PieceType{ PieceType.bishop, PieceType.rook };

const magic_seeds = [_][8]u64{
    .{ 8977, 44560, 54343, 38998, 5731, 95205, 104912, 17020 },
    .{ 728, 10316, 55013, 32803, 12281, 15100, 16645, 255 },
};

fn initMagics(pt: PieceType, table: []u64, magics: *[64][2]Magic) void {
    var occupancy: [4096]u64 = undefined;
    var epoch: [4096]c_int = [_]c_int{0} ** 4096;
    var reference: [4096]u64 = [_]u64{0} ** 4096;
    var cnt: c_int = 0;
    var previous_size: usize = 0;
    const table_index = magicIndexForPiece(pt);

    for (0..64) |square| {
        const edges = ((rank_1_bb | rank_8_bb) & ~rankBb(square))
            | ((file_a_bb | file_h_bb) & ~fileBb(square));
        var magic_ref = &magics[square][table_index];
        const attacks = slidingAttack(pt, square, 0);
        magic_ref.mask = attacks & ~edges;
        magic_ref.shift = @intCast(64 - @popCount(magic_ref.mask));
        magic_ref.attacks = if (square == 0)
            table.ptr
        else
            magics[square - 1][table_index].attacks + previous_size;

        var size: usize = 0;
        var subset: u64 = 0;
        while (true) {
            occupancy[size] = subset;
            reference[size] = slidingAttack(pt, square, subset);
            size += 1;
            subset = (subset -% magic_ref.mask) & magic_ref.mask;
            if (subset == 0) {
                break;
            }
        }

        var rng = Prng.init(magic_seeds[1][rankOf(square)]);
        while (true) {
            magic_ref.magic = 0;
            while (@popCount((magic_ref.magic * magic_ref.mask) >> 56) < 6) {
                magic_ref.magic = rng.sparseRand();
            }

            cnt += 1;
            var entry: usize = 0;
            while (entry < size) : (entry += 1) {
                const idx = computeMagicIndex(magic_ref.*, occupancy[entry]);
                if (epoch[idx] < cnt) {
                    epoch[idx] = cnt;
                    magic_ref.attacks[idx] = reference[entry];
                } else if (magic_ref.attacks[idx] != reference[entry]) {
                    break;
                }
            }

            if (entry == size) {
                break;
            }
        }

        previous_size = size;
    }
}

fn attacksBb(pt: PieceType, square: usize, occupied: u64, magics: *[64][2]Magic) u64 {
    const magic_ref = magics[square][magicIndexForPiece(pt)];
    return magic_ref.attacks[computeMagicIndex(magic_ref, occupied)];
}

fn computeMagicIndex(magic_ref: Magic, occupied: u64) usize {
    return @intCast(((occupied & magic_ref.mask) * magic_ref.magic) >> @as(u6, @intCast(magic_ref.shift)));
}

fn pseudoAttacks(pt: PieceType, square: usize) u64 {
    return slidingAttack(pt, square, 0);
}

fn slidingAttack(pt: PieceType, square: usize, occupied: u64) u64 {
    var attacks: u64 = 0;
    const directions = if (pt == PieceType.rook) rook_directions[0..] else bishop_directions[0..];
    for (directions) |direction| {
        var current = square;
        while (true) {
            const destination = safeDestination(current, direction);
            if (destination == 0) {
                break;
            }
            attacks |= destination;
            current = lsb(destination);
            if ((occupied & destination) != 0) {
                break;
            }
        }
    }
    return attacks;
}

fn safeDestination(square: usize, step: i8) u64 {
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

fn fileBb(square: usize) u64 {
    return file_a_bb << @as(u6, @intCast(fileOf(square)));
}

fn rankBb(square: usize) u64 {
    return rank_1_bb << @as(u6, @intCast(8 * rankOf(square)));
}

fn squareBb(square: usize) u64 {
    return @as(u64, 1) << @intCast(square);
}

fn rankOf(square: usize) usize {
    return square / 8;
}

fn fileOf(square: usize) usize {
    return square % 8;
}

fn absDiff(left: usize, right: usize) usize {
    return if (left > right) left - right else right - left;
}

fn magicIndexForPiece(pt: PieceType) usize {
    return @intFromEnum(pt) - @intFromEnum(PieceType.bishop);
}

fn lsb(bitboard: u64) usize {
    return @ctz(bitboard);
}

fn allocCString(value: []const u8) !?[*:0]u8 {
    const allocator = std.heap.c_allocator;
    const result = try allocator.allocSentinel(u8, value.len, 0);
    @memcpy(result[0..value.len], value);
    return result.ptr;
}

const Prng = struct {
    state: u64,

    fn init(seed: u64) Prng {
        return .{ .state = seed };
    }

    fn rand64(self: *Prng) u64 {
        self.state ^= self.state >> 12;
        self.state ^= self.state << 25;
        self.state ^= self.state >> 27;
        return self.state * 2685821657736338717;
    }

    fn sparseRand(self: *Prng) u64 {
        return self.rand64() & self.rand64() & self.rand64();
    }
};
