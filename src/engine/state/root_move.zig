// RootMove and PVMoves.
//
// The root-move list the search ranks and the per-line principal variation.

const std = @import("std");

pub const max_ply = 246; // MAX_PLY
pub const value_infinite = 32001; // VALUE_INFINITE

pub const Move = u16; // raw Move word
pub const move_none: Move = 0;

// PVMoves: a fixed Move[MAX_PLY+1] buffer plus a length.
pub const PVMoves = struct {
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

    /// Reinterpret a raw Worker-graph address as a *PVMoves (graph_layout re-exports
    /// this type).
    pub inline fn fromAddr(addr: usize) *PVMoves {
        return @ptrFromInt(addr);
    }
};

comptime {
    // The PVMoves footprint is 494 bytes of moves, padded to an 8-byte length -> 504,
    // and the RootMove footprint is 552.
    std.debug.assert(@sizeOf(PVMoves) == 504);
}

pub const RootMove = struct {
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

    // init(m): pv.pushBack(m).
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
    // Descending sort: by score, then previousScore.
    pub fn lessThan(_: void, a: RootMove, b: RootMove) bool {
        return if (b.score != a.score) b.score < a.score else b.previous_score < a.previous_score;
    }

    /// Reinterpret a raw rootMoves-vector element address as a *RootMove (graph_layout
    /// re-exports this type; the vector strides by @sizeOf(RootMove) == 552).
    pub inline fn fromAddr(addr: usize) *RootMove {
        return @ptrFromInt(addr);
    }
};

comptime {
    // Zig owns the field order, but the element size must equal the strided rootMoves
    // vector element.
    std.debug.assert(@sizeOf(RootMove) == 552);
}

// ---- tests ------------------------------------------------------------------

const testing = std.testing;

test "PVMoves and RootMove keep the strided element size" {
    try testing.expectEqual(@as(usize, 504), @sizeOf(PVMoves));
    try testing.expectEqual(@as(usize, 552), @sizeOf(RootMove));
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
