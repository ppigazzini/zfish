const std = @import("std");

// Geometry/magic-index helpers live in a std-only leaf now; alias back
// (top-level decls are order-independent).
const bitboard_geom = @import("bitboard_geom.zig");
const PieceType = bitboard_geom.PieceType;
const betweenSquares = bitboard_geom.betweenSquares;
const lineStep = bitboard_geom.lineStep;
const knightAttacks = bitboard_geom.knightAttacks;
const kingAttacks = bitboard_geom.kingAttacks;
const squareAt = bitboard_geom.squareAt;
const safeDestination = bitboard_geom.safeDestination;
const fileBb = bitboard_geom.fileBb;
const rankBb = bitboard_geom.rankBb;
const squareBb = bitboard_geom.squareBb;
const rankOf = bitboard_geom.rankOf;
const fileOf = bitboard_geom.fileOf;
const absDiff = bitboard_geom.absDiff;
const magicIndexForPiece = bitboard_geom.magicIndexForPiece;
const lsb = bitboard_geom.lsb;

pub const Magic = struct {
    mask: u64,
    attacks: [*]u64,
    magic: u64,
    shift: c_uint,
};

const knight_piece: u8 = 2;
const bishop_piece: u8 = 3;
const rook_piece: u8 = 4;
const queen_piece: u8 = 5;
const king_piece: u8 = 6;

// Runtime magic-bitboard attack tables (Stockfish-style): built once at startup by
// initSliderMagics() (invoked from position.initRuntime, before any position setup or
// search), read-only during search. The magic search builds each entry from the
// ray-cast slidingAttack reference, so attacksBb() returns bit-identical attack sets
// while replacing the per-node direction loop with an O(1) mask/multiply/shift/load.
// ~860 KB total; the single-threaded startup init is the only writer.
var rook_magic_attacks: [0x19000]u64 = undefined;
var bishop_magic_attacks: [0x1480]u64 = undefined;
var slider_magics: [64][2]Magic = undefined;

// Derived square-pair geometry, built once from the magics at startup and read-only during
// search -- the same tables upstream keeps (LineBB / BetweenBB / ray-pass). Without them
// line/between/rayPass each re-ray-cast on every call, and rayPass runs per slider per
// threat update per node.
var line_bb: [64][64]u64 = undefined;
var between_bb: [64][64]u64 = undefined;
var ray_pass_bb: [64][64]u64 = undefined;

// Leaper attack tables -- upstream's PseudoAttacks[KNIGHT|KING][s]. The generators in
// bitboard_geom walk eight offsets through a bounds-checked squareAt() per call, so
// without these attacks() re-derives a leaper attack set on every SEE, movegen and
// threat update. Built once here from those same generators, so the sets are identical.
var knight_attacks_bb: [64]u64 = undefined;
var king_attacks_bb: [64]u64 = undefined;

// Occupancy-free attack sets -- upstream's PseudoAttacks[pt][s]. A slider's empty-board
// reach depends only on its square, so deriving it through the magic pipeline (mask,
// multiply, shift, then a load from the ~860 KB attack table) re-computes a constant and
// touches cold memory. Upstream reads a 64-entry table; attacks_bb<Pt>(s) IS that read.
var pseudo_attacks_bb: [8][64]u64 = undefined;

pub fn initSliderMagics() void {
    initMagics(PieceType.rook, rook_magic_attacks[0..], &slider_magics);
    initMagics(PieceType.bishop, bishop_magic_attacks[0..], &slider_magics);
    initLeaperTables();
    initDerivedTables();
}

fn initLeaperTables() void {
    for (0..64) |s| {
        knight_attacks_bb[s] = knightAttacks(s);
        king_attacks_bb[s] = kingAttacks(s);
        const b = attacksBb(PieceType.bishop, s, 0, &slider_magics);
        const r = attacksBb(PieceType.rook, s, 0, &slider_magics);
        pseudo_attacks_bb[knight_piece][s] = knight_attacks_bb[s];
        pseudo_attacks_bb[bishop_piece][s] = b;
        pseudo_attacks_bb[rook_piece][s] = r;
        pseudo_attacks_bb[queen_piece][s] = b | r;
        pseudo_attacks_bb[king_piece][s] = king_attacks_bb[s];
    }
}

// Upstream's attacks_bb<Pt>(s): the empty-board attack set, one table read.
pub fn pseudoAttacks(piece_type: u8, square: u8) u64 {
    return pseudo_attacks_bb[piece_type][@as(usize, square)];
}

fn initDerivedTables() void {
    for (0..64) |s1| {
        for (0..64) |s2| {
            line_bb[s1][s2] = 0;
            between_bb[s1][s2] = 0;
            ray_pass_bb[s1][s2] = 0;
        }
    }
    for (0..64) |s1| {
        for (piece_types) |pt| {
            for (0..64) |s2| {
                if ((slidingAttack(pt, s1, 0) & squareBb(s2)) != 0) {
                    line_bb[s1][s2] =
                        (attacksBb(pt, s1, 0, &slider_magics) & attacksBb(pt, s2, 0, &slider_magics)) |
                        squareBb(s1) | squareBb(s2);
                    between_bb[s1][s2] = attacksBb(pt, s1, squareBb(s2), &slider_magics) &
                        attacksBb(pt, s2, squareBb(s1), &slider_magics);
                    ray_pass_bb[s1][s2] = attacksBb(pt, s1, 0, &slider_magics) &
                        (attacksBb(pt, s2, squareBb(s1), &slider_magics) | squareBb(s2));
                }
                between_bb[s1][s2] |= squareBb(s2);
            }
        }
    }
}

pub fn attacks(piece_type: u8, square: u8, occupied: u64) u64 {
    const sq = @as(usize, @intCast(square));
    return switch (piece_type) {
        knight_piece => knight_attacks_bb[sq],
        bishop_piece => attacksBb(PieceType.bishop, sq, occupied, &slider_magics),
        rook_piece => attacksBb(PieceType.rook, sq, occupied, &slider_magics),
        queen_piece => attacksBb(PieceType.bishop, sq, occupied, &slider_magics) |
            attacksBb(PieceType.rook, sq, occupied, &slider_magics),
        king_piece => king_attacks_bb[sq],
        else => 0,
    };
}

pub fn between(from: u8, to: u8) u64 {
    return between_bb[from][to];
}

// Full line through two squares (both endpoints + the ray extended to the board
// edges) if they are aligned, else 0. Mirrors upstream LineBB construction.
pub fn line(s1: u8, s2: u8) u64 {
    return line_bb[s1][s2];
}

// RayPassBB[s1][s2]: from s1's attacks along the s1-s2 line, the squares at or
// beyond s2 (s1 removed from the occupancy). Mirrors the upstream init formula.
pub fn rayPass(s1: u8, s2: u8) u64 {
    return ray_pass_bb[s1][s2];
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

const magic_is_64bit_index = false;

fn initMagics(pt: PieceType, table: []u64, magics: *[64][2]Magic) void {
    var occupancy: [4096]u64 = undefined;
    var epoch: [4096]c_int = @splat(0);
    var reference: [4096]u64 = @splat(0);
    var cnt: c_int = 0;
    var previous_size: usize = 0;
    const table_index = magicIndexForPiece(pt);

    for (0..64) |square| {
        const edges = ((rank_1_bb | rank_8_bb) & ~rankBb(square)) | ((file_a_bb | file_h_bb) & ~fileBb(square));
        var magic_ref = &magics[square][table_index];
        const attack_mask = slidingAttack(pt, square, 0);
        magic_ref.mask = attack_mask & ~edges;
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
            while (@popCount((magic_ref.magic *% magic_ref.mask) >> 56) < 6) {
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
    return @intCast(((occupied & magic_ref.mask) *% magic_ref.magic) >> @as(u6, @intCast(magic_ref.shift)));
}

fn slidingAttack(pt: PieceType, square: usize, occupied: u64) u64 {
    var result: u64 = 0;
    const directions = if (pt == PieceType.rook) rook_directions[0..] else bishop_directions[0..];
    for (directions) |direction| {
        var current = square;
        while (true) {
            const destination = safeDestination(current, direction);
            if (destination == 0) {
                break;
            }
            result |= destination;
            current = lsb(destination);
            if ((occupied & destination) != 0) {
                break;
            }
        }
    }
    return result;
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
        return self.state *% 2685821657736338717;
    }

    fn sparseRand(self: *Prng) u64 {
        return self.rand64() & self.rand64() & self.rand64();
    }
};

test {
    @import("std").testing.refAllDecls(@This());
}
