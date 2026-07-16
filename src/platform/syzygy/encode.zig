//! Syzygy position->index encoding geometry: the precomputed tables Stockfish's
//! `Tablebases::init` builds and `do_probe_table` indexes through -- Binomial coefficients, the
//! king-pair map (MapKK, 462 legal positions), the a1-d1-d4 / below-a1h8 square maps, and the
//! leading-pawn encoding (MapPawns / LeadPawnIdx / LeadPawnsSize). Pure board geometry: computed
//! once, no I/O, no engine types, so it is unit-testable against known mathematics on its own.
//! The verified geometry the WDL probe indexes through.

const std = @import("std");

// Square numbering matches SF: A1=0 .. H8=63; rank = sq>>3, file = sq&7.
inline fn rankOf(sq: usize) usize {
    return sq >> 3;
}
inline fn fileOf(sq: usize) usize {
    return sq & 7;
}
inline fn makeSquare(f: usize, r: usize) usize {
    return r * 8 + f;
}
inline fn flipFile(sq: usize) usize {
    return sq ^ 7;
}
pub inline fn flipRank(sq: usize) usize {
    return sq ^ 56;
}
// off_A1H8(sq) = rank - file: <0 below the a1-h8 diagonal, 0 on it, >0 above.
pub inline fn offA1H8(sq: usize) i32 {
    return @as(i32, @intCast(rankOf(sq))) - @as(i32, @intCast(fileOf(sq)));
}
pub inline fn edgeDistance(f: usize) usize {
    return @min(f, 7 - f);
}
// King "touch": s2 == s1 or s2 is a king move from s1 (Chebyshev distance <= 1).
inline fn kingTouch(s1: usize, s2: usize) bool {
    const df = @abs(@as(i32, @intCast(fileOf(s1))) - @as(i32, @intCast(fileOf(s2))));
    const dr = @abs(@as(i32, @intCast(rankOf(s1))) - @as(i32, @intCast(rankOf(s2))));
    return df <= 1 and dr <= 1;
}

const sq_d4: usize = makeSquare(3, 3); // FILE_D, RANK_4 (0-indexed rank 3) = 27

pub var map_b1h1h7: [64]i32 = undefined;
pub var map_a1d1d4: [64]i32 = undefined;
pub var map_kk: [10][64]i32 = undefined;
pub var binomial: [6][64]i32 = undefined; // [k][n] = C(n,k)
pub var map_pawns: [64]i32 = undefined;
pub var lead_pawn_idx: [6][64]i32 = undefined;
pub var lead_pawns_size: [6][4]i32 = undefined;
pub var kk_count: i32 = 0; // number of legal king-pair encodings assigned (== 462)

pub fn initGeometry() void {
    @memset(std.mem.asBytes(&map_b1h1h7), 0);
    @memset(std.mem.asBytes(&map_a1d1d4), 0);
    for (&map_kk) |*row| @memset(std.mem.asBytes(row), 0);
    for (&binomial) |*row| @memset(std.mem.asBytes(row), 0);
    @memset(std.mem.asBytes(&map_pawns), 0);
    for (&lead_pawn_idx) |*row| @memset(std.mem.asBytes(row), 0);
    for (&lead_pawns_size) |*row| @memset(std.mem.asBytes(row), 0);

    // MapB1H1H7: a square below the a1-h8 diagonal -> 0..27.
    var code: i32 = 0;
    var s: usize = 0;
    while (s < 64) : (s += 1) if (offA1H8(s) < 0) {
        map_b1h1h7[s] = code;
        code += 1;
    };

    // MapA1D1D4: a square in the a1-d1-d4 triangle -> 0..9 (diagonal squares last).
    var diagonal: [4]usize = undefined;
    var ndiag: usize = 0;
    code = 0;
    s = 0;
    while (s <= sq_d4) : (s += 1) {
        if (offA1H8(s) < 0 and fileOf(s) <= 3) {
            map_a1d1d4[s] = code;
            code += 1;
        } else if (offA1H8(s) == 0 and fileOf(s) <= 3) {
            diagonal[ndiag] = s;
            ndiag += 1;
        }
    }
    for (diagonal[0..ndiag]) |d| {
        map_a1d1d4[d] = code;
        code += 1;
    }

    // MapKK: the 462 legal positions of two kings, first in the a1-d1-d4 triangle.
    var both_on_diag: [64]struct { idx: usize, s2: usize } = undefined;
    var nboth: usize = 0;
    code = 0;
    var idx: usize = 0;
    while (idx < 10) : (idx += 1) {
        var s1: usize = 0;
        while (s1 <= sq_d4) : (s1 += 1) {
            if (!(map_a1d1d4[s1] == @as(i32, @intCast(idx)) and (idx != 0 or s1 == 1))) continue; // SQ_B1==1
            var s2: usize = 0;
            while (s2 < 64) : (s2 += 1) {
                if (kingTouch(s1, s2)) continue; // illegal (adjacent/same kings)
                if (offA1H8(s1) == 0 and offA1H8(s2) > 0) continue; // first on diag, second above
                if (offA1H8(s1) == 0 and offA1H8(s2) == 0) {
                    both_on_diag[nboth] = .{ .idx = idx, .s2 = s2 };
                    nboth += 1;
                } else {
                    map_kk[idx][s2] = code;
                    code += 1;
                }
            }
        }
    }
    for (both_on_diag[0..nboth]) |p| {
        map_kk[p.idx][p.s2] = code;
        code += 1;
    }
    kk_count = code;

    // Binomial[k][n] via Pascal's rule == C(n,k).
    binomial[0][0] = 1;
    var n: usize = 1;
    while (n < 64) : (n += 1) {
        var k: usize = 0;
        while (k < 6 and k <= n) : (k += 1) {
            binomial[k][n] = (if (k > 0) binomial[k - 1][n - 1] else 0) +
                (if (k < n) binomial[k][n - 1] else 0);
        }
    }

    // MapPawns (a2-h7 -> 0..47) + LeadPawnIdx/LeadPawnsSize (up to 5 leading pawns).
    var available: i32 = 47;
    var lead_cnt: usize = 1;
    while (lead_cnt <= 5) : (lead_cnt += 1) {
        var f: usize = 0;
        while (f <= 3) : (f += 1) { // FILE_A..FILE_D
            var pidx: i32 = 0;
            var r: usize = 1; // RANK_2 (0-indexed)
            while (r <= 6) : (r += 1) { // ..RANK_7
                const sq = makeSquare(f, r);
                if (lead_cnt == 1) {
                    map_pawns[sq] = available;
                    available -= 1;
                    map_pawns[flipFile(sq)] = available;
                    available -= 1;
                }
                lead_pawn_idx[lead_cnt][sq] = pidx;
                pidx += binomial[lead_cnt - 1][@intCast(map_pawns[sq])];
            }
            lead_pawns_size[lead_cnt][f] = pidx;
        }
    }
}

fn cnk(n: i64, k: i64) i64 {
    if (k < 0 or k > n) return 0;
    var num: i64 = 1;
    var den: i64 = 1;
    var i: i64 = 0;
    while (i < k) : (i += 1) {
        num *= (n - i);
        den *= (i + 1);
    }
    return @divTrunc(num, den);
}

test "Binomial[k][n] == C(n,k)" {
    initGeometry();
    var n: usize = 0;
    while (n < 64) : (n += 1) {
        var k: usize = 0;
        while (k < 6 and k <= n) : (k += 1)
            try std.testing.expectEqual(@as(i32, @intCast(cnk(@intCast(n), @intCast(k)))), binomial[k][n]);
    }
}

test "MapPawns encodes a2-h7 to 0..47 (a2=47, a3=45, h7=0-ish edge)" {
    initGeometry();
    try std.testing.expectEqual(@as(i32, 47), map_pawns[makeSquare(0, 1)]); // A2
    try std.testing.expectEqual(@as(i32, 45), map_pawns[makeSquare(0, 2)]); // A3
    try std.testing.expectEqual(@as(i32, 46), map_pawns[makeSquare(7, 1)]); // H2 (flip of A2)
    // every a2..h7 square gets a distinct value in 0..47
    var seen: [48]bool = @splat(false);
    var f: usize = 0;
    while (f < 8) : (f += 1) {
        var r: usize = 1;
        while (r <= 6) : (r += 1) {
            const v = map_pawns[makeSquare(f, r)];
            try std.testing.expect(v >= 0 and v < 48 and !seen[@intCast(v)]);
            seen[@intCast(v)] = true;
        }
    }
}

test "MapKK assigns exactly 462 legal king-pair encodings" {
    initGeometry();
    try std.testing.expectEqual(@as(i32, 462), kk_count);
}

test "MapA1D1D4 covers the 10 triangle squares 0..9" {
    initGeometry();
    var seen: [10]bool = @splat(false);
    var s: usize = 0;
    while (s <= sq_d4) : (s += 1) {
        if (fileOf(s) <= 3 and offA1H8(s) <= 0) {
            const v = map_a1d1d4[s];
            try std.testing.expect(v >= 0 and v < 10 and !seen[@intCast(v)]);
            seen[@intCast(v)] = true;
        }
    }
    for (seen) |b| try std.testing.expect(b);
}
