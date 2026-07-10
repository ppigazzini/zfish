// Search UCI reporting (M17.3x): the "info"/"bestmove" emission and MultiPV walk.
//
// The output half of the search driver -- everything that formats and prints a
// UCI line during search: the per-PV info line (searchEmitInfoFull), the MultiPV
// loop (searchPv + its PvContext), the mate/stalemate line, the bestmove/ponder
// line, and the "currmove" iteration line. Reads the Worker graph + options and
// routes text through uci_output; it has NO dependency on the search algorithm
// (searchImpl / qsearch / QCtx), so it splits cleanly out of search_driver.zig,
// which imports it and aliases the driver-facing emitters. Byte-exactly covered by
// the output-golden / driver-golden / search-parity gates.

const std = @import("std");
const clock = @import("clock");
const graph_layout = @import("graph_layout");
const tt = @import("tt");
const score_port = @import("score");
const uci_wdl = @import("uci_wdl");
const uci_output = @import("uci_output");
const uci_move_port = @import("uci_move");
const position_query = @import("position_query");
const option_port = @import("option");
const search_types = @import("search_types");

const RootMove = search_types.RootMove;
const isChess960 = position_query.isChess960;
const hasCheckers = position_query.hasCheckers;
const wdlMaterial = position_query.wdlMaterial;

// Trivial accessors duplicated from search_driver (a leaf cannot import the driver
// that imports it); both are one-line reads of the Worker graph.
fn optInt(name: []const u8) c_int {
    return option_port.intByName(name);
}
fn workerRootMove0(wl: *const graph_layout.WorkerLayout) *graph_layout.RootMove {
    // root_moves is the {begin,end,cap} vector header; [0] is the first element's
    // address. Return the typed first RootMove via the graph adapter so callers read
    // fields directly instead of each re-doing RootMove.fromAddr.
    return @ptrCast(wl.root_moves.ptr);
}
fn workerRootMoveAt(wl: *const graph_layout.WorkerLayout, index: usize) usize {
    // root_moves is a typed slice; the i-th element's address, stride root_move_size.
    return @intFromPtr(wl.root_moves.ptr) + index * graph_layout.root_move_size;
}
fn workerRootDepthOf(wl: *const graph_layout.WorkerLayout) c_int {
    return wl.root_depth;
}

// Score text (mate/tb-cp/cp) via the score classifier + the leaf uci_wdl formatters.
fn scoreTextAlloc(v: c_int, material: c_int) ?[*:0]u8 {
    const sc = score_port.classify(v, 31507, 31753, 32000);
    return switch (sc.kind) {
        2 => uci_wdl.formatScore(0, sc.plies, 0),
        1 => uci_wdl.formatScore(1, sc.plies, sc.win),
        else => uci_wdl.formatScore(2, uci_wdl.toCp(v, material), 0),
    };
}

// Build + print one "info depth ... pv ..." line.
// Publishes the whole-search node count to the shared leaf; no-op in quiet mode.
fn searchEmitInfoFull(manager: ?*graph_layout.SearchManager, worker: ?*graph_layout.WorkerLayout, move_index: usize, depth: c_int, sel_depth: c_int, multipv: usize, v: c_int, show_wdl: u8, bound_kind: u8, nodes: u64, tb_hits: u64, hashfull: c_int, time_ms: u64) void {
    _ = manager;
    uci_output.setLastNodesSearched(nodes);
    if (uci_output.isQuiet()) return;

    const w = worker.?;
    const ca = std.heap.c_allocator;
    const root_pos = &w.root_pos;
    const material = wdlMaterial(root_pos);
    const chess960 = isChess960(root_pos);

    const score_c = scoreTextAlloc(v, material) orelse return;
    defer ca.free(std.mem.span(score_c));
    const score_text = std.mem.span(score_c);

    const bound_text: []const u8 = switch (bound_kind) {
        1 => "lowerbound",
        2 => "upperbound",
        else => "",
    };

    var wdl_c: ?[*:0]u8 = null;
    var wdl_text: []const u8 = "";
    if (show_wdl != 0) {
        wdl_c = uci_wdl.wdl(v, material);
        if (wdl_c) |wc| wdl_text = std.mem.span(wc);
    }
    defer if (wdl_c) |wc| ca.free(std.mem.span(wc));

    const rm = workerRootMoveAt(w, move_index);
    const pv = &graph_layout.RootMove.fromAddr(rm).pv;
    const pv_len = pv.length;
    var pv_buf: [4096]u8 = undefined;
    var pv_n: usize = 0;
    var i: usize = 0;
    while (i < pv_len) : (i += 1) {
        if (i != 0) {
            pv_buf[pv_n] = ' ';
            pv_n += 1;
        }
        var mbuf: [5]u8 = undefined;
        const txt = uci_move_port.renderMoveText(&mbuf, pv.moves[i], chess960);
        @memcpy(pv_buf[pv_n..][0..txt.len], txt);
        pv_n += txt.len;
    }

    const nps: usize = if (time_ms != 0) @intCast(nodes * 1000 / time_ms) else 0;
    const line_c = uci_wdl.formatInfoFull(depth, sel_depth, multipv, score_text, bound_text, wdl_text, show_wdl, @intCast(nodes), nps, hashfull, @intCast(tb_hits), @intCast(time_ms), pv_buf[0..pv_n]) orelse return;
    defer ca.free(std.mem.span(line_c));
    const line = std.mem.span(line_c);
    uci_output.printLine(line.ptr, line.len);
}

// Checkmated/stalemated root: "info depth 0 score ..." + "bestmove (none)".
pub fn ssEmitNoMoves(worker: ?*graph_layout.WorkerLayout) void {
    if (uci_output.isQuiet()) return;
    const w = worker.?;
    const ca = std.heap.c_allocator;
    const root_pos = &w.root_pos;
    const v: c_int = if (hasCheckers(root_pos)) -32000 else 0;
    const material = wdlMaterial(root_pos);

    const score_c = scoreTextAlloc(v, material) orelse return;
    defer ca.free(std.mem.span(score_c));
    const line_c = uci_wdl.formatInfoNoMoves(0, std.mem.span(score_c)) orelse return;
    defer ca.free(std.mem.span(line_c));
    const line = std.mem.span(line_c);
    uci_output.printLine(line.ptr, line.len);

    const bm = "bestmove (none)";
    uci_output.printLine(bm.ptr, bm.len);
}

// "bestmove X[ ponder Y]" from best's first RootMove PV. No-op in quiet mode.
pub fn ssEmitBestmove(worker: ?*graph_layout.WorkerLayout, best: ?*graph_layout.WorkerLayout) void {
    if (uci_output.isQuiet()) return;
    const pv = &workerRootMove0(best.?).pv;
    const root_pos = &worker.?.root_pos;
    const chess960 = isChess960(root_pos);

    var buf0: [5]u8 = undefined;
    const bestmove = uci_move_port.renderMoveText(&buf0, pv.moves[0], chess960);

    var line: [40]u8 = undefined;
    var n: usize = 0;
    @memcpy(line[n..][0..9], "bestmove ");
    n += 9;
    @memcpy(line[n..][0..bestmove.len], bestmove);
    n += bestmove.len;
    if (pv.length > 1) {
        var buf1: [5]u8 = undefined;
        const ponder = uci_move_port.renderMoveText(&buf1, pv.moves[1], chess960);
        @memcpy(line[n..][0..8], " ponder ");
        n += 8;
        @memcpy(line[n..][0..ponder.len], ponder);
        n += ponder.len;
    }
    uci_output.printLine(line[0..n].ptr, n);
}

// "info depth D currmove M currmovenumber N" (main thread, past the node threshold).
pub fn searchCbRootOnIter(wl: *const graph_layout.WorkerLayout, depth: c_int, move: u16, move_count: c_int) void {
    if (wl.thread_idx != 0) return;
    if (uci_output.isQuiet()) return;
    const root_pos = &wl.root_pos;
    const chess960 = isChess960(root_pos);
    var mbuf: [5]u8 = undefined;
    const currmove = uci_move_port.renderMoveText(&mbuf, move, chess960);
    const currmovenumber: c_int = move_count + @as(c_int, @intCast(wl.pv_idx));
    const line_c = uci_wdl.formatInfoIter(depth, currmove, currmovenumber) orelse return;
    defer std.heap.c_allocator.free(std.mem.span(line_c));
    const line = std.mem.span(line_c);
    uci_output.printLine(line.ptr, line.len);
}

const PvContext = struct {
    manager: ?*graph_layout.SearchManager,
    worker: ?*graph_layout.WorkerLayout,
    root_moves: [*]const RootMove,
    root_moves_count: usize,
    multipv: usize,
    show_wdl: u8,
    chess960: u8,
    nodes: u64,
    tb_hits: u64,
    hashfull: c_int,
    elapsed_ms: u64,
};
// Per-PV-emit context: root-move span, MultiPV/WDL options, chess960, pool nodes/tbhits,
// TT hashfull and elapsed ms. graph_layout + option + the leaf pool aggregates.
fn searchCbPvContext(manager: ?*graph_layout.SearchManager, worker: ?*graph_layout.WorkerLayout, threads: *graph_layout.ThreadPool, tt_ptr: *graph_layout.TranspositionTable, out: *PvContext) void {
    const wl = worker.?;
    const rm_count = wl.root_moves.len;

    const multipv_opt: usize = @intCast(@max(optInt("MultiPV"), 0));

    out.manager = manager;
    out.worker = worker;
    out.root_moves = wl.root_moves.ptr;
    out.root_moves_count = rm_count;
    out.multipv = @min(multipv_opt, rm_count);
    out.show_wdl = if (optInt("UCI_ShowWDL") != 0) 1 else 0;

    const root_pos = &wl.root_pos;
    out.chess960 = if (isChess960(root_pos)) 1 else 0;
    out.nodes = graph_layout.poolNodesSearched(threads);
    out.tb_hits = graph_layout.poolTbHits(threads);

    const tp = tt_ptr;
    out.hashfull = tt.hashfull(@ptrFromInt(@intFromPtr(tp.table)), tp.cluster_count, tp.generation8, 0);

    const start_time = manager.?.tm.start_time;
    const elapsed = clock.now() - start_time;
    out.elapsed_ms = @intCast(@max(@as(i64, 1), elapsed));
}

pub fn searchPv(manager: ?*graph_layout.SearchManager, worker: ?*graph_layout.WorkerLayout, threads: *graph_layout.ThreadPool, tt_ptr: *graph_layout.TranspositionTable, depth: c_int) void {
    const value_infinite: i32 = 32001;
    var ctx: PvContext = undefined;
    searchCbPvContext(manager, worker, threads, tt_ptr, &ctx);
    var i: usize = 0;
    while (i < ctx.multipv) : (i += 1) {
        const rm = &ctx.root_moves[i];
        const use_prev = rm.score == -value_infinite;
        if (depth == 1 and use_prev and i > 0) continue;
        const d: c_int = if (use_prev) @max(@as(c_int, 1), depth - 1) else depth;
        var v: i32 = if (use_prev) rm.previous_score else rm.uci_score;
        if (v == -value_infinite) v = 0;
        var bound_kind: u8 = 0;
        if (!use_prev) {
            if (rm.score_lowerbound) {
                bound_kind = 1;
            } else if (rm.score_upperbound) {
                bound_kind = 2;
            }
        }
        searchEmitInfoFull(ctx.manager, ctx.worker, i, d, @intCast(rm.sel_depth), i + 1, @intCast(v), ctx.show_wdl, bound_kind, ctx.nodes, ctx.tb_hits, ctx.hashfull, ctx.elapsed_ms);
    }
}

// emit_pv / search_id_pv: thin graph-only wrappers that resolve the worker's
// manager/threads/tt reference slots and drive the MultiPV emitter (searchPv).
pub fn ssEmitPv(worker: ?*graph_layout.WorkerLayout, best: ?*graph_layout.WorkerLayout) void {
    const wl = worker.?;
    searchPv(
        wl.manager,
        best,
        wl.threads,
        wl.tt,
        workerRootDepthOf(best.?),
    );
}
pub fn searchIdPv(worker: *graph_layout.WorkerLayout, depth: c_int) void {
    const wl = worker;
    searchPv(
        wl.manager,
        worker,
        wl.threads,
        wl.tt,
        depth,
    );
}
