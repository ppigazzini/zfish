// Define the search's UCI-reporting seam.
//
// Hold a plain function pointer plus an opaque context pointer. Bind the four
// UCI-output callbacks (no-moves / full / iteration / bestmove), `*const fn (...) void`
// fields, to whatever owns the output sink (the UCIEngine), plus the three Info
// payload records they carry.
//
// The manager object those callbacks are reached from is `worker_layout.SearchManager`,
// embedded in the object graph the Worker points at; only the reporting seam lives here.
//
// Build and unit-test this module standalone.

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

// UpdateContext: hold four callbacks plus the opaque
// sink they write through (the UCIEngine output side). Make each callback a
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
