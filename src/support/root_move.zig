// Native Zig RootMove and PVMoves.
//
// Part of the post-src/ object graph: the root-move list the search ranks and
// the per-line principal variation. Laid out byte-for-byte against the C++
// Search::RootMove / PVMoves so the native struct interoperates with the ported
// search during the transition, and stands on its own once src/ is gone.

const std = @import("std");

pub const max_ply = 246; // src/types.h MAX_PLY
pub const value_infinite = 32001; // src/types.h VALUE_INFINITE

pub const Move = u16; // Move::raw()
pub const move_none: Move = 0;

// PVMoves: a fixed Move[MAX_PLY+1] buffer plus a length, matching the C++ POD.
pub const PVMoves = extern struct {
    moves: [max_ply + 1]Move,
    length: usize,

    pub fn empty() PVMoves {
        return .{ .moves = undefined, .length = 0 };
    }
    pub fn pushBack(self: *PVMoves, m: Move) void {
        std.debug.assert(self.length < max_ply + 1);
        self.moves[self.length] = m;
        self.length += 1;
    }
    pub fn clear(self: *PVMoves) void {
        self.length = 0;
    }
    pub fn slice(self: *const PVMoves) []const Move {
        return self.moves[0..self.length];
    }
};

comptime {
    // Must reproduce the C++ PVMoves footprint (494 bytes of moves, padded to an
    // 8-byte length -> 504), and the RootMove footprint (552).
    std.debug.assert(@sizeOf(PVMoves) == 504);
}

pub const RootMove = extern struct {
    effort: u64 = 0,
    score: i32 = -value_infinite,
    previous_score: i32 = -value_infinite,
    average_score: i32 = -value_infinite,
    mean_squared_score: i32 = -value_infinite * value_infinite,
    uci_score: i32 = -value_infinite,
    score_lowerbound: bool = false,
    score_upperbound: bool = false,
    sel_depth: i32 = 0,
    tb_rank: i32 = 0,
    tb_score: i32 = 0,
    pv: PVMoves,

    // RootMove(Move m): pv.push_back(m).
    pub fn init(m: Move) RootMove {
        var rm = RootMove{ .pv = PVMoves.empty() };
        rm.pv.pushBack(m);
        return rm;
    }

    pub fn scoreIsBound(self: *const RootMove) bool {
        return self.score_lowerbound or self.score_upperbound;
    }
    pub fn unsetBoundFlags(self: *RootMove) void {
        self.score_lowerbound = false;
        self.score_upperbound = false;
    }
    pub fn eqMove(self: *const RootMove, m: Move) bool {
        return self.pv.moves[0] == m;
    }
    // Descending sort: by score, then previousScore (C++ operator<).
    pub fn lessThan(_: void, a: RootMove, b: RootMove) bool {
        return if (b.score != a.score) b.score < a.score else b.previous_score < a.previous_score;
    }
};

comptime {
    std.debug.assert(@sizeOf(RootMove) == 552);
    std.debug.assert(@offsetOf(RootMove, "pv") == 48);
}

// ---- tests ------------------------------------------------------------------

const testing = std.testing;

test "PVMoves and RootMove reproduce the C++ footprint" {
    try testing.expectEqual(@as(usize, 504), @sizeOf(PVMoves));
    try testing.expectEqual(@as(usize, 552), @sizeOf(RootMove));
    try testing.expectEqual(@as(usize, 48), @offsetOf(RootMove, "pv"));
}

test "RootMove(Move) seeds the pv and defaults" {
    const rm = RootMove.init(0x1234);
    try testing.expectEqual(@as(usize, 1), rm.pv.length);
    try testing.expectEqual(@as(Move, 0x1234), rm.pv.moves[0]);
    try testing.expectEqual(@as(i32, -value_infinite), rm.score);
    try testing.expect(rm.eqMove(0x1234));
    try testing.expect(!rm.scoreIsBound());
}

test "RootMove sorts descending by score then previousScore" {
    var moves = [_]RootMove{
        RootMove.init(1), RootMove.init(2), RootMove.init(3),
    };
    moves[0].score = 10;
    moves[0].previous_score = 5;
    moves[1].score = 50;
    moves[2].score = 10;
    moves[2].previous_score = 9;
    std.sort.pdq(RootMove, &moves, {}, RootMove.lessThan);
    try testing.expectEqual(@as(i32, 50), moves[0].score);
    // ties on score 10 break by previousScore descending (9 before 5)
    try testing.expectEqual(@as(i32, 9), moves[1].previous_score);
    try testing.expectEqual(@as(i32, 5), moves[2].previous_score);
}

test "bound flags" {
    var rm = RootMove.init(0);
    rm.score_lowerbound = true;
    try testing.expect(rm.scoreIsBound());
    rm.unsetBoundFlags();
    try testing.expect(!rm.scoreIsBound());
}
