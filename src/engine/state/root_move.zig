// RootMove, PVMoves and RootPVMoves.
//
// Define the root-move list the search ranks and the two principal-variation carriers: the
// fixed one the search stack builds, and the growable one a root move owns.

const std = @import("std");

pub const max_ply = 246; // MAX_PLY
pub const value_infinite = 32001; // VALUE_INFINITE

pub const Move = u16; // raw Move word
pub const move_none: Move = 0;

// Bound the FIXED carrier. A node's PV is its own move plus the child's, so a search stopping
// at `max_ply` cannot build a longer one. The root list reserves against this name too
// (root_move_build), which is what keeps the two in step when `max_ply` moves.
pub const pv_capacity: usize = max_ply + 1;

// Hold the SEARCH STACK's PV: a fixed `pv_capacity` buffer plus a length. extern because
// worker_layout embeds one in the Worker graph (`last_iteration_pv`) and asserts its size.
pub const PVMoves = extern struct {
    moves: [pv_capacity]Move,
    length: usize,

    pub fn empty() PVMoves {
        return .{ .moves = undefined, .length = 0 };
    }
    pub fn pushBack(self: *PVMoves, m: Move) void {
        std.debug.assert(self.length < pv_capacity);
        self.moves[self.length] = m;
        self.length += 1;
    }
    pub fn clear(self: *PVMoves) void {
        self.length = 0;
    }
    pub fn slice(self: *const PVMoves) []const Move {
        return self.moves[0..self.length];
    }

    /// Take a ROOT pv, truncated to what this buffer holds -- upstream's
    /// `PVMoves& operator=(const RootPVMoves&)` (search.h:108), which is the only place the
    /// two carriers meet. MAX_PLY, not MAX_PLY+1: upstream clamps at the ply count.
    pub fn assignTruncated(self: *PVMoves, src: *const RootPVMoves) void {
        self.length = @min(src.length, max_ply);
        if (self.length != 0) @memcpy(self.moves[0..self.length], src.slice()[0..self.length]);
    }

    /// Reinterpret a raw Worker-graph address as a *PVMoves (worker_layout re-exports
    /// this type).
    pub inline fn fromAddr(addr: usize) *PVMoves {
        return @ptrFromInt(addr);
    }
};

comptime {
    // Pin the PVMoves footprint at 494 bytes of moves, padded to an 8-byte length -> 504.
    std.debug.assert(@sizeOf(PVMoves) == 504);
}

// Report a failed PV allocation the way upstream's report_failed_allocation does (memory.h):
// name the byte count and exit, never a signal. Restated rather than imported because this file
// is a POD leaf whose only dependency is std.
fn reportFailedAllocation(bytes: usize) noreturn {
    std.debug.print("Failed to allocate {d} bytes.\n", .{bytes});
    std.process.exit(1);
}

/// Hold a ROOT move's principal variation, which can outgrow MAX_PLY.
///
/// syzygyExtendPv walks a tablebase mate line move by move, and that walk ends at mate, at a
/// draw or at the clock -- never at a ply count, so a fixed buffer would truncate the answer
/// rather than bound it. Upstream's carrier is `struct RootPVMoves: public std::vector<Move>`
/// (search.h:64).
///
/// OWNING, and singly: each RootMove holds its own buffer, so a swap or a rotate of the
/// root-move list carries ownership with the element and needs no special case. Assignment is
/// therefore never a struct copy -- `copyFrom` is the deep copy upstream's vector assignment
/// is. extern so it stays legal as a field of the extern RootMove below.
pub const RootPVMoves = extern struct {
    items: ?[*]Move = null,
    length: usize = 0,
    capacity: usize = 0,

    // Bake the allocator in: an extern struct cannot carry one, and every list in the tree is
    // created and released by the same two owners (root_move_build for the engine's list,
    // thread.zig for each worker's copy), both of which allocate here.
    const allocator = std.heap.c_allocator;

    /// Reserve at least `n` moves. The search path never reaches the growth: the root list is
    /// built with `1 + pv_capacity` reserved, which is the longest PV `rootUpdate` can
    /// assemble -- its own move plus a full PVMoves from the child. Only the tablebase walk,
    /// which runs at emit time, can ask for more.
    pub fn reserve(self: *RootPVMoves, n: usize) void {
        if (n <= self.capacity) return;
        const want = @max(n, self.capacity * 2);
        const old: []Move = if (self.items) |p| p[0..self.capacity] else &[_]Move{};
        const grown = allocator.realloc(old, want) catch reportFailedAllocation(want * @sizeOf(Move));
        self.items = grown.ptr;
        self.capacity = grown.len;
    }

    pub fn pushBack(self: *RootPVMoves, m: Move) void {
        self.reserve(self.length + 1);
        self.items.?[self.length] = m;
        self.length += 1;
    }

    pub fn clear(self: *RootPVMoves) void {
        self.length = 0;
    }

    /// Shrink to `n`. SHRINK only, as upstream's `resize` asserts: growing here would publish
    /// moves past the ones written, which a caller then reports as PV.
    pub fn resize(self: *RootPVMoves, n: usize) void {
        std.debug.assert(n <= self.length);
        self.length = n;
    }

    pub fn isEmpty(self: *const RootPVMoves) bool {
        return self.length == 0;
    }

    /// Read move `i`, which the caller must have written -- an empty list holds no buffer at
    /// all, so `i < length` is a precondition and not a bound this checks in a release build.
    /// Type the ACCESSOR rather than exposing `items`: every caller wants pv[0] or pv[1], and
    /// none of them should be reaching for a pointer that may be null.
    pub fn at(self: *const RootPVMoves, i: usize) Move {
        std.debug.assert(i < self.length);
        return self.items.?[i];
    }

    pub fn slice(self: *const RootPVMoves) []const Move {
        if (self.items) |p| return p[0..self.length];
        return &.{};
    }

    /// Deep-copy `src` over this list -- upstream's vector assignment. Keeps this list's own
    /// buffer, growing it when the source is longer.
    pub fn copyFrom(self: *RootPVMoves, src: *const RootPVMoves) void {
        self.reserve(src.length);
        if (src.length != 0) @memcpy(self.items.?[0..src.length], src.slice());
        self.length = src.length;
    }

    pub fn deinit(self: *RootPVMoves) void {
        if (self.items) |p| allocator.free(p[0..self.capacity]);
        self.* = .{};
    }
};

// Pin the RootMove element size the strided rootMoves vector uses: the scalar head plus two
// RootPVMoves handles. This stride is paid by every rootMoves scan and every sort swap, which is
// why the PVs are held through a handle rather than inline.
pub const root_move_footprint: usize = 96;

// extern, in upstream's exact declared order (search.h:126-153): effort, then all the
// hot per-sort scalars together, then pv/previousPV last. A plain struct sorts by
// descending alignment, which put the two ~504B PVMoves fields in the SAME alignment
// class as `effort` (both align-8), floating `effort` away from the score cluster
// upstream declares it beside -- the same "hot scalar pulled into a cold field's
// alignment class" bug already found and fixed in WorkerLayout.
pub const RootMove = extern struct {
    effort: u64 = 0,
    score: i32 = -value_infinite,
    previous_score: i32 = -value_infinite,
    average_score: i32 = -value_infinite,
    mean_squared_score: i32 = -value_infinite * value_infinite,
    uci_score: i32 = -value_infinite,
    score_lowerbound: bool = false,
    score_upperbound: bool = false,
    // Mirror upstream's `bool previousScoreExact` (search.h:149), declared beside the
    // other two bound flags as upstream does. Gates the aborted-MultiPV score repair
    // (search.cpp:456).
    previous_score_exact: bool = false,
    sel_depth: i32 = 0,
    tb_rank: i32 = 0,
    tb_score: i32 = 0,
    // Mirror upstream's `RootPVMoves pv, previousPV;` (search.h:164), placed last as
    // upstream declares them. They are two distinct memories, not one: the follow-PV
    // heuristic needs THIS line's PV from the previous iteration
    // (rootMoves[pvIdx].previousPV), which rootMoves[0].pv cannot supply once MultiPV > 1.
    //
    // OWNING: every RootMove that is built must be `deinit`ed, and a copy of one is a
    // `copyFrom`, never a struct assignment -- two RootMoves must never name one buffer.
    pv: RootPVMoves = .{},
    previous_pv: RootPVMoves = .{},

    // Push m onto the pv in init(m).
    pub fn init(m: Move) RootMove {
        var rm = RootMove{};
        rm.pv.pushBack(m);
        return rm;
    }

    /// Release both PV buffers. Every creator of a RootMove list owns this call.
    pub fn deinit(self: *RootMove) void {
        self.pv.deinit();
        self.previous_pv.deinit();
    }

    /// Copy `src` onto this element, PV buffers included, without either sharing a buffer --
    /// what the per-worker fan-out of the root-move list needs.
    pub fn copyFrom(self: *RootMove, src: *const RootMove) void {
        // Hold THIS element's handles across the scalar copy and put them back: `self.* =
        // src.*` installs src's, and two RootMoves naming one buffer is a double free.
        var pv = self.pv;
        var previous_pv = self.previous_pv;
        pv.copyFrom(&src.pv);
        previous_pv.copyFrom(&src.previous_pv);
        self.* = src.*;
        self.pv = pv;
        self.previous_pv = previous_pv;
    }

    pub fn scoreIsBound(self: *const RootMove) bool {
        return self.score_lowerbound or self.score_upperbound;
    }
    pub fn unsetBoundFlags(self: *RootMove) void {
        self.score_lowerbound = false;
        self.score_upperbound = false;
    }
    // Report an exact (non-bound) proven loss, mirroring upstream's
    // `score_is_exact_loss()` (search.h:131). Take is_loss as a parameter: the loss
    // threshold lives in the search's value module, and this type stays free of it.
    pub fn scoreIsExactLoss(self: *const RootMove, is_loss: bool) bool {
        return self.score != -value_infinite and is_loss and !self.scoreIsBound();
    }
    pub fn eqMove(self: *const RootMove, m: Move) bool {
        return self.pv.at(0) == m;
    }
    // Sort descending by score, then previousScore.
    pub fn lessThan(_: void, a: RootMove, b: RootMove) bool {
        return if (b.score != a.score) b.score < a.score else b.previous_score < a.previous_score;
    }

    /// Reinterpret a raw rootMoves-vector element address as a *RootMove (worker_layout
    /// re-exports this type; the vector strides by @sizeOf(RootMove) == root_move_footprint).
    pub inline fn fromAddr(addr: usize) *RootMove {
        return @ptrFromInt(addr);
    }
};

comptime {
    // extern pins declaration order to upstream's; this assert keeps the element size
    // equal to the strided rootMoves vector element regardless. The footprint includes
    // previousPV and previousScoreExact, which upstream's RootMove also carries; the
    // assert catches a dropped field.
    std.debug.assert(@sizeOf(RootMove) == root_move_footprint);
}

// ---- tests ------------------------------------------------------------------

const testing = std.testing;

test "PVMoves and RootMove keep the strided element size" {
    try testing.expectEqual(@as(usize, 504), @sizeOf(PVMoves));
    try testing.expectEqual(root_move_footprint, @sizeOf(RootMove));
}

test "RootMove(Move) seeds the pv and defaults" {
    var rm = RootMove.init(0x1234);
    defer rm.deinit();
    try testing.expectEqual(@as(usize, 1), rm.pv.length);
    try testing.expectEqual(@as(Move, 0x1234), rm.pv.at(0));
    try testing.expectEqual(@as(i32, -value_infinite), rm.score);
    try testing.expect(rm.eqMove(0x1234));
    try testing.expect(!rm.scoreIsBound());
}

test "the root pv grows past the fixed buffer, and PVMoves takes it truncated" {
    // The tablebase walk ends at mate, a draw or the clock -- never at a ply count, which is
    // why the root carrier grows. The stack carrier does not, and takes what fits.
    var pv = RootPVMoves{};
    defer pv.deinit();
    var i: usize = 0;
    while (i < max_ply + 100) : (i += 1) pv.pushBack(@intCast(i & 0xffff));
    try testing.expectEqual(max_ply + 100, pv.length);
    try testing.expectEqual(@as(Move, max_ply + 99), pv.at(pv.length - 1));

    var fixed = PVMoves.empty();
    fixed.assignTruncated(&pv);
    try testing.expectEqual(@as(usize, max_ply), fixed.length);
    try testing.expectEqual(@as(Move, 0), fixed.moves[0]);
    try testing.expectEqual(@as(Move, max_ply - 1), fixed.moves[max_ply - 1]);
}

test "the reserve the root list is built with covers the longest search PV" {
    // rootUpdate keeps pv[0] and appends a whole PVMoves from the child, so the longest PV the
    // SEARCH can assemble is 1 + pv_capacity. Reserving that is what keeps the search path free
    // of allocation; only the tablebase walk asks for more.
    var pv = RootPVMoves{};
    defer pv.deinit();
    pv.reserve(1 + pv_capacity);
    const reserved = pv.capacity;
    var i: usize = 0;
    while (i < 1 + pv_capacity) : (i += 1) pv.pushBack(0);
    try testing.expectEqual(reserved, pv.capacity);
}

test "copyFrom deep-copies: the two lists never share a buffer" {
    var a = RootMove.init(7);
    defer a.deinit();
    a.pv.pushBack(8);
    var b = RootMove.init(1);
    defer b.deinit();

    b.copyFrom(&a);
    try testing.expectEqual(@as(usize, 2), b.pv.length);
    try testing.expect(b.pv.items.? != a.pv.items.?);
    a.pv.items.?[1] = 99;
    try testing.expectEqual(@as(Move, 8), b.pv.at(1));
}

test "RootMove sorts descending by score then previousScore" {
    var moves = [_]RootMove{
        RootMove.init(1), RootMove.init(2), RootMove.init(3),
    };
    defer for (&moves) |*m| m.deinit();
    moves[0].score = 10;
    moves[0].previous_score = 5;
    moves[1].score = 50;
    moves[2].score = 10;
    moves[2].previous_score = 9;
    std.sort.pdq(RootMove, &moves, {}, RootMove.lessThan);
    try testing.expectEqual(@as(i32, 50), moves[0].score);
    // break ties on score 10 by previousScore descending (9 before 5)
    try testing.expectEqual(@as(i32, 9), moves[1].previous_score);
    try testing.expectEqual(@as(i32, 5), moves[2].previous_score);
}

test "bound flags" {
    var rm = RootMove.init(0);
    defer rm.deinit();
    rm.score_lowerbound = true;
    try testing.expect(rm.scoreIsBound());
    rm.unsetBoundFlags();
    try testing.expect(!rm.scoreIsBound());
}
