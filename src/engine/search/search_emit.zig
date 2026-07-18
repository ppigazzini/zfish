// Report search progress over UCI: the "info"/"bestmove" emission and MultiPV walk.
//
// Form the output half of the search driver -- everything that formats and prints a
// UCI line during search: the per-PV info line (searchEmitInfoFull), the MultiPV
// loop (searchPv + its PvContext), the mate/stalemate line, the bestmove/ponder
// line, and the "currmove" iteration line. Read the Worker graph + options and
// route text through uci_output; it has NO dependency on the search algorithm
// (searchImpl / qsearch / QCtx). Byte-exactly covered by
// the output-golden / driver-golden / search-parity gates.

const std = @import("std");
const time_source = @import("time_source");
const worker_layout = @import("worker_layout");
const tt = @import("tt");
const score_port = @import("score");
const uci_wdl = @import("uci_wdl");
const uci_output = @import("output_sink");
const uci_move_port = @import("uci_move");
const position_query = @import("position_query");
const option_port = @import("option_source");
const search_types = @import("search_types");

const RootMove = search_types.RootMove;
const isChess960 = position_query.isChess960;
const hasCheckers = position_query.hasCheckers;
const wdlMaterial = position_query.wdlMaterial;

// Provide trivial accessors; both are one-line reads of the Worker graph.
fn optInt(name: []const u8) i32 {
    return option_port.intByName(name);
}
fn workerRootMove0(wl: *const worker_layout.WorkerLayout) *worker_layout.RootMove {
    // Return the typed first RootMove via the graph adapter so callers read fields
    // directly instead of each re-doing RootMove.fromAddr; root_moves[0] is the
    // first element's address.
    return @ptrCast(wl.root_moves.ptr);
}
fn workerRootMoveAt(wl: *const worker_layout.WorkerLayout, index: usize) usize {
    // Return the i-th element's address (stride root_move_size); root_moves is a typed slice.
    return @intFromPtr(wl.root_moves.ptr) + index * worker_layout.root_move_size;
}
fn workerRootDepthOf(wl: *const worker_layout.WorkerLayout) i32 {
    return wl.root_depth;
}

// Format the score text (mate/tb-cp/cp) via the score classifier + the leaf uci_wdl formatters.
fn scoreTextAlloc(v: i32, material: i32) ?[:0]u8 {
    const sc = score_port.classify(v, 31507, 31753, 32000);
    return switch (sc.kind) {
        2 => uci_wdl.formatScore(0, sc.plies, 0),
        1 => uci_wdl.formatScore(1, sc.plies, sc.win),
        else => uci_wdl.formatScore(2, uci_wdl.toCp(v, material), 0),
    };
}

// Build + print one "info depth ... pv ..." line.
// Publish the whole-search node count to the shared leaf; no-op in quiet mode.
fn searchEmitInfoFull(manager: ?*worker_layout.SearchManager, worker: ?*worker_layout.WorkerLayout, move_index: usize, depth: i32, sel_depth: i32, multipv: usize, v: i32, show_wdl: u8, bound_kind: u8, nodes: u64, tb_hits: u64, hashfull: i32, time_ms: u64) void {
    _ = manager;
    uci_output.setLastNodesSearched(nodes);
    if (uci_output.isQuiet()) return;

    const w = worker.?;
    const ca = std.heap.c_allocator;
    const root_pos = &w.root_pos;
    const material = wdlMaterial(root_pos);
    const chess960 = isChess960(root_pos);

    const score_c = scoreTextAlloc(v, material) orelse return;
    defer ca.free(score_c);
    const score_text = score_c;

    const bound_text: []const u8 = switch (bound_kind) {
        1 => "lowerbound",
        2 => "upperbound",
        else => "",
    };

    var wdl_c: ?[:0]u8 = null;
    var wdl_text: []const u8 = "";
    if (show_wdl != 0) {
        wdl_c = uci_wdl.wdl(v, material);
        if (wdl_c) |wc| wdl_text = wc;
    }
    defer if (wdl_c) |wc| ca.free(wc);

    const rm = workerRootMoveAt(w, move_index);
    const pv = &worker_layout.RootMove.fromAddr(rm).pv;
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
    defer ca.free(line_c);
    uci_output.printLine(line_c.ptr, line_c.len);
}

// Emit for a checkmated/stalemated root: "info depth 0 score ..." + "bestmove (none)".
pub fn ssEmitNoMoves(worker: ?*worker_layout.WorkerLayout) void {
    if (uci_output.isQuiet()) return;
    const w = worker.?;
    const ca = std.heap.c_allocator;
    const root_pos = &w.root_pos;
    const v: i32 = if (hasCheckers(root_pos)) -32000 else 0;
    const material = wdlMaterial(root_pos);

    const score_c = scoreTextAlloc(v, material) orelse return;
    defer ca.free(score_c);
    const line_c = uci_wdl.formatInfoNoMoves(0, score_c) orelse return;
    defer ca.free(line_c);
    uci_output.printLine(line_c.ptr, line_c.len);

    const bm = "bestmove (none)";
    uci_output.printLine(bm.ptr, bm.len);
}

// Emit "bestmove X[ ponder Y]" from best's first RootMove PV. No-op in quiet mode.
pub fn ssEmitBestmove(worker: ?*worker_layout.WorkerLayout, best: ?*worker_layout.WorkerLayout) void {
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

// Emit "info depth D currmove M currmovenumber N" (main thread, past the node threshold).
pub fn searchCbRootOnIter(wl: *const worker_layout.WorkerLayout, depth: i32, move: u16, move_count: i32) void {
    if (wl.thread_idx != 0) return;
    if (uci_output.isQuiet()) return;
    const root_pos = &wl.root_pos;
    const chess960 = isChess960(root_pos);
    var mbuf: [5]u8 = undefined;
    const currmove = uci_move_port.renderMoveText(&mbuf, move, chess960);
    const currmovenumber: i32 = move_count + @as(i32, @intCast(wl.pv_idx));
    const line_c = uci_wdl.formatInfoIter(depth, currmove, currmovenumber) orelse return;
    defer std.heap.c_allocator.free(line_c);
    uci_output.printLine(line_c.ptr, line_c.len);
}

// Mirror SF is_mate_or_mated: |v| >= VALUE_MATE_IN_MAX_PLY (a real mate, not a TB win). Use it to decide
// whether the root-TB tbScore override applies (it does NOT override a genuine mate score).
fn isMateOrMated(v: i32) bool {
    const value_mate_in_max_ply: i32 = 32000 - 246; // VALUE_MATE - MAX_PLY
    return v >= value_mate_in_max_ply or v <= -value_mate_in_max_ply;
}

const PvContext = struct {
    manager: ?*worker_layout.SearchManager,
    worker: ?*worker_layout.WorkerLayout,
    root_moves: [*]const RootMove,
    root_moves_count: usize,
    root_in_tb: bool,
    multipv: usize,
    show_wdl: u8,
    chess960: u8,
    nodes: u64,
    tb_hits: u64,
    hashfull: i32,
    elapsed_ms: u64,
};
// Build the per-PV-emit context: root-move span, MultiPV/WDL options, chess960, pool nodes/tbhits,
// TT hashfull and elapsed ms. worker_layout + option + the pool aggregates.
fn searchCbPvContext(manager: ?*worker_layout.SearchManager, worker: ?*worker_layout.WorkerLayout, threads: *worker_layout.ThreadPool, tt_ptr: *worker_layout.TranspositionTable, out: *PvContext) void {
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
    out.nodes = worker_layout.poolNodesSearched(threads);
    // SF: reported tbHits == pool hits + (rootInTB ? rootMoves.size() : 0). Count the root-ranking
    // probes as one hit per root move at emit time (tb_config byte[4] = root_in_tb).
    out.root_in_tb = wl.tb_config[4] != 0;
    out.tb_hits = worker_layout.poolTbHits(threads) + (if (out.root_in_tb) rm_count else 0);

    const tp = tt_ptr;
    out.hashfull = tt.hashfull(@ptrFromInt(@intFromPtr(tp.table)), tp.cluster_count, tp.generation8, 0);

    const start_time = manager.?.tm.start_time;
    const elapsed = time_source.now() - start_time;
    out.elapsed_ms = @intCast(@max(@as(i64, 1), elapsed));
}

pub fn searchPv(manager: ?*worker_layout.SearchManager, worker: ?*worker_layout.WorkerLayout, threads: *worker_layout.ThreadPool, tt_ptr: *worker_layout.TranspositionTable, depth: i32) void {
    const value_infinite: i32 = 32001;
    var ctx: PvContext = undefined;
    searchCbPvContext(manager, worker, threads, tt_ptr, &ctx);
    var i: usize = 0;
    while (i < ctx.multipv) : (i += 1) {
        const rm = &ctx.root_moves[i];
        const use_prev = rm.score == -value_infinite;
        if (depth == 1 and use_prev and i > 0) continue;
        const d: i32 = if (use_prev) @max(@as(i32, 1), depth - 1) else depth;
        var v: i32 = if (use_prev) rm.previous_score else rm.uci_score;
        if (v == -value_infinite) v = 0;
        // SF: when the root is in a tablebase and the score isn't a real mate, show the exact
        // tbScore (the DTZ/WDL-derived value) instead of the search score. Gated by root_in_tb,
        // so non-TB searches (incl. bench) are unaffected.
        const is_tb_score = ctx.root_in_tb and !isMateOrMated(v);
        if (is_tb_score) v = rm.tb_score;
        var bound_kind: u8 = 0;
        // Treat TB scores as exact even if the root move's bound flags say otherwise.
        if (!use_prev and !is_tb_score) {
            if (rm.score_lowerbound) {
                bound_kind = 1;
            } else if (rm.score_upperbound) {
                bound_kind = 2;
            }
        }
        searchEmitInfoFull(ctx.manager, ctx.worker, i, d, @intCast(rm.sel_depth), i + 1, @intCast(v), ctx.show_wdl, bound_kind, ctx.nodes, ctx.tb_hits, ctx.hashfull, ctx.elapsed_ms);
    }
}

// Wrap emit_pv / search_id_pv as thin graph-only wrappers: resolve the worker's
// manager/threads/tt reference slots and drive the MultiPV emitter (searchPv).
pub fn ssEmitPv(worker: ?*worker_layout.WorkerLayout, best: ?*worker_layout.WorkerLayout) void {
    const wl = worker.?;
    searchPv(
        wl.manager,
        best,
        wl.threads,
        wl.tt,
        workerRootDepthOf(best.?),
    );
}
pub fn searchIdPv(worker: *worker_layout.WorkerLayout, depth: i32) void {
    const wl = worker;
    searchPv(
        wl.manager,
        worker,
        wl.threads,
        wl.tt,
        depth,
    );
}
