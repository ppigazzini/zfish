// SearchManager + UpdateContext.
//
//   * UpdateContext: a plain function pointer plus an opaque context pointer.
//     The four UCI-output callbacks (no-moves / full / iteration / bestmove)
//     are `*const fn (...) void` fields, bound to whatever owns
//     the output sink (the UCIEngine).
//
//   * SearchManager: a single struct with an `is_main` flag. Non-main workers
//     get a manager that simply does nothing on check_time; there is no vtable,
//     just a branch. Dispatch is a direct Zig call, resolved at the call site.
//
// This module is built and unit-tested standalone.

const std = @import("std");

pub const InfoShort = struct {
    depth: i32,
    score: i32,
};

pub const InfoFull = struct {
    short: InfoShort,
    sel_depth: i32,
    multi_pv: usize,
    wdl: []const u8,
    bound: []const u8,
    time_ms: usize,
    nodes: usize,
    nps: usize,
    tb_hits: usize,
    pv: []const u8,
    hashfull: i32,
};

pub const InfoIteration = struct {
    depth: i32,
    currmove: []const u8,
    currmovenumber: usize,
};

// UpdateContext: four callbacks plus the opaque
// sink they write through (the UCIEngine output side). Each callback is a
// C-ABI function pointer so the same vtable-free dispatch works whether the sink
// is implemented in Zig or handed across a C boundary.
pub const UpdateContext = struct {
    pub const NoMovesFn = *const fn (ctx: ?*anyopaque, info: *const InfoShort) void;
    pub const FullFn = *const fn (ctx: ?*anyopaque, info: *const InfoFull) void;
    pub const IterFn = *const fn (ctx: ?*anyopaque, info: *const InfoIteration) void;
    pub const BestmoveFn = *const fn (ctx: ?*anyopaque, bestmove: [*:0]const u8, ponder: [*:0]const u8) void;

    ctx: ?*anyopaque,
    on_update_no_moves: NoMovesFn,
    on_update_full: FullFn,
    on_iter: IterFn,
    on_bestmove: BestmoveFn,

    pub fn updateNoMoves(self: *const UpdateContext, info: *const InfoShort) void {
        self.on_update_no_moves(self.ctx, info);
    }
    pub fn updateFull(self: *const UpdateContext, info: *const InfoFull) void {
        self.on_update_full(self.ctx, info);
    }
    pub fn iter(self: *const UpdateContext, info: *const InfoIteration) void {
        self.on_iter(self.ctx, info);
    }
    pub fn bestmove(self: *const UpdateContext, best: [*:0]const u8, ponder: [*:0]const u8) void {
        self.on_bestmove(self.ctx, best, ponder);
    }
};

// The main thread gets a manager with is_main = true and
// a bound UpdateContext; non-main threads get one with is_main = false whose
// check_time is a no-op. No vtable -- a single branch in check_time.
pub const SearchManager = struct {
    is_main: bool,
    updates: *const UpdateContext,

    // Main-thread search bookkeeping.
    original_time_adjust: f64 = 0,
    calls_cnt: i32 = 0,
    ponder: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    iter_value: [4]i32 = .{ 0, 0, 0, 0 },
    previous_time_reduction: f64 = 0,
    best_previous_score: i32 = 0,
    best_previous_average_score: i32 = 0,
    stop_on_ponderhit: bool = false,
    id: usize = 0,

    pub fn initMain(updates: *const UpdateContext, id: usize) SearchManager {
        return .{ .is_main = true, .updates = updates, .id = id };
    }

    pub fn initNull(updates: *const UpdateContext) SearchManager {
        return .{ .is_main = false, .updates = updates };
    }

    // Non-main managers do nothing; main managers run the supplied CheckBody.
    pub fn checkTime(self: *SearchManager, comptime CheckBody: type) void {
        if (!self.is_main) return;
        CheckBody.run(self);
    }
};

// ---- tests ------------------------------------------------------------------

const testing = std.testing;

const Captured = struct {
    var full_nodes: usize = 0;
    var bestmove_seen: [64]u8 = undefined;
    var bestmove_len: usize = 0;
    var no_moves_score: i32 = 0;

    fn onNoMoves(ctx: ?*anyopaque, info: *const InfoShort) void {
        _ = ctx;
        no_moves_score = info.score;
    }
    fn onFull(ctx: ?*anyopaque, info: *const InfoFull) void {
        _ = ctx;
        full_nodes = info.nodes;
    }
    fn onIter(ctx: ?*anyopaque, info: *const InfoIteration) void {
        _ = ctx;
        _ = info;
    }
    fn onBestmove(ctx: ?*anyopaque, best: [*:0]const u8, ponder: [*:0]const u8) void {
        _ = ctx;
        _ = ponder;
        const s = std.mem.span(best);
        @memcpy(bestmove_seen[0..s.len], s);
        bestmove_len = s.len;
    }
};

fn testContext() UpdateContext {
    return .{
        .ctx = null,
        .on_update_no_moves = Captured.onNoMoves,
        .on_update_full = Captured.onFull,
        .on_iter = Captured.onIter,
        .on_bestmove = Captured.onBestmove,
    };
}

test "UpdateContext dispatches through function pointers" {
    const ctx = testContext();
    const full = InfoFull{
        .short = .{ .depth = 12, .score = 34 },
        .sel_depth = 15,
        .multi_pv = 1,
        .wdl = "",
        .bound = "",
        .time_ms = 100,
        .nodes = 123456,
        .nps = 1000,
        .tb_hits = 0,
        .pv = "e2e4 e7e5",
        .hashfull = 5,
    };
    ctx.updateFull(&full);
    try testing.expectEqual(@as(usize, 123456), Captured.full_nodes);

    const short = InfoShort{ .depth = 0, .score = -777 };
    ctx.updateNoMoves(&short);
    try testing.expectEqual(@as(i32, -777), Captured.no_moves_score);

    ctx.bestmove("d2d4", "g8f6");
    try testing.expectEqualStrings("d2d4", Captured.bestmove_seen[0..Captured.bestmove_len]);
}

test "non-main manager skips check_time (no vtable, just a branch)" {
    const ctx = testContext();
    const Body = struct {
        var ran: bool = false;
        fn run(_: *SearchManager) void {
            ran = true;
        }
    };

    var main_mgr = SearchManager.initMain(&ctx, 0);
    var null_mgr = SearchManager.initNull(&ctx);

    Body.ran = false;
    null_mgr.checkTime(Body);
    try testing.expect(!Body.ran); // non-main manager: no-op

    Body.ran = false;
    main_mgr.checkTime(Body);
    try testing.expect(Body.ran); // main thread runs the time check
}

test "SearchManager carries the main-thread bookkeeping" {
    const ctx = testContext();
    var mgr = SearchManager.initMain(&ctx, 7);
    try testing.expect(mgr.is_main);
    try testing.expectEqual(@as(usize, 7), mgr.id);
    mgr.ponder.store(true, .release);
    try testing.expect(mgr.ponder.load(.acquire));
}
