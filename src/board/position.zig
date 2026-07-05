const std = @import("std");
const clock = @import("clock");
const graph_layout = @import("graph_layout");
const bitboard = @import("bitboard");
const movegen = @import("movegen");
const tt = @import("tt");
const movepick = @import("movepick");
const search = @import("search");
const nnue_acc = @import("nnue_accumulator");
const evaluate_mod = @import("evaluate");
const shared_hist = @import("shared_histories"); // native SharedHistories sizing (cut)
const shared_histories_map = @import("shared_histories_map"); // native sharedHists map (cut)

// Large-page allocator used by the native SharedHistories construction
// (mirrors C++ make_unique_large_page<T[]> over aligned_large_pages_alloc/free).
const memory = @import("memory");
const network_port = @import("network");
const position_snapshot_port = @import("position_snapshot");
const uci_output = @import("uci_output");
const uci_wdl = @import("uci_wdl");
const uci_move_port = @import("uci_move");
const score_port = @import("score");
const thread_vote = @import("thread_vote");
const native_thread = @import("native_thread");
const option_port = @import("option");
const timeman_port = @import("timeman");

// Force-compile the native StateInfo leaf node so its 192-byte layout assert is
// build-verified rather than dead source (part of the post-src/ object graph).
comptime {
    _ = @import("state_info.zig");
    // NOTE: state_list.zig (native `states` member) is build-verified via the
    // engine module (engine_graph.zig imports it as the EngineGraph.states type) —
    // a file may belong to only one module, so it is NOT force-compiled here.
}

const pawn_pt: u8 = 1;
const knight_pt: u8 = 2;
const bishop_pt: u8 = 3;
const rook_pt: u8 = 4;
const queen_pt: u8 = 5;
const king_pt: u8 = 6;
const color_white: u8 = 0;
const color_black: u8 = 1;

const file_a_bb: u64 = 0x0101010101010101;
const file_h_bb: u64 = 0x8080808080808080;

// MoveType (top 2 bits of the 16-bit move).
const mt_normal: u16 = 0;
const mt_promotion: u16 = 1 << 14;
const mt_en_passant: u16 = 2 << 14;
const mt_castling: u16 = 3 << 14;

inline fn sqBb(s: u8) u64 {
    return @as(u64, 1) << @intCast(s);
}
inline fn moveFrom(m: u16) u8 {
    return @intCast((m >> 6) & 0x3F);
}
inline fn moveTo(m: u16) u8 {
    return @intCast(m & 0x3F);
}
inline fn moveTypeOf(m: u16) u16 {
    return m & (3 << 14);
}
inline fn movePromotionType(m: u16) u8 {
    return @intCast(((m >> 12) & 3) + 2); // + KNIGHT
}
inline fn relativeSquare(c: u8, s: u8) u8 {
    return s ^ (c * 56);
}
inline fn makeSquare(f: u8, r: u8) u8 {
    return (r << 3) + f;
}
inline fn pieceTypeOn(pos: *const Position, s: u8) u8 {
    return pos.board[s] & 7;
}

// Memory mirror of the search Stack (src/search.h). Only the scalar fields used
// by ported search helpers are read; the layout/size must match for ss-N stack
// arithmetic.
pub const SearchStack = struct {
    pv: ?*anyopaque,
    continuation_history: ?*anyopaque,
    continuation_correction_history: ?*anyopaque,
    ply: c_int,
    current_move: u16,
    excluded_move: u16,
    static_eval: c_int,
    stat_score: c_int,
    move_count: c_int,
    in_check: bool,
    tt_pv: bool,
    tt_hit: bool,
    follow_pv: bool,
    cutoff_cnt: c_int,
    reduction: c_int,
};

// History-table dimensions (src/history.h, src/types.h).
const hist_color_nb: usize = 2;
const hist_uint16: usize = 65536;
const hist_low_ply: usize = 5;
const hist_piece_nb: usize = 16;
const hist_square_nb: usize = 64;
const hist_piece_type_nb: usize = 8;
const hist_pieceto: usize = hist_piece_nb * hist_square_nb; // PieceToHistory page = [16][64]

// Memory mirror of the leading data members of Search::Worker (src/search.h):
// the per-Worker history tables, which form a contiguous int16-array prefix
// (no vtable; mainHistory is at offset 0) followed by the shared-history
// reference. Only ever used through a pointer to the live C++ Worker, so the
// field order and sizes must byte-match the C++ class. The bridge proves the
// layout with offsetof static_asserts; this mirror lets ported search code
// address every table from one Worker pointer instead of per-call base passing.
pub const WorkerHistories = struct {
    main_history: [hist_color_nb * hist_uint16]i16, // ButterflyHistory [2][65536]
    low_ply_history: [hist_low_ply * hist_uint16]i16, // LowPlyHistory [5][65536]
    capture_history: [hist_piece_nb * hist_square_nb * hist_piece_type_nb]i16, // [16][64][8]
    continuation_history: [2 * 2 * hist_pieceto * hist_pieceto]i16, // [2][2] of [16][64]->[16][64]
    continuation_correction_history: [hist_pieceto * hist_pieceto]i16, // [16][64]->[16][64]
    tt_move_history: i16,
    shared_history: ?*anyopaque, // &SharedHistories
};

// Native offset of the Worker's shared_history reference (last WorkerHistories field).
// WorkerHistories is a native struct now, so the worker builder/reader use this rather
// than the old graph_layout.worker_off.shared_history C++ offset.
pub const worker_shared_history_off = @offsetOf(WorkerHistories, "shared_history");

// One CorrectionBundle (src/history.h): the four correction StatsEntry<int16>
// fields, one [2] page per correctionHistory index (indexed by color).
const CorrectionBundle = struct {
    pawn: i16,
    minor: i16,
    nonpawn_white: i16,
    nonpawn_black: i16,
};

// Memory mirror of SharedHistories (src/history.h), reached through the Worker
// mirror's shared_history pointer. correctionHistory and pawnHistory are each a
// DynStats { size_t size; T* data } (the LargePagePtr is a unique_ptr with a
// stateless deleter, so just an 8-byte pointer), followed by the two index
// masks. pawn page = [16][64] int16 (1024); correction page = [2]CorrectionBundle.
pub const SharedHistories = struct {
    corr_size: usize,
    corr_data: [*][2]CorrectionBundle,
    pawn_size: usize,
    pawn_data: [*]i16,
    size_minus1: usize,
    pawn_hist_size_minus1: usize,
};

inline fn sharedOf(w: *const WorkerHistories) *SharedHistories {
    return @ptrCast(@alignCast(w.shared_history.?));
}

// DynStats::clear_range numa partition of `size` entries: [start, end).
inline fn dynRange(size: usize, thread_idx: usize, numa_total: usize) struct { start: usize, end: usize } {
    const start = thread_idx * size / numa_total;
    const end = if (thread_idx + 1 == numa_total) size else (thread_idx + 1) * size / numa_total;
    return .{ .start = start, .end = end };
}

// SharedHistories clear_range pair from Worker::clear: correctionHistory entries
// (each [2]CorrectionBundle, 8 int16) filled to -6, pawnHistory pages (each a
// [16][64] int16 page) filled to -1262, over this thread's numa partition.
pub fn clearSharedHistory(shared_ptr: *anyopaque, thread_idx: usize, numa_total: usize) void {
    const shared: *SharedHistories = @ptrCast(@alignCast(shared_ptr));
    const corr_entry_i16: usize = @sizeOf([2]CorrectionBundle) / @sizeOf(i16);
    {
        const r = dynRange(shared.corr_size, thread_idx, numa_total);
        const base: [*]i16 = @ptrCast(@alignCast(shared.corr_data));
        var i = r.start * corr_entry_i16;
        const stop = r.end * corr_entry_i16;
        while (i < stop) : (i += 1) base[i] = -6;
    }
    {
        const r = dynRange(shared.pawn_size, thread_idx, numa_total);
        var i = r.start * hist_pieceto;
        const stop = r.end * hist_pieceto;
        while (i < stop) : (i += 1) shared.pawn_data[i] = -1262;
    }
}

// Native construction of one node's SharedHistories — the post-src/ replacement for
// the C++ ctor SharedHistories(threadCount) reached via try_emplace. Allocates the
// two DynStats arrays from large pages (corr: [2]CorrectionBundle elements; pawn:
// [16][64] int16 pages, exposed as a flat int16 array) and fills in the size fields +
// index masks. `thread_count` is nextPowerOfTwo(threads on the node), so the counts
// are powers of two and the masks are (count - 1). Element strides come from the same
// types the native search already reads C++-built histories through, so they match the
// C++ layout; the COUNT logic is shared with the shadow verifier (shared_histories.zig).
// UNWIRED: the live path still builds histories via the C++ try_emplace; this is the
// native builder the flip will call. Native-graph cut flip fire 2.
pub fn constructSharedHistories(thread_count: usize) error{OutOfMemory}!SharedHistories {
    const sizes = shared_hist.sharedHistoriesSizes(thread_count);
    const corr_bytes = sizes.corr * @sizeOf([2]CorrectionBundle);
    const pawn_bytes = sizes.pawn * hist_pieceto * @sizeOf(i16);

    const corr_ptr = memory.alignedLargePagesAlloc(corr_bytes) orelse return error.OutOfMemory;
    const pawn_ptr = memory.alignedLargePagesAlloc(pawn_bytes) orelse {
        memory.alignedLargePagesFree(corr_ptr); // don't leak corr if pawn alloc fails
        return error.OutOfMemory;
    };

    return .{
        .corr_size = sizes.corr,
        .corr_data = @ptrCast(@alignCast(corr_ptr)),
        .pawn_size = sizes.pawn,
        .pawn_data = @ptrCast(@alignCast(pawn_ptr)),
        .size_minus1 = sizes.corr - 1,
        .pawn_hist_size_minus1 = sizes.pawn - 1,
    };
}

// Release a SharedHistories' two large-page arrays — the free hook the native
// sharedHists map (SharedHistoriesMap) calls per element on erase/clear (~map<>).
pub fn deinitSharedHistories(sh: *SharedHistories) void {
    memory.alignedLargePagesFree(@ptrCast(sh.corr_data));
    memory.alignedLargePagesFree(@ptrCast(sh.pawn_data));
    sh.* = undefined;
}

// The native engine `sharedHists` member: NumaIndex -> SharedHistories, built with the
// large-page-backed construct/free hooks. UNWIRED until the atomic repoint.
pub const SharedHistoriesMap = shared_histories_map.SharedHistoriesMapOf(SharedHistories);

// Shadow verifier: read a constructed (C++ try_emplace) SharedHistories through the
// native mirror and confirm its four size fields match the native sizing for
// `thread_count`. Called at the live insert to diff the native logic against the
// oracle without changing behavior.
pub fn verifySharedHistories(shared_ptr: *const anyopaque, thread_count: usize) bool {
    const shared: *const SharedHistories = @ptrCast(@alignCast(shared_ptr));
    return shared_hist.verifySizes(
        shared.corr_size,
        shared.pawn_size,
        shared.size_minus1,
        shared.pawn_hist_size_minus1,
        thread_count,
    );
}

// pawn_entry(pos) row base: pawnHistory[pawn_key & mask] is a [16][64] page.
inline fn pawnEntryRow(shared: *SharedHistories, pos: *const Position) [*]i16 {
    const idx: usize = @intCast(pos.st.pawn_key & @as(u64, shared.pawn_hist_size_minus1));
    return shared.pawn_data + idx * hist_pieceto;
}

// update_quiet_histories addressed through the Worker + SharedHistories mirrors:
// the bridge passes only the Worker and Position pointers and the move, and Zig
// resolves mainHistory[us][move], lowPlyHistory[ply][move], and the pawn entry
// itself (no per-call base pointers from C++).
pub fn updateQuietHistoriesWorker(
    worker_ptr: *anyopaque,
    pos_ptr: *const anyopaque,
    ss_ptr: *anyopaque,
    move: u16,
    bonus: c_int,
) void {
    const w: *WorkerHistories = @ptrCast(@alignCast(worker_ptr));
    const pos: *const Position = @ptrCast(@alignCast(pos_ptr));
    const ss: *const SearchStack = @ptrCast(@alignCast(ss_ptr));
    const raw: usize = move;
    const main_entry = &w.main_history[@as(usize, pos.side_to_move) * hist_uint16 + raw];
    var lowply_entry: ?*i16 = null;
    if (ss.ply < 5) // LOW_PLY_HISTORY_SIZE
        lowply_entry = &w.low_ply_history[@as(usize, @intCast(ss.ply)) * hist_uint16 + raw];
    const pc = pos.board[moveFrom(move)];
    const to = moveTo(move);
    const pawn_entry = &pawnEntryRow(sharedOf(w), pos)[@as(usize, pc) * hist_square_nb + to];
    updateQuietHistories(main_entry, lowply_entry, pawn_entry, ss_ptr, pc, to, bonus);
}

// do_move / do_null_move continuation-history pointer setup, via the Worker
// mirror. Sets the Stack's continuation_history to &continuationHistory
// [in_check][capture][pc][to] (a PieceToHistory page) and continuation_
// correction_history to &continuationCorrectionHistory[pc][to]. The null move
// and the iterative_deepening sentinels pass all-zero indices (NO_PIECE), which
// resolve to the table bases. This moves the Worker-table address arithmetic
// out of the C++ do_move wrappers and into Zig ownership.
pub fn setContHist(worker_ptr: *anyopaque, ss_ptr: *anyopaque, in_check: u8, capture: u8, pc: u8, to: u8) void {
    const w: *WorkerHistories = @ptrCast(@alignCast(worker_ptr));
    const ss: *SearchStack = @ptrCast(@alignCast(ss_ptr));
    const ch_block = (@as(usize, in_check) * 2 + capture) * hist_pieceto +
        @as(usize, pc) * hist_square_nb + to;
    ss.continuation_history = @ptrCast(&w.continuation_history[ch_block * hist_pieceto]);
    const cc_block = @as(usize, pc) * hist_square_nb + to;
    ss.continuation_correction_history =
        @ptrCast(&w.continuation_correction_history[cc_block * hist_pieceto]);
}

// iterative_deepening() per-iteration main-history decay, now addressed through
// the Worker mirror: (v + 5) * 789 / 1024 toward zero over the whole table.
pub fn ageMainHistory(worker_ptr: *anyopaque) void {
    const w: *WorkerHistories = @ptrCast(@alignCast(worker_ptr));
    for (&w.main_history) |*e| {
        const v: c_int = e.*;
        e.* = @intCast(@divTrunc(v * 789, 1024)); // upstream 3c858c19e: drop the +5
    }
}

// iterative_deepening() per-search lowPlyHistory reset: lowPlyHistory.fill(100)
// over the whole [5][65536] table, via the Worker mirror.
pub fn fillLowPlyHistory(worker_ptr: *anyopaque) void {
    const w: *WorkerHistories = @ptrCast(@alignCast(worker_ptr));
    for (&w.low_ply_history) |*e| e.* = 100;
}

// Worker::clear() per-Worker history resets (the shared correction/pawn
// clear_range stays C++ for its numa partitioning, and the NNUE refreshTable is
// untouched). mainHistory=-5, captureHistory=-699, ttMoveHistory=0,
// continuationCorrectionHistory=5, continuationHistory=-552.
pub fn clearWorkerHistories(worker_ptr: *anyopaque) void {
    const w: *WorkerHistories = @ptrCast(@alignCast(worker_ptr));
    for (&w.main_history) |*e| e.* = -5;
    for (&w.capture_history) |*e| e.* = -699;
    w.tt_move_history = 0;
    for (&w.continuation_correction_history) |*e| e.* = 5;
    for (&w.continuation_history) |*e| e.* = -552;
}

fn captureStage(pos: *const Position, m: u16) bool {
    const cap = (pos.board[moveTo(m)] != 0 and moveTypeOf(m) != mt_castling) or
        moveTypeOf(m) == mt_en_passant;
    return cap or movePromotionType(m) == queen_pt;
}

inline fn moveIsOk(m: u16) bool {
    return m != 0 and m != 65; // != none() and != null()
}

// StatsEntry<int16, D>::operator<<(bonus): gravity update toward [-D, D].
inline fn statsUpdate(entry: *i16, bonus: c_int, comptime d: c_int) void {
    const clamped = @max(-d, @min(d, bonus));
    const val: c_int = entry.*;
    const abs_clamped = if (clamped < 0) -clamped else clamped;
    entry.* = @intCast(val + clamped - @divTrunc(val * abs_clamped, d));
}


// The bridge shim performs the C++ table lookups (mainHistory[us][move],
// lowPlyHistory, sharedHistory.pawn_entry) and hands Zig the int16 entry
// pointers; Zig owns the bonus scaling + gravity update sequence.
pub fn updateQuietHistories(
    main_entry: *i16,
    lowply_entry: ?*i16,
    pawn_entry: *i16,
    ss_ptr: *anyopaque,
    pc: u8,
    to: u8,
    bonus: c_int,
) void {
    statsUpdate(main_entry, bonus, 7183);
    if (lowply_entry) |e| statsUpdate(e, search.quietLowPlyScale(bonus), 7183);
    updateContinuationHistories(ss_ptr, pc, to, search.quietContScale(bonus));
    statsUpdate(pawn_entry, search.quietPawnScale(bonus), 8192);
}

const ConthistBonus = struct { i: u8, w: c_int };
const conthist_bonuses = [6]ConthistBonus{
    .{ .i = 1, .w = 1040 }, .{ .i = 2, .w = 780 }, .{ .i = 3, .w = 300 },
    .{ .i = 4, .w = 537 },  .{ .i = 5, .w = 129 }, .{ .i = 6, .w = 423 },
};

pub fn updateContinuationHistories(ss_ptr: *anyopaque, pc: u8, to: u8, bonus: c_int) void {
    const ss: *SearchStack = @ptrCast(@alignCast(ss_ptr));
    var positive_count: c_int = 0;
    for (conthist_bonuses) |b| {
        if (ss.in_check and b.i > 2) break;
        const ssi: *SearchStack = @ptrFromInt(@intFromPtr(ss) - @as(usize, b.i) * @sizeOf(SearchStack));
        if (moveIsOk(ssi.current_move)) {
            const cont: [*]i16 = @ptrCast(@alignCast(ssi.continuation_history.?));
            const entry = &cont[@as(usize, pc) * 64 + to]; // PieceToHistory[pc][to]
            if (entry.* > 0) positive_count += 1;
            const delta = search.conthistDelta(bonus, b.w, positive_count, @intCast(b.i));
            statsUpdate(entry, delta, 30000);
        }
    }
}

pub fn isShuffling(pos_ptr: *const anyopaque, ss_ptr: *const anyopaque, move: u16) bool {
    const pos: *const Position = @ptrCast(@alignCast(pos_ptr));
    const ss: *const SearchStack = @ptrCast(@alignCast(ss_ptr));
    if (captureStage(pos, move) or pos.st.rule50 < 10) return false;
    if (pos.st.plies_from_null < 6 or ss.ply < 20) return false;
    const ss2: *const SearchStack = @ptrFromInt(@intFromPtr(ss) - 2 * @sizeOf(SearchStack));
    const ss4: *const SearchStack = @ptrFromInt(@intFromPtr(ss) - 4 * @sizeOf(SearchStack));
    return moveFrom(move) == moveTo(ss2.current_move) and
        moveFrom(ss2.current_move) == moveTo(ss4.current_move);
}

// ======================= qsearch() (ported to Zig) =======================
// Mirrors Search::Worker::qsearch (src/search.cpp). Calls Zig-native TT
// (tt.probeTable/entrySave), MovePicker (movepick.nextMove), position
// predicates, and search-formula helpers directly; the accumulator-coupled
// do_move/undo_move/evaluate and the Worker-private nodes/selDepth go through
// C++ callbacks (zfish_search_cb_*). All history/correction tables are read
// from the Worker + SharedHistories mirrors.
const q_value_draw: c_int = 0;
const q_value_none: c_int = 32002;
const q_value_inf: c_int = 32001;
const q_value_mate: c_int = 32000;
const q_max_ply: c_int = 246;
const q_value_mate_in_max: c_int = q_value_mate - q_max_ply; // 31754
const q_value_tb: c_int = q_value_mate_in_max - 1; // 31753
const q_value_tb_win: c_int = q_value_tb - q_max_ply; // 31507
const q_depth_qs: c_int = 0;
const q_depth_unsearched: c_int = -2;
const q_depth_none: c_int = -3;
const q_bound_upper: u8 = 1;
const q_bound_lower: u8 = 2;
const q_mt_promotion: u16 = 1 << 14;

const q_piece_value = [16]c_int{ 0, 208, 781, 825, 1276, 2538, 0, 0, 0, 208, 781, 825, 1276, 2538, 0, 0 };

inline fn qIsValid(v: c_int) bool {
    return v != q_value_none;
}
inline fn qIsWin(v: c_int) bool {
    return v >= q_value_tb_win;
}
inline fn qIsLoss(v: c_int) bool {
    return v <= -q_value_tb_win;
}
inline fn qIsDecisive(v: c_int) bool {
    return qIsWin(v) or qIsLoss(v);
}
inline fn qMatedIn(ply: c_int) c_int {
    return -q_value_mate + ply;
}

// Memory mirror of Search::PVMoves (src/search.h): a Move array + length.
pub const PVMoves = struct {
    moves: [247]u16,
    length: usize,
};

// Memory mirror of Search::RootMove (src/search.h). RootMove is a standard-layout
// POD (its pv is the inline PVMoves, not a heap vector), so std::vector<RootMove>
// rootMoves is a contiguous array the Zig search indexes through a base pointer
// handed over by worker_state. Field order/types match the C++ declaration; the
// C ABI extern struct reproduces the same offsets.
pub const RootMove = struct {
    effort: u64,
    score: i32,
    previous_score: i32,
    average_score: i32,
    mean_squared_score: i32,
    uci_score: i32,
    score_lowerbound: bool,
    score_upperbound: bool,
    sel_depth: i32,
    tb_rank: i32,
    tb_score: i32,
    pv: PVMoves,
};
inline fn pvClear(pv: *PVMoves) void {
    pv.length = 0;
}
fn pvUpdate(pv: *PVMoves, move: u16, child: ?*PVMoves) void {
    const n: usize = if (child) |c| c.length else 0;
    if (child) |c| {
        var i: usize = 0;
        while (i < n) : (i += 1) pv.moves[i + 1] = c.moves[i];
    }
    pv.moves[0] = move;
    pv.length = n + 1;
}

// SearchManager::pv driver (default target). The C++ pv() delegates the multiPV
// info-line loop here; Zig derives each line's fields from the RootMove memory
// mirror and calls zfish_search_emit_info_full, which rebuilds InfoFull and
// routes it through the unchanged updates.onUpdateFull listener for byte-exact
// output. No tablebases in this build, so the upstream TB/syzygy branches never
// apply (rootInTB is always false).
const PvContext = struct {
    manager: ?*anyopaque,
    worker: ?*anyopaque,
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
// TT hashfull and elapsed ms. Relocated from main.zig (M16.7); graph_layout + option +
// the leaf pool aggregates, so no thread-module import (which would cycle).
fn searchCbPvContext(manager: ?*anyopaque, worker: ?*anyopaque, threads: ?*anyopaque, tt_ptr: ?*anyopaque, out: *PvContext) void {
    const w = @intFromPtr(worker.?);
    const rm_vec = w + graph_layout.worker_off.root_moves;
    const rm_begin = @as(*const usize, @ptrFromInt(rm_vec)).*;
    const rm_end = @as(*const usize, @ptrFromInt(rm_vec + 8)).*;
    const rm_count = (rm_end - rm_begin) / graph_layout.root_move_size;

    const multipv_opt: usize = @intCast(@max(optInt("MultiPV"), 0));

    out.manager = manager;
    out.worker = worker;
    out.root_moves = @ptrFromInt(rm_begin);
    out.root_moves_count = rm_count;
    out.multipv = @min(multipv_opt, rm_count);
    out.show_wdl = if (optInt("UCI_ShowWDL") != 0) 1 else 0;

    const root_pos: *const anyopaque = @ptrFromInt(w + graph_layout.worker_off.root_pos);
    out.chess960 = if (isChess960(root_pos)) 1 else 0;
    out.nodes = graph_layout.poolNodesSearched(threads.?);
    out.tb_hits = graph_layout.poolTbHits(threads.?);

    const tp = graph_layout.TranspositionTable.fromPtr(tt_ptr.?);
    out.hashfull = tt.hashfull(@ptrFromInt(@intFromPtr(tp.table)), tp.cluster_count, tp.generation8, 0);

    const start_time = graph_layout.SearchManager.fromPtr(manager.?).tm.start_time;
    const elapsed = clock.now() - start_time;
    out.elapsed_ms = @intCast(@max(@as(i64, 1), elapsed));
}
fn workerRootMoveAt(worker: *const anyopaque, index: usize) usize {
    const begin: *const usize = @ptrCast(@alignCast(@as([*]const u8, @ptrCast(worker)) + graph_layout.worker_off.root_moves));
    return begin.* + index * graph_layout.root_move_size;
}

// Score text (mate/tb-cp/cp) via the score classifier + the leaf uci_wdl formatters.
// Relocated from main.zig (M16.7).
fn scoreTextAlloc(v: c_int, material: c_int) ?[*:0]u8 {
    const sc = score_port.classify(v, 31507, 31753, 32000);
    return switch (sc.kind) {
        2 => uci_wdl.formatScore(0, sc.plies, 0),
        1 => uci_wdl.formatScore(1, sc.plies, sc.win),
        else => uci_wdl.formatScore(2, uci_wdl.toCp(v, material), 0),
    };
}

// Build + print one "info depth ... pv ..." line (relocated from main.zig, M16.7).
// Publishes the whole-search node count to the shared leaf; no-op in quiet mode.
fn searchEmitInfoFull(manager: ?*anyopaque, worker: ?*anyopaque, move_index: usize, depth: c_int, sel_depth: c_int, multipv: usize, v: c_int, show_wdl: u8, bound_kind: u8, nodes: u64, tb_hits: u64, hashfull: c_int, time_ms: u64) void {
    _ = manager;
    uci_output.setLastNodesSearched(nodes);
    if (uci_output.isQuiet()) return;

    const w = worker.?;
    const ca = std.heap.c_allocator;
    const root_pos: *const anyopaque = @ptrFromInt(@intFromPtr(w) + graph_layout.worker_off.root_pos);
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
fn ssEmitNoMoves(worker: ?*anyopaque) void {
    if (uci_output.isQuiet()) return;
    const w = worker.?;
    const ca = std.heap.c_allocator;
    const root_pos: *const anyopaque = @ptrFromInt(@intFromPtr(w) + graph_layout.worker_off.root_pos);
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
fn ssEmitBestmove(worker: ?*anyopaque, best: ?*anyopaque) void {
    if (uci_output.isQuiet()) return;
    const rm0 = workerRootMove0(best.?);
    const pv = &graph_layout.RootMove.fromAddr(rm0).pv;
    const root_pos: *const anyopaque = @ptrFromInt(@intFromPtr(worker.?) + graph_layout.worker_off.root_pos);
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
fn searchCbRootOnIter(worker: *const anyopaque, depth: c_int, move: u16, move_count: c_int) void {
    const thread_idx: *const usize = @ptrFromInt(@intFromPtr(worker) + graph_layout.worker_off.thread_idx);
    if (thread_idx.* != 0) return;
    if (uci_output.isQuiet()) return;
    const root_pos: *const anyopaque = @ptrFromInt(@intFromPtr(worker) + graph_layout.worker_off.root_pos);
    const chess960 = isChess960(root_pos);
    const pv_idx: *const usize = @ptrFromInt(@intFromPtr(worker) + graph_layout.worker_off.pv_idx);
    var mbuf: [5]u8 = undefined;
    const currmove = uci_move_port.renderMoveText(&mbuf, move, chess960);
    const currmovenumber: c_int = move_count + @as(c_int, @intCast(pv_idx.*));
    const line_c = uci_wdl.formatInfoIter(depth, currmove, currmovenumber) orelse return;
    defer std.heap.c_allocator.free(std.mem.span(line_c));
    const line = std.mem.span(line_c);
    uci_output.printLine(line.ptr, line.len);
}

fn zfish_search_pv(manager: ?*anyopaque, worker: ?*anyopaque, threads: ?*anyopaque, tt_ptr: ?*anyopaque, depth: c_int) void {
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

const SsCtx = struct {
    is_mainthread: u8,
    root_moves_empty: u8,
    npmsec: u8,
    limits_depth: i32,
    skill_enabled: u8,
};

// Search-manager driver callbacks that touch only the Worker graph (via graph_layout)
// + the accumulator stack — relocated from main.zig (M16.7). The driver
// (workerStartSearching) now calls them locally instead of through C-ABI. Callbacks that
// need the thread pool / options / timeman / uci output / network stay main-side bridges,
// since position sits below those layers (importing them would cycle).
fn workerThreadsPool(worker: *const anyopaque) usize {
    const p: *const usize = @ptrCast(@alignCast(@as([*]const u8, @ptrCast(worker)) + graph_layout.worker_off.threads));
    return p.*;
}
fn workerManager(worker: *const anyopaque) usize {
    const p: *const usize = @ptrCast(@alignCast(@as([*]const u8, @ptrCast(worker)) + graph_layout.worker_off.manager));
    return p.*;
}
fn workerRootMove0(worker: *const anyopaque) usize {
    const begin: *const usize = @ptrCast(@alignCast(@as([*]const u8, @ptrCast(worker)) + graph_layout.worker_off.root_moves));
    return begin.*;
}
fn workerTT(worker: *const anyopaque) usize {
    const p: *const usize = @ptrCast(@alignCast(@as([*]const u8, @ptrCast(worker)) + graph_layout.worker_off.tt));
    return p.*;
}

// Per-search reset: clear the worker's accumulator stack + last-iteration PV.
fn ssPrologue(worker: *anyopaque) void {
    const wb = @intFromPtr(worker);
    const acc_stack: *anyopaque = @ptrFromInt(wb + graph_layout.worker_off.accumulator_stack);
    nnue_acc.stackReset(acc_stack);
    graph_layout.PVMoves.fromAddr(wb + graph_layout.worker_off.last_iteration_pv).length = 0;
}

// Sum and reset each thread's worker bestMoveChanges (atomic u64), as a double.
fn searchIdCollectBmc(worker: *anyopaque) f64 {
    const tp = graph_layout.ThreadPool.fromAddr(@as(*const usize, @ptrFromInt(@intFromPtr(worker) + graph_layout.worker_off.threads)).*);
    const count = tp.numThreads();
    var tot: f64 = 0;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const thread = tp.threadAt(i);
        const wkr = graph_layout.Thread.fromAddr(thread).worker;
        const bmc: *u64 = @ptrFromInt(wkr + graph_layout.worker_off.best_move_changes);
        tot += @floatFromInt(bmc.*);
        bmc.* = 0;
    }
    return tot;
}

fn ssSetStop(worker: *anyopaque) void {
    const pool = workerThreadsPool(worker);
    graph_layout.ThreadPool.fromAddr(pool).stop = 1;
}

// !threads.stop && (manager->ponder || limits.infinite).
fn ssShouldBusywait(worker: *const anyopaque) u8 {
    const pool = workerThreadsPool(worker);
    if (graph_layout.ThreadPool.fromAddr(pool).stop != 0) return 0;
    const ponder = graph_layout.SearchManager.fromAddr(workerManager(worker)).ponder;
    const infinite = graph_layout.LimitsType.fromAddr(@intFromPtr(worker) + graph_layout.worker_off.limits).infinite;
    return if (ponder != 0 or infinite != 0) 1 else 0;
}

fn ssSetPrevScores(worker: *anyopaque, best: *const anyopaque) void {
    const rm0 = workerRootMove0(best);
    const rmv = graph_layout.RootMove.fromAddr(rm0);
    const sm = graph_layout.SearchManager.fromAddr(workerManager(worker));
    sm.best_previous_score = rmv.score;
    sm.best_previous_average_score = rmv.average_score;
}

// best->rootMoves[0].pv.size()==1 && extract_ponder_from_tt(worker->tt, worker->rootPos).
fn ssPvOneAndPonder(worker: *anyopaque, best: *anyopaque) u8 {
    const rm0 = workerRootMove0(best);
    const pv = &graph_layout.RootMove.fromAddr(rm0).pv;
    if (pv.length != 1) return 0;
    const tp = graph_layout.TranspositionTable.fromAddr(workerTT(worker));
    const pos: usize = @intFromPtr(worker) + graph_layout.worker_off.root_pos;
    return extractPonderFromTt(@ptrCast(pv), tp.table, tp.cluster_count, tp.generation8, @ptrFromInt(pos));
}

fn searchCbTtContext(worker: *const anyopaque, out_table: *?*anyopaque, out_cluster_count: *usize, out_generation: *u8) void {
    const tp = graph_layout.TranspositionTable.fromAddr(@as(*const usize, @ptrFromInt(@intFromPtr(worker) + graph_layout.worker_off.tt)).*);
    out_table.* = tp.table;
    out_cluster_count.* = tp.cluster_count;
    out_generation.* = tp.generation8;
}

fn optInt(name: []const u8) c_int {
    return option_port.zfish_optmodel_int_by_name(name.ptr, name.len);
}

// Per-search context flags read off the worker graph + the native OptionsModel.
fn ssContext(worker: *anyopaque, out: *SsCtx) void {
    const wbase = @intFromPtr(worker);
    const thread_idx = @as(*const usize, @ptrFromInt(wbase + graph_layout.worker_off.thread_idx)).*;
    const rm_begin = @as(*const usize, @ptrFromInt(wbase + graph_layout.worker_off.root_moves)).*;
    const rm_end = @as(*const usize, @ptrFromInt(wbase + graph_layout.worker_off.root_moves + 8)).*;
    const limits = wbase + graph_layout.worker_off.limits;
    const npmsec = graph_layout.LimitsType.fromAddr(limits).npmsec;

    const limit_strength = optInt("UCI_LimitStrength") != 0;
    const uci_elo: c_int = if (limit_strength) optInt("UCI_Elo") else 0;
    const skill_level = optInt("Skill Level");
    const skill_enabled = uci_elo != 0 or skill_level < 20;

    out.is_mainthread = @intFromBool(thread_idx == 0);
    out.root_moves_empty = @intFromBool(rm_begin == rm_end);
    out.npmsec = @intFromBool(npmsec != 0);
    out.limits_depth = graph_layout.LimitsType.fromAddr(limits).depth;
    out.skill_enabled = @intFromBool(skill_enabled);
}

// Per-search TimeManagement::init + TT::new_search (main thread). Builds the timeman
// input from the worker's limits/rootPos + the manager's tm, reads nodestime/Move
// Overhead/Ponder from the native model, writes the outputs back, and bumps the TT
// generation. Relocated from main.zig (M16.7).
fn ssTmInit(worker: *anyopaque) void {
    const wb = @intFromPtr(worker);
    const off = graph_layout.worker_off;
    const lim = graph_layout.LimitsType.fromAddr(wb + off.limits);
    const smgr = graph_layout.SearchManager.fromAddr(@as(*const usize, @ptrFromInt(wb + off.manager)).*);
    const tm = &smgr.tm;
    const root_pos: *const anyopaque = @ptrFromInt(wb + off.root_pos);

    const us: usize = sideToMove(root_pos);

    const input = timeman_port.TimemanInput{
        .time_us = lim.time[us],
        .inc_us = lim.inc[us],
        .start_time = lim.start_time,
        .npmsec = optInt("nodestime"),
        .move_overhead = optInt("Move Overhead"),
        .available_nodes = tm.available_nodes,
        .current_optimum_time = tm.optimum_time,
        .current_maximum_time = tm.maximum_time,
        .movestogo = lim.movestogo,
        .ply = gamePly(root_pos),
        .original_time_adjust = smgr.original_time_adjust,
        .ponder = @intFromBool(optInt("Ponder") != 0),
    };

    const out = timeman_port.init(input);

    tm.start_time = out.start_time;
    tm.optimum_time = out.optimum_time;
    tm.maximum_time = out.maximum_time;
    tm.available_nodes = out.available_nodes;
    tm.use_nodes_time = out.use_nodes_time;
    smgr.original_time_adjust = out.original_time_adjust;
    lim.time[us] = out.time_us;
    lim.inc[us] = out.inc_us;
    lim.npmsec = out.npmsec;

    const gen = &graph_layout.TranspositionTable.fromAddr(@as(*const usize, @ptrFromInt(wb + off.tt)).*).generation8;
    gen.* = tt.generationNext(gen.*);
}

// Skill level as a float: from UCI_Elo (interpolated) when UCI_LimitStrength is set,
// else the raw Skill Level option. Relocated from main.zig (M16.7).
fn skillLevel() f64 {
    const limit_strength = optInt("UCI_LimitStrength") != 0;
    const uci_elo: c_int = if (limit_strength) optInt("UCI_Elo") else 0;
    if (uci_elo != 0) {
        const e = @as(f64, @floatFromInt(uci_elo - 1320)) / @as(f64, 3190 - 1320);
        const raw = (((37.2473 * e - 40.8525) * e + 22.2943) * e - 0.311438);
        return std.math.clamp(raw, 0.0, 19.0);
    }
    return @floatFromInt(optInt("Skill Level"));
}

// Snapshot the iterative-deepening state (worker/pool member pointers + scalars) for
// the native search root loop. Relocated from main.zig (M16.7); graph reads + the
// native OptionsModel only.
fn searchIdState(worker: *anyopaque, out: *ZfishIdState) void {
    const wb = @intFromPtr(worker);
    const off = graph_layout.worker_off;
    const thread_idx = @as(*const usize, @ptrFromInt(wb + off.thread_idx)).*;
    const is_main = thread_idx == 0;
    const pool = @as(*const usize, @ptrFromInt(wb + off.threads)).*;
    const limits = wb + off.limits;

    const rm_begin = @as(*const usize, @ptrFromInt(wb + off.root_moves)).*;
    const rm_end = @as(*const usize, @ptrFromInt(wb + off.root_moves + 8)).*;
    const tp = graph_layout.ThreadPool.fromAddr(pool);

    out.root_pos = @ptrFromInt(wb + off.root_pos);
    out.root_moves = @ptrFromInt(rm_begin);
    out.pv_idx = @ptrFromInt(wb + off.pv_idx);
    out.pv_last = @ptrFromInt(wb + off.pv_last);
    out.sel_depth = @ptrFromInt(wb + off.sel_depth);
    out.root_depth = @ptrFromInt(wb + off.root_depth);
    out.root_delta = @ptrFromInt(wb + off.root_delta);
    out.optimism = @ptrFromInt(wb + off.optimism);
    out.nodes = @ptrFromInt(wb + off.nodes);
    out.stop = @ptrFromInt(@intFromPtr(&tp.stop));
    out.increase_depth = @ptrFromInt(@intFromPtr(&tp.increase_depth));
    out.last_iter_pv = @ptrFromInt(wb + off.last_iteration_pv);
    out.root_moves_count = (rm_end - rm_begin) / graph_layout.root_move_size;
    out.thread_idx = thread_idx;
    out.threads_size = tp.numThreads();
    out.multipv_option = @intCast(@max(optInt("MultiPV"), 0));
    out.limits_depth = graph_layout.LimitsType.fromAddr(limits).depth;
    out.limits_mate = graph_layout.LimitsType.fromAddr(limits).mate;
    const time_w = @as(*const i64, @ptrFromInt(limits + 24)).*;
    const time_b = @as(*const i64, @ptrFromInt(limits + 32)).*;
    out.use_time_management = @intFromBool(time_w != 0 or time_b != 0);
    out.is_main = @intFromBool(is_main);

    const sl = skillLevel();
    out.skill_level = sl;
    out.skill_enabled = @intFromBool(sl < 20.0);

    if (is_main) {
        const smgr = graph_layout.SearchManager.fromAddr(@as(*const usize, @ptrFromInt(wb + off.manager)).*);
        out.stop_on_ponderhit = @ptrCast(&smgr.stop_on_ponderhit);
        out.ponder = @ptrCast(&smgr.ponder);
        out.iter_value = @ptrCast(&smgr.iter_value);
        out.previous_time_reduction = @ptrCast(&smgr.previous_time_reduction);
        out.tm_optimum = smgr.tm.optimum_time;
        out.tm_maximum = smgr.tm.maximum_time;
        out.tm_start_time = smgr.tm.start_time;
        out.tm_use_nodes_time = smgr.tm.use_nodes_time;
        out.best_previous_score = smgr.best_previous_score;
        out.best_previous_average_score = smgr.best_previous_average_score;
    } else {
        // Non-main threads bail before the time-management block (`if (!main_thread)
        // continue;`), so these SearchManager/TM pointer fields are never dereferenced
        // for them. position's ZfishIdState types them non-optional, so use the worker
        // pointer as a harmless valid placeholder (the C++ path left them null/unused).
        out.stop_on_ponderhit = @ptrCast(worker);
        out.ponder = @ptrCast(worker);
        out.iter_value = @ptrCast(@alignCast(worker));
        out.previous_time_reduction = @ptrCast(@alignCast(worker));
        out.tm_optimum = 0;
        out.tm_maximum = 0;
        out.tm_start_time = 0;
        out.tm_use_nodes_time = 0;
        out.best_previous_score = 0;
        out.best_previous_average_score = 0;
    }
}

// Start / wait the sibling search threads. The driver reaches the native thread
// runtime directly now (M16.7): native_thread no longer imports position (its search
// job is a registered fn-pointer), so position can drive the pool without a cycle.
fn ssThreadsStart(worker: ?*anyopaque) void {
    native_thread.startPoolSiblings(workerRefPtr(worker.?, graph_layout.worker_off.threads).?);
}
fn ssWaitFinished(worker: ?*anyopaque) void {
    native_thread.waitPoolSiblings(workerRefPtr(worker.?, graph_layout.worker_off.threads).?);
}

// Worker of the vote-winning thread (Lazy-SMP best-thread selection via the leaf
// thread_vote model). Relocated from main.zig (M16.7).
fn ssGetBestThread(worker: ?*anyopaque) ?*anyopaque {
    const wb = @intFromPtr(worker.?);
    const pool = @as(*const usize, @ptrFromInt(wb + graph_layout.worker_off.threads)).*;
    return @ptrFromInt(thread_vote.bestThreadWorker(@ptrFromInt(pool)));
}

// Read a Worker reference slot (a pointer stored at worker+offset).
fn workerRefPtr(worker: *anyopaque, offset: usize) ?*anyopaque {
    const slot: *const ?*anyopaque = @ptrCast(@alignCast(@as([*]u8, @ptrCast(worker)) + offset));
    return slot.*;
}
fn workerRootDepthOf(worker: *anyopaque) c_int {
    const p: *const c_int = @ptrCast(@alignCast(@as([*]u8, @ptrCast(worker)) + graph_layout.worker_off.root_depth));
    return p.*;
}

// emit_pv / search_id_pv: thin graph-only wrappers that resolve the worker's
// manager/threads/tt reference slots and drive the local PV emitter (searchPv).
// Relocated from main.zig (M16.7).
fn ssEmitPv(worker: ?*anyopaque, best: ?*anyopaque) void {
    const w = worker.?;
    zfish_search_pv(
        workerRefPtr(w, graph_layout.worker_off.manager),
        best,
        workerRefPtr(w, graph_layout.worker_off.threads),
        workerRefPtr(w, graph_layout.worker_off.tt),
        workerRootDepthOf(best.?),
    );
}
fn searchIdPv(worker: *anyopaque, depth: c_int) void {
    zfish_search_pv(
        workerRefPtr(worker, graph_layout.worker_off.manager),
        worker,
        workerRefPtr(worker, graph_layout.worker_off.threads),
        workerRefPtr(worker, graph_layout.worker_off.tt),
        depth,
    );
}

// nodestime available-nodes advance (tm.advance_nodes_time). Relocated from main.zig (M16.7).
fn ssNpmsecAdvance(worker: *anyopaque) void {
    const wbase: [*]u8 = @ptrCast(worker);
    const off = graph_layout.worker_off;
    const manager = workerRefPtr(worker, off.manager).?;
    const avail = &graph_layout.SearchManager.fromPtr(manager).tm.available_nodes;
    const us: usize = sideToMove(@ptrCast(wbase + off.root_pos));
    const inc = graph_layout.LimitsType.fromAddr(@intFromPtr(wbase) + off.limits).inc[us];
    const nodes: i64 = @intCast(graph_layout.poolNodesSearched(workerRefPtr(worker, off.threads).?));
    avail.* = @max(@as(i64, 0), avail.* - (nodes - inc));
}

// Worker::start_searching control flow, ported from the bridge. Zig owns every
// branch and the sequencing; the C++ leaf helpers run the individual time-
// management, thread-pool, skill, and UCI-output operations.
pub fn workerStartSearching(worker: ?*anyopaque) void {
    ssPrologue(worker.?);

    var ctx: SsCtx = undefined;
    ssContext(worker.?, &ctx);

    if (ctx.is_mainthread == 0) {
        _ = iterativeDeepening(worker.?);
        return;
    }

    ssTmInit(worker.?);

    if (ctx.root_moves_empty != 0) {
        ssEmitNoMoves(worker);
        return;
    }

    ssThreadsStart(worker);
    var uci_pv_sent = iterativeDeepening(worker.?) != 0;

    while (ssShouldBusywait(worker.?) != 0) {}

    ssSetStop(worker.?);
    ssWaitFinished(worker);

    if (ctx.npmsec != 0) ssNpmsecAdvance(worker.?);

    var best = worker;
    if (ctx.limits_depth == 0 and ctx.skill_enabled == 0)
        best = ssGetBestThread(worker);

    ssSetPrevScores(worker.?, best.?);

    if (ssPvOneAndPonder(worker.?, best.?) != 0)
        uci_pv_sent = false;

    if (!uci_pv_sent or best != worker)
        ssEmitPv(worker, best);

    ssEmitBestmove(worker, best);
}


// One-shot fetch of the Worker state the inlined search needs, all stable for the
// whole search: the NNUE accumulator stack, the node counter, the (numa-resolved)
// Network, the accumulator-refresh cache, the optimism[2] array, and the three
// scalar Worker fields the search reads/writes directly — nmpMinPly, selDepth, and
// rootDepth. Cached in QCtx at entry so do_move/undo_move/evaluate and these scalar
// accesses touch no C++ (the accumulator push/pop, pos.do_move, and the network
// forward pass + eval scaling are all Zig-owned).
// Once-per-search snapshot of the Worker's live member pointers + shared stop flag,
// and -- on the main thread -- the SearchManager/TimeManagement/LimitsType time inputs.
// Relocated from main.zig (M16.7): graph_layout offset reads + the native FT pointer
// (the network handle is never dereferenced -- weights serve from native storage).
fn searchCbWorkerState(worker: *anyopaque, out_acc_stack: *?*anyopaque, out_nodes: *?*u64, out_network: *?*const anyopaque, out_cache: *?*anyopaque, out_optimism: *?*const [2]c_int, out_nmp_min_ply: *?*c_int, out_sel_depth: *?*c_int, out_root_depth: *?*c_int, out_reductions: *?[*]const c_int, out_root_delta: *?*const c_int, out_last_iter_pv: *?*const PVMoves, out_stop: *?*const u8, out_pv_idx: *?*const usize, out_root_moves: *?*anyopaque, out_pv_last: *?*const usize, out_best_move_changes: *?*u64, out_time: *SearchTimeState) void {
    const wb = @intFromPtr(worker);
    const off = graph_layout.worker_off;
    const pool = @as(*const usize, @ptrFromInt(wb + off.threads)).*;
    const stop_addr = @intFromPtr(&graph_layout.ThreadPool.fromAddr(pool).stop);

    out_acc_stack.* = @ptrFromInt(wb + off.accumulator_stack);
    out_nodes.* = @ptrFromInt(wb + off.nodes);
    out_network.* = network_port.nativeFtPtr();
    out_cache.* = @ptrFromInt(wb + off.refresh_table);
    out_optimism.* = @ptrFromInt(wb + off.optimism);
    out_nmp_min_ply.* = @ptrFromInt(wb + off.nmp_min_ply);
    out_sel_depth.* = @ptrFromInt(wb + off.sel_depth);
    out_root_depth.* = @ptrFromInt(wb + off.root_depth);
    out_reductions.* = @ptrFromInt(wb + off.reductions);
    out_root_delta.* = @ptrFromInt(wb + off.root_delta);
    out_last_iter_pv.* = @ptrFromInt(wb + off.last_iteration_pv);
    out_stop.* = @ptrFromInt(stop_addr);
    out_pv_idx.* = @ptrFromInt(wb + off.pv_idx);
    out_root_moves.* = @ptrFromInt(@as(*const usize, @ptrFromInt(wb + off.root_moves)).*);
    out_pv_last.* = @ptrFromInt(wb + off.pv_last);
    out_best_move_changes.* = @ptrFromInt(wb + off.best_move_changes);

    const thread_idx = @as(*const usize, @ptrFromInt(wb + off.thread_idx)).*;
    if (thread_idx == 0) {
        const smgr = graph_layout.SearchManager.fromAddr(@as(*const usize, @ptrFromInt(wb + off.manager)).*);
        const limits = wb + off.limits;
        out_time.calls_cnt = &smgr.calls_cnt;
        out_time.stop_write = @ptrFromInt(stop_addr);
        out_time.ponder = &smgr.ponder;
        out_time.stop_on_ponderhit = &smgr.stop_on_ponderhit;
        out_time.tm_start_time = smgr.tm.start_time;
        out_time.tm_maximum_time = smgr.tm.maximum_time;
        const lim = graph_layout.LimitsType.fromAddr(limits);
        out_time.lim_nodes = lim.nodes;
        out_time.lim_movetime = lim.movetime;
        out_time.tm_use_nodes_time = smgr.tm.use_nodes_time;
        out_time.use_time_management = @intFromBool(lim.time[0] != 0 or lim.time[1] != 0);
    } else {
        out_time.calls_cnt = null;
    }
}

// Zig-owned accumulator stack push/pop (defined in stockfish_zcu.o). push() bumps
// the stack and hands back pointers to the just-reserved DirtyPiece/DirtyThreats
// scratch that pos.do_move fills in; pop() drops the top entry.
const StackPushOutput = nnue_acc.StackPushOutput;

// Zig-owned NNUE forward pass + final eval scaling (defined in stockfish_zcu.o).
// network_evaluate runs the bucketed network and returns the scaled psqt/positional
// halves; eval_compute_value applies the optimism/material/rule50 blend.
const EvalOutput = struct {
    psqt: c_int,
    positional: c_int,
};
const EvalInput = struct {
    psqt: c_int,
    positional: c_int,
    optimism: c_int,
    material: c_int,
    rule50_count: c_int,
    value_tb_loss_in_max_ply: c_int,
    value_tb_win_in_max_ply: c_int,
};

// SearchManager::check_time inputs, fetched once per search tree by worker_state.
// Live (mutable) fields are pointers; fixed-per-search fields are snapshot values.
// calls_cnt is null when this worker is not the main thread (check_time is a
// main-thread-only operation), matching the C++ is_mainthread() gate.
const SearchTimeState = struct {
    calls_cnt: ?*c_int,
    stop_write: ?*u8,
    ponder: ?*const u8,
    stop_on_ponderhit: ?*const u8,
    tm_start_time: i64,
    tm_maximum_time: i64,
    lim_nodes: u64,
    lim_movetime: i64,
    tm_use_nodes_time: u8,
    use_time_management: u8,
};

// iterative_deepening state, snapshotted once at entry (skill-off path only; the
// C++ keeps the skill-enabled handicap path and remains the rebase body). Live
// fields are pointers into Worker/SearchManager/ThreadPool; the rest are values
// read once. Layout matches the bridge ZfishIdState exactly.
const ZfishIdState = struct {
    root_pos: *anyopaque,
    root_moves: [*]RootMove,
    pv_idx: *usize,
    pv_last: *usize,
    sel_depth: *c_int,
    root_depth: *c_int,
    root_delta: *c_int,
    optimism: *[2]c_int,
    nodes: *const u64,
    stop: *u8,
    increase_depth: *u8,
    stop_on_ponderhit: *u8,
    ponder: *const u8,
    iter_value: *[4]c_int,
    previous_time_reduction: *f64,
    last_iter_pv: *PVMoves,
    root_moves_count: usize,
    thread_idx: usize,
    threads_size: usize,
    multipv_option: usize,
    tm_optimum: i64,
    tm_maximum: i64,
    tm_start_time: i64,
    limits_depth: c_int,
    limits_mate: c_int,
    best_previous_score: c_int,
    best_previous_average_score: c_int,
    skill_level: f64,
    is_main: u8,
    use_time_management: u8,
    tm_use_nodes_time: u8,
    skill_enabled: u8,
};

const QCtx = struct {
    worker: *anyopaque,
    table: ?*anyopaque,
    cluster_count: usize,
    generation: u8,
    acc_stack: *anyopaque,
    nodes: *u64,
    network: *const anyopaque,
    cache: *anyopaque,
    optimism: *const [2]c_int,
    nmp_min_ply: *c_int,
    sel_depth: *c_int,
    root_depth: *c_int,
    reductions: [*]const c_int,
    root_delta: *const c_int,
    last_iter_pv: *const PVMoves,
    stop: *const u8,
    pv_idx: *const usize,
    root_moves: [*]RootMove,
    pv_last: *const usize,
    best_move_changes: *u64,
    time_state: SearchTimeState,
};

// Worker::update_seldepth inlined: selDepth tracks the deepest ply reached, used
// only for UCI reporting. Bumps the cached field when this ply is deeper.
inline fn updateSelDepth(ctx: *const QCtx, ply: c_int) void {
    if (ctx.sel_depth.* < ply + 1) ctx.sel_depth.* = ply + 1;
}

// Worker::reduction inlined: the LMR base reduction from the per-thread reductions
// table, the root delta, and the improving flag. Mirrors search.cpp exactly with
// C truncating integer division.
inline fn reductionAcc(ctx: *const QCtx, i: bool, d: c_int, mn: c_int, delta: c_int) c_int {
    const reduction_scale = ctx.reductions[@intCast(d)] * ctx.reductions[@intCast(mn)];
    return reduction_scale - @divTrunc(delta * 617, ctx.root_delta.*) +
        @divTrunc(@as(c_int, @intFromBool(!i)) * reduction_scale * 194, 512) + 1027;
}

// Worker::evaluate inlined: run the NNUE forward pass on the current position,
// then apply the eval scaling. Mirrors Eval::evaluate exactly — material is
// 534 * pawn count (both colours) + non-pawn material, optimism is indexed by the
// side to move, and the TB clamp bounds are ±VALUE_TB_WIN_IN_MAX_PLY.
inline fn evaluateAcc(ctx: *const QCtx, pos_ptr: *anyopaque) c_int {
    const pos: *const Position = @ptrCast(@alignCast(pos_ptr));
    const out = network_port.evaluate(ctx.network, pos_ptr, ctx.acc_stack, ctx.cache);
    const pawns = pos.piece_count[1] + pos.piece_count[9];
    const material = 534 * pawns + pos.st.non_pawn_material[0] + pos.st.non_pawn_material[1];
    return evaluate_mod.computeValue(.{
        .psqt = out.psqt,
        .positional = out.positional,
        .optimism = ctx.optimism[pos.side_to_move],
        .material = material,
        .rule50_count = pos.st.rule50,
        .value_tb_loss_in_max_ply = -q_value_tb_win,
        .value_tb_win_in_max_ply = q_value_tb_win,
    });
}

// Worker::do_move inlined: count the node, push a fresh accumulator slot, make the
// move (the Zig make-move records the dirty piece/threats into that slot), then set
// the Stack's current move and continuation-history pointer. Mirrors search.cpp
// do_move exactly; capture_stage is read pre-move, dirtyPiece.pc post-move.
inline fn doMoveAcc(ctx: *const QCtx, pos_ptr: *anyopaque, move: u16, st_ptr: *anyopaque, gives_check: u8, ss_ptr: *anyopaque) void {
    const pos: *Position = @ptrCast(@alignCast(pos_ptr));
    const ss: *SearchStack = @ptrCast(@alignCast(ss_ptr));
    const capture = captureStage(pos, move);
    ctx.nodes.* +%= 1;
    const out = nnue_acc.stackPush(ctx.acc_stack);
    doMove(pos_ptr, move, st_ptr, gives_check, out.dirty_piece, out.dirty_threats);
    const dp: *const DirtyPiece = @ptrCast(@alignCast(out.dirty_piece));
    ss.current_move = move;
    setContHist(ctx.worker, ss_ptr, @intFromBool(ss.in_check), @intFromBool(capture), dp.pc, moveTo(move));
}

// Worker::undo_move inlined: unmake the move, then drop the accumulator slot.
inline fn undoMoveAcc(ctx: *const QCtx, pos_ptr: *anyopaque, move: u16) void {
    undoMove(pos_ptr, move);
    nnue_acc.stackPop(ctx.acc_stack);
}

// Position-level verification make/unmake used by the qsearch TT-move cutoff.
// Mirrors Position::do_move(Move, StateInfo&): gives_check is computed here, a
// fresh DirtyThreats list and a throwaway DirtyPiece are passed as scratch (no
// accumulator slot is pushed, so the dirty state doMove writes is never
// consumed). undo is the plain Position-level unmake.
inline fn verifyDoMove(pos_ptr: *anyopaque, move: u16, st_ptr: *anyopaque) void {
    var dp: DirtyPiece = undefined;
    var dts: DirtyThreats = undefined;
    dts.list_size = 0;
    doMove(pos_ptr, move, st_ptr, @intFromBool(givesCheck(pos_ptr, move)), &dp, &dts);
}

inline fn verifyUndoMove(pos_ptr: *anyopaque, move: u16) void {
    undoMove(pos_ptr, move);
}

// M-FINAL cutover: native Position::do_move(Move, StateInfo&) for UCI move application
// (the bridge's zfish_position_do_move_state, used to apply `position ... moves`). Mirrors
// verifyDoMove: gives_check is computed here and scratch DirtyPiece/DirtyThreats are passed
// (during setup no accumulator slot consumes the dirty state). Replaces the C++
// Position::do_move in the default build.
pub fn doMoveState(pos_ptr: *anyopaque, move: u16, st_ptr: *anyopaque) void {
    var dp: DirtyPiece = undefined;
    var dts: DirtyThreats = undefined;
    dts.list_size = 0;
    doMove(pos_ptr, move, st_ptr, @intFromBool(givesCheck(pos_ptr, move)), &dp, &dts);
}

/// Allocate a zeroed Position block (M16.7 — was main.zig's zfish_position_create).
pub fn create() ?*anyopaque {
    const buf = std.c.malloc(graph_layout.position_size) orelse return null;
    @memset(@as([*]u8, @ptrCast(buf))[0..graph_layout.position_size], 0);
    return buf;
}
pub fn destroy(pos: ?*anyopaque) void {
    if (pos) |p| std.c.free(p);
}

/// setPosition with the engine-graph Position/StateInfo sizes filled in (M16.7 — lets callers
/// keep the old 5-arg zfish_position_set_state shape without threading graph sizes through).
pub fn setPositionState(pos_ptr: *anyopaque, fen_ptr: [*]const u8, fen_len: usize, chess960_enabled: u8, state_ptr: *anyopaque) ?[*:0]u8 {
    return setPosition(pos_ptr, fen_ptr, fen_len, chess960_enabled, state_ptr, graph_layout.position_size, graph_layout.state_info_size);
}

// Is `move` in the legal move list of the current position?
fn legalContains(pos_ptr: *const anyopaque, move: u16) bool {
    var buf: [256]u16 = undefined;
    const n = movegen.generateLegal(pos_ptr, &buf);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (buf[i] == move) return true;
    }
    return false;
}

// RootMove::extract_ponder_from_tt: make the best move, probe the TT for a reply
// stored there, append it to the PV if it is a legal move, unmake. Returns
// whether a ponder move was found (pv length > 1). The tt context (table base,
// cluster count, generation) is handed over by the bridge.
pub fn extractPonderFromTt(pv_ptr: *anyopaque, table: ?*anyopaque, cluster_count: usize, generation: u8, pos_ptr: *anyopaque) u8 {
    const pv: *PVMoves = @ptrCast(@alignCast(pv_ptr));
    const move = pv.moves[0];
    var st: StateInfo = undefined;
    verifyDoMove(pos_ptr, move, &st);
    if (!isDraw(pos_ptr, 1)) {
        const pos: *const Position = @ptrCast(@alignCast(pos_ptr));
        const key = adjustKey50(pos);
        const probe = tt.probeTable(table, cluster_count, key, generation, q_depth_none);
        const ttm = probe.data.move16;
        if (probe.found != 0 and ttm != 0 and legalContains(pos_ptr, ttm)) {
            pv.moves[pv.length] = ttm;
            pv.length += 1;
        }
    }
    verifyUndoMove(pos_ptr, move);
    return if (pv.length > 1) 1 else 0;
}

// correction_value(*this, pos, ss): gather the four shared correction values and
// the (ss-2)/(ss-4) continuation-correction values, then apply the Zig formula.
fn qCorrectionValue(w: *WorkerHistories, pos: *const Position, ss: *SearchStack) c_int {
    const shared = sharedOf(w);
    const us = pos.side_to_move;
    const pcv: c_int = corrBundle(shared, pos.st.pawn_key)[us].pawn;
    const micv: c_int = corrBundle(shared, pos.st.minor_piece_key)[us].minor;
    const wnpcv: c_int = corrBundle(shared, pos.st.non_pawn_key[0])[us].nonpawn_white;
    const bnpcv: c_int = corrBundle(shared, pos.st.non_pawn_key[1])[us].nonpawn_black;
    const ss1: *SearchStack = @ptrFromInt(@intFromPtr(ss) - @sizeOf(SearchStack));
    const m = ss1.current_move;
    var cch2: c_int = 0;
    var cch4: c_int = 0;
    const m_ok = moveIsOk(m);
    if (m_ok) {
        const to = moveTo(m);
        const idx = @as(usize, pos.board[to]) * 64 + to;
        const ss2: *SearchStack = @ptrFromInt(@intFromPtr(ss) - 2 * @sizeOf(SearchStack));
        const ss4: *SearchStack = @ptrFromInt(@intFromPtr(ss) - 4 * @sizeOf(SearchStack));
        const cc2: [*]i16 = @ptrCast(@alignCast(ss2.continuation_correction_history.?));
        const cc4: [*]i16 = @ptrCast(@alignCast(ss4.continuation_correction_history.?));
        cch2 = cc2[idx];
        cch4 = cc4[idx];
    }
    return search.correctionValue(pcv, micv, wnpcv, bnpcv, cch2, cch4, m_ok);
}

// pos.key() == adjust_key50(st->key): the rule50-adjusted Zobrist key the TT
// is indexed by (src/position.h). Near the 50-move boundary it perturbs the key
// so positions differing only in rule50 hash apart.
inline fn adjustKey50(pos: *const Position) u64 {
    const k = pos.st.key;
    if (pos.st.rule50 < 14) return k;
    const seed: u64 = @intCast(@divTrunc(pos.st.rule50 - 14, 8));
    return k ^ (seed *% 6364136223846793005 +% 1442695040888963407);
}

fn qsearchImpl(ctx: *const QCtx, pos_ptr: *anyopaque, ss_ptr: *anyopaque, alpha_in: c_int, beta: c_int, pv_node: bool) c_int {
    const w: *WorkerHistories = @ptrCast(@alignCast(ctx.worker));
    const pos: *Position = @ptrCast(@alignCast(pos_ptr));
    const ss: *SearchStack = @ptrCast(@alignCast(ss_ptr));
    const ss1: *SearchStack = @ptrFromInt(@intFromPtr(ss) - @sizeOf(SearchStack));
    const ss_next: *SearchStack = @ptrFromInt(@intFromPtr(ss) + @sizeOf(SearchStack));
    var alpha = alpha_in;

    // Upcoming-repetition draw.
    if (alpha < q_value_draw and upcomingRepetition(pos_ptr, ss.ply)) {
        alpha = search.valueDraw(ctx.nodes.*);
        if (alpha >= beta) return alpha;
    }

    var pv: PVMoves = undefined;
    var st: StateInfo = undefined;

    var best_move: u16 = 0;
    ss.in_check = pos.st.checkers_bb != 0;
    var move_count: c_int = 0;

    // Step 1. Initialize node (PV).
    if (pv_node) {
        ss_next.pv = @ptrCast(&pv);
        pvClear(@ptrCast(@alignCast(ss.pv.?)));
        updateSelDepth(ctx, ss.ply);
    }

    // Step 2. Immediate draw or max ply.
    if (isDraw(pos_ptr, ss.ply) or ss.ply >= q_max_ply) {
        if (ss.ply >= q_max_ply and !ss.in_check) return evaluateAcc(ctx, pos_ptr);
        return q_value_draw;
    }

    // Step 3. Transposition-table lookup.
    const pos_key = adjustKey50(pos);
    const probe = tt.probeTable(ctx.table, ctx.cluster_count, pos_key, ctx.generation, q_depth_none);
    const tt_hit = probe.found != 0;
    ss.tt_hit = tt_hit;
    const tt_move: u16 = if (tt_hit) probe.data.move16 else 0;
    const tt_value: c_int = if (tt_hit) search.valueFromTt(probe.data.value16, ss.ply, pos.st.rule50) else q_value_none;
    const tt_depth: c_int = probe.data.depth;
    const tt_bound: u8 = probe.data.bound;
    const tt_eval: c_int = probe.data.eval16;
    const pv_hit = tt_hit and probe.data.is_pv != 0;
    const writer: *tt.TtEntry = @ptrCast(@alignCast(probe.writer_ptr.?));

    if (!pv_node and tt_depth >= q_depth_qs and qIsValid(tt_value) and
        (tt_bound & (if (tt_value >= beta) q_bound_lower else q_bound_upper)) != 0)
        return tt_value;

    // Step 4. Static evaluation.
    var unadjusted_static_eval: c_int = q_value_none;
    var best_value: c_int = undefined;
    var futility_base: c_int = -q_value_inf;
    if (ss.in_check) {
        best_value = -q_value_inf;
    } else {
        const correction_value = qCorrectionValue(w, pos, ss);
        if (ss.tt_hit) {
            unadjusted_static_eval = tt_eval;
            if (!qIsValid(unadjusted_static_eval))
                unadjusted_static_eval = evaluateAcc(ctx, pos_ptr);
            ss.static_eval = search.toCorrectedStaticEval(unadjusted_static_eval, correction_value);
            best_value = ss.static_eval;
            if (qIsValid(tt_value) and !qIsDecisive(tt_value) and
                (tt_bound & (if (tt_value > best_value) q_bound_lower else q_bound_upper)) != 0)
                best_value = tt_value;
        } else {
            unadjusted_static_eval = evaluateAcc(ctx, pos_ptr);
            ss.static_eval = search.toCorrectedStaticEval(unadjusted_static_eval, correction_value);
            best_value = ss.static_eval;
        }

        // Stand pat.
        if (best_value >= beta) {
            if (!qIsDecisive(best_value)) best_value = search.qsearchStandPatBlend(best_value, beta);
            if (!ss.tt_hit)
                tt.entrySave(writer, pos_key, q_value_none, 0, q_bound_lower, q_depth_unsearched, q_depth_none, 0, unadjusted_static_eval, ctx.generation);
            return best_value;
        }
        if (best_value > alpha) alpha = best_value;
        futility_base = search.qsearchFutilityBase(ss.static_eval);
    }

    var cont_hist = [1]?*const anyopaque{ss1.continuation_history};
    const prev_sq: c_int = if (moveIsOk(ss1.current_move)) @intCast(moveTo(ss1.current_move)) else @as(c_int, sq_none);

    // Step 5. MovePicker (captures, or evasions when in check).
    var mp_moves: [256]movepick.SortEntry = undefined;
    const has_checkers = pos.st.checkers_bb != 0;
    const tt_pseudo = tt_move != 0 and pseudoLegal(pos_ptr, tt_move);
    var mp_state = movepick.MovePickerState{
        .tt_move_raw = tt_move,
        .stage = movepick.initMainStage(has_checkers, tt_pseudo, q_depth_qs),
        .threshold = 0,
        .depth = q_depth_qs,
        .skip_quiets = 0,
        .cur = 0,
        .end_cur = 0,
        .end_bad_captures = 0,
        .end_captures = 0,
        .end_generated = 0,
        .moves = &mp_moves,
    };
    const mp_ctx = movepick.MovePickerContext{
        .pos = pos_ptr,
        .main_history = @ptrCast(&w.main_history),
        .low_ply_history = @ptrCast(&w.low_ply_history),
        .capture_history = @ptrCast(&w.capture_history),
        .continuation_history = @ptrCast(&cont_hist),
        .shared_history = w.shared_history,
        .ply = ss.ply,
    };

    while (true) {
        const move = movepick.nextMove(&mp_state, &mp_ctx);
        if (move == 0) break;

        if (!legal(pos_ptr, move)) continue;

        const gc = givesCheck(pos_ptr, move);
        const capture = captureStage(pos, move);
        move_count += 1;

        // Step 6. Pruning.
        if (!qIsLoss(best_value)) {
            if (!gc and @as(c_int, moveTo(move)) != prev_sq and !qIsLoss(futility_base) and
                moveTypeOf(move) != q_mt_promotion)
            {
                if (move_count > 2) continue;
                const futility_value = futility_base + q_piece_value[pos.board[moveTo(move)]];
                if (futility_value <= alpha) {
                    if (futility_value > best_value) best_value = futility_value;
                    continue;
                }
                if (!seeGe(pos_ptr, move, alpha - futility_base)) {
                    const cap = if (alpha < futility_base) alpha else futility_base;
                    if (cap > best_value) best_value = cap;
                    continue;
                }
            }
            if (!capture) continue;
            if (!seeGe(pos_ptr, move, -74)) continue;
        }

        // Step 7. Make and search the move.
        doMoveAcc(ctx, pos_ptr, move, @ptrCast(&st), @intFromBool(gc), ss_ptr);
        const value = -qsearchImpl(ctx, pos_ptr, @ptrCast(ss_next), -beta, -alpha, pv_node);
        undoMoveAcc(ctx, pos_ptr, move);

        // Step 8. New best move.
        if (value > best_value) {
            best_value = value;
            if (value > alpha) {
                best_move = move;
                if (pv_node) pvUpdate(@ptrCast(@alignCast(ss.pv.?)), move, @ptrCast(@alignCast(ss_next.pv.?)));
                if (value < beta) alpha = value else break;
            }
        }
    }

    // Step 9. Mate / stalemate.
    if (move_count == 0) {
        if (ss.in_check) return qMatedIn(ss.ply);
        const us = pos.side_to_move;
        const pawns = pos.by_color_bb[us] & pos.by_type_bb[pawn_pt];
        const pushed = if (us == color_white) pawns << 8 else pawns >> 8;
        if ((pushed & ~pos.by_type_bb[0]) == 0 and pos.st.non_pawn_material[us] == 0 and
            (pos.st.captured_piece & 7) >= knight_pt)
        {
            var lbuf: [256]u16 = undefined;
            if (movegen.generateLegal(pos_ptr, &lbuf) == 0) best_value = q_value_draw;
        }
    }

    if (!qIsDecisive(best_value) and best_value > beta)
        best_value = search.qsearchFailHighBlend(best_value, beta);

    // Save to the transposition table.
    tt.entrySave(writer, pos_key, search.valueToTt(best_value, ss.ply), @intFromBool(pv_hit), if (best_value >= beta) q_bound_lower else q_bound_upper, q_depth_qs, q_depth_none, best_move, unadjusted_static_eval, ctx.generation);

    return best_value;
}

// Fetch the stable per-search Worker state once and assemble the QCtx threaded
// through the whole (q)search recursion.
fn buildCtx(worker: *anyopaque, table: ?*anyopaque, cc: usize, gen: u8) QCtx {
    var acc_stack: ?*anyopaque = null;
    var nodes: ?*u64 = null;
    var network: ?*const anyopaque = null;
    var cache: ?*anyopaque = null;
    var optimism: ?*const [2]c_int = null;
    var nmp_min_ply: ?*c_int = null;
    var sel_depth: ?*c_int = null;
    var root_depth: ?*c_int = null;
    var reductions: ?[*]const c_int = null;
    var root_delta: ?*const c_int = null;
    var last_iter_pv: ?*const PVMoves = null;
    var stop: ?*const u8 = null;
    var pv_idx: ?*const usize = null;
    var root_moves: ?*anyopaque = null;
    var pv_last: ?*const usize = null;
    var best_move_changes: ?*u64 = null;
    var time_state: SearchTimeState = undefined;
    searchCbWorkerState(worker, &acc_stack, &nodes, &network, &cache, &optimism, &nmp_min_ply, &sel_depth, &root_depth, &reductions, &root_delta, &last_iter_pv, &stop, &pv_idx, &root_moves, &pv_last, &best_move_changes, &time_state);
    return .{
        .worker = worker,
        .table = table,
        .cluster_count = cc,
        .generation = gen,
        .acc_stack = acc_stack.?,
        .nodes = nodes.?,
        .network = network.?,
        .cache = cache.?,
        .optimism = optimism.?,
        .nmp_min_ply = nmp_min_ply.?,
        .sel_depth = sel_depth.?,
        .root_depth = root_depth.?,
        .reductions = reductions.?,
        .root_delta = root_delta.?,
        .last_iter_pv = last_iter_pv.?,
        .stop = stop.?,
        .pv_idx = pv_idx.?,
        .root_moves = @ptrCast(@alignCast(root_moves.?)),
        .pv_last = pv_last.?,
        .best_move_changes = best_move_changes.?,
        .time_state = time_state,
    };
}

// SearchManager::check_time inlined (main thread only). Decrements the call
// counter; when it reaches zero, resets it and applies the stop conditions.
// nodes_searched() is the single-thread node counter (ctx.nodes, the owned
// runtime target). The dbg_print / lastInfoTime block is dropped: dbg_print is
// provably dead (no dbg_hit/dbg_mean registrations exist in the tree). now() is
// the C++ steady_clock so elapsed shares the epoch in which startTime was taken.
fn checkTime(ctx: *const QCtx) void {
    const ts = &ctx.time_state;
    const cc = ts.calls_cnt orelse return; // not the main thread => no-op
    cc.* -= 1;
    if (cc.* > 0) return;
    cc.* = if (ts.lim_nodes != 0) @intCast(@min(@as(u64, 512), ts.lim_nodes / 1024)) else 512;

    const elapsed: i64 = if (ts.tm_use_nodes_time != 0)
        @intCast(ctx.nodes.*)
    else
        clock.now() - ts.tm_start_time;

    if (ts.ponder.?.* != 0) return;

    const ns: u64 = ctx.nodes.*;
    if ((ts.use_time_management != 0 and (elapsed > ts.tm_maximum_time or ts.stop_on_ponderhit.?.* != 0)) or
        (ts.lim_movetime != 0 and elapsed >= ts.lim_movetime) or
        (ts.lim_nodes != 0 and ns >= ts.lim_nodes))
    {
        @atomicStore(u8, ts.stop_write.?, 1, .monotonic);
    }
}

// search<Root> per-move bookkeeping (Worker root_update, inlined). Finds the
// RootMove for `move` in [pvIdx, pvLast) (unique, guaranteed present by the
// rootInList filter), updates its effort / averageScore / meanSquaredScore, and
// on a PV move stores the score/bound flags/PV. C truncating division (@divTrunc)
// and i32 arithmetic match the C++ exactly (no overflow: both squared terms are
// < VALUE_INFINITE^2, sum < INT_MAX).
const root_mean_sq_sentinel: c_int = -(q_value_inf * q_value_inf);
fn rootUpdate(ctx: *const QCtx, move: u16, value: c_int, nodes_delta: u64, move_count: c_int, alpha: c_int, beta: c_int, child_pv: ?*const PVMoves) void {
    var idx: usize = ctx.pv_idx.*;
    const last = ctx.pv_last.*;
    while (idx < last and ctx.root_moves[idx].pv.moves[0] != move) : (idx += 1) {}
    const rm = &ctx.root_moves[idx];

    rm.effort += nodes_delta;
    rm.average_score = if (rm.average_score != -q_value_inf) @divTrunc(value + rm.average_score, 2) else value;
    const av = if (value < 0) -value else value;
    const v_sq = value * av;
    rm.mean_squared_score = if (rm.mean_squared_score != root_mean_sq_sentinel) @divTrunc(v_sq + rm.mean_squared_score, 2) else v_sq;

    if (move_count == 1 or value > alpha) {
        rm.score = value;
        rm.uci_score = value;
        rm.sel_depth = ctx.sel_depth.*;
        rm.score_lowerbound = false;
        rm.score_upperbound = false;
        if (value >= beta) {
            rm.score_lowerbound = true;
            rm.uci_score = beta;
        } else if (value <= alpha) {
            rm.score_upperbound = true;
            rm.uci_score = alpha;
        }
        // pv.resize(1) keeps pv[0] (== move), then append the child PV.
        rm.pv.length = 1;
        if (child_pv) |c| {
            var j: usize = 0;
            while (j < c.length) : (j += 1) rm.pv.moves[1 + j] = c.moves[j];
            rm.pv.length = 1 + c.length;
        }
        if (move_count > 1 and ctx.pv_idx.* == 0)
            _ = @atomicRmw(u64, ctx.best_move_changes, .Add, 1, .monotonic);
    } else rm.score = -q_value_inf;
}

// search<Root> reads the TT move and the legal-root filter from the rootMoves
// array (a contiguous std::vector<RootMove>) handed over by worker_state.
inline fn rootTtMove(ctx: *const QCtx) u16 {
    return ctx.root_moves[ctx.pv_idx.*].pv.moves[0];
}

// RootMove::operator==(Move) compares pv[0]; std::count over [pvIdx, pvLast).
inline fn rootInList(ctx: *const QCtx, move: u16) bool {
    var i: usize = ctx.pv_idx.*;
    const last = ctx.pv_last.*;
    while (i < last) : (i += 1) {
        if (ctx.root_moves[i].pv.moves[0] == move) return true;
    }
    return false;
}

// Worker::threads.stop inlined: the search aborts when the shared stop flag is
// set. worker_state hands Zig a pointer to the std::atomic_bool; this mirrors
// the C++ load(memory_order_relaxed) with a monotonic atomic byte load.
inline fn searchStopped(ctx: *const QCtx) bool {
    return @atomicLoad(u8, ctx.stop, .monotonic) != 0;
}

// Worker::is_in_last_iteration_pv inlined: lastIterationPV is an inline PVMoves
// member (fixed Move array + length), so worker_state hands Zig a stable pointer
// and the follow-pv test compares directly against it.
inline fn inLastIterPv(ctx: *const QCtx, ply_minus_1: c_int, move: u16) bool {
    const pv = ctx.last_iter_pv;
    const idx: usize = @intCast(ply_minus_1);
    return idx < pv.length and pv.moves[idx] == move;
}

pub fn qsearchEntry(worker: *anyopaque, pos_ptr: *anyopaque, ss_ptr: *anyopaque, alpha: c_int, beta: c_int, pv_node: u8) c_int {
    var table: ?*anyopaque = null;
    var cc: usize = 0;
    var gen: u8 = 0;
    searchCbTtContext(worker, &table, &cc, &gen);
    const ctx = buildCtx(worker, table, cc, gen);
    return qsearchImpl(&ctx, pos_ptr, ss_ptr, alpha, beta, pv_node != 0);
}

// ======================= search() (ported to Zig, non-root) =======================
// Mirrors Search::Worker::search for PV/NonPV nodes (Root stays C++ in search.cpp,
// so rootMoves never crosses the boundary). Reuses the qsearch infrastructure
// (mirrors, TT, MovePicker, the worker_state pointers) plus the pos_do_move
// (2-arg) / followPV / root-bookkeeping callbacks. (do_null_move, reduction,
// nmpMinPly, and seldepth are now inlined: null make/unmake is Zig-owned, and the
// reductions table / rootDelta / nmpMinPly / selDepth are read through the stable
// pointers worker_state hands the search.)

const q_bound_none: u8 = 0;
const q_bound_exact: u8 = 3;
const lmr_divisor = [16]c_int{ 3307, 2930, 2874, 2818, 3215, 3225, 3224, 2782, 2858, 2919, 3088, 3275, 3180, 2868, 3006, 3599 };

inline fn qMateIn(ply: c_int) c_int {
    return q_value_mate - ply;
}
// pos.capture(m): occupied target (non-castling) or en passant; excludes pure promotions.
inline fn posCapture(pos: *const Position, m: u16) bool {
    const t = moveTypeOf(m);
    return (pos.board[moveTo(m)] != 0 and t != mt_castling) or t == mt_en_passant;
}
inline fn ssAdd(ss: *SearchStack, n: usize) *SearchStack {
    return @ptrFromInt(@intFromPtr(ss) + n * @sizeOf(SearchStack));
}
inline fn ssSub(ss: *SearchStack, n: usize) *SearchStack {
    return @ptrFromInt(@intFromPtr(ss) - n * @sizeOf(SearchStack));
}
inline fn ttMoveHistoryUpdate(w: *WorkerHistories, bonus: c_int) void {
    statsUpdate(&w.tt_move_history, bonus, 8192);
}
inline fn contVal(ss_ch: ?*const anyopaque, pc: u8, to: u8) c_int {
    const p: [*]const i16 = @ptrCast(@alignCast(ss_ch.?));
    return p[@as(usize, pc) * 64 + to];
}

fn searchImpl(ctx: *const QCtx, pos_ptr: *anyopaque, ss_ptr: *anyopaque, alpha_in: c_int, beta_in: c_int, depth_in: c_int, cut_node: bool, pv_node: bool, root_node: bool) c_int {
    const all_node = !(pv_node or cut_node);

    // Dive into qsearch at depth 0.
    if (depth_in <= 0) return qsearchImpl(ctx, pos_ptr, ss_ptr, alpha_in, beta_in, pv_node);

    const w: *WorkerHistories = @ptrCast(@alignCast(ctx.worker));
    const pos: *Position = @ptrCast(@alignCast(pos_ptr));
    const ss: *SearchStack = @ptrCast(@alignCast(ss_ptr));
    const ss1 = ssSub(ss, 1);
    const ss2 = ssSub(ss, 2);

    var alpha = alpha_in;
    var beta = beta_in;
    var depth = @min(depth_in, q_max_ply - 1);

    // Upcoming-repetition draw (non-root).
    if (!root_node and alpha < q_value_draw and upcomingRepetition(pos_ptr, ss.ply)) {
        alpha = search.valueDraw(ctx.nodes.*);
        if (alpha >= beta) return alpha;
    }

    var pv: PVMoves = undefined;
    var st: StateInfo = undefined;

    // Step 1. Initialize node.
    ss.in_check = pos.st.checkers_bb != 0;
    const prior_capture = pos.st.captured_piece != 0;
    const us = pos.side_to_move;
    ss.move_count = 0;
    var best_value: c_int = -q_value_inf;
    const max_value: c_int = q_value_inf;

    ss.follow_pv = root_node or (ss1.follow_pv and inLastIterPv(ctx, ss.ply - 1, ss1.current_move));

    checkTime(ctx);

    if (pv_node) updateSelDepth(ctx, ss.ply);

    if (!root_node) {
        // Step 2. Aborted search / immediate draw / max ply.
        if (searchStopped(ctx) or isDraw(pos_ptr, ss.ply) or ss.ply >= q_max_ply) {
            if (ss.ply >= q_max_ply and !ss.in_check) return evaluateAcc(ctx, pos_ptr);
            return search.valueDraw(ctx.nodes.*);
        }

        // Step 3. Mate distance pruning.
        alpha = @max(qMatedIn(ss.ply), alpha);
        beta = @min(qMateIn(ss.ply + 1), beta);
        if (alpha >= beta) return alpha;
    }

    const prev_sq: c_int = if (moveIsOk(ss1.current_move)) @intCast(moveTo(ss1.current_move)) else @as(c_int, sq_none);
    var best_move: u16 = 0;
    const prior_reduction = ss1.reduction;
    ss1.reduction = 0;
    ss.stat_score = 0;
    ssAdd(ss, 2).cutoff_cnt = 0;

    // Step 4. Transposition-table lookup.
    const excluded_move = ss.excluded_move;
    const pos_key = adjustKey50(pos);
    const probe = tt.probeTable(ctx.table, ctx.cluster_count, pos_key, ctx.generation, q_depth_none);
    const tt_hit = probe.found != 0;
    ss.tt_hit = tt_hit;
    const tt_move: u16 = if (root_node) rootTtMove(ctx) else if (tt_hit) probe.data.move16 else 0;
    const tt_value: c_int = if (tt_hit) search.valueFromTt(probe.data.value16, ss.ply, pos.st.rule50) else q_value_none;
    const tt_depth: c_int = probe.data.depth;
    const tt_bound: u8 = probe.data.bound;
    const tt_eval: c_int = probe.data.eval16;
    const tt_is_pv = tt_hit and probe.data.is_pv != 0;
    ss.tt_pv = if (excluded_move != 0) ss.tt_pv else (pv_node or tt_is_pv);
    const tt_capture = tt_move != 0 and captureStage(pos, tt_move);
    const writer: *tt.TtEntry = @ptrCast(@alignCast(probe.writer_ptr.?));

    // Step 5. Static evaluation.
    var unadjusted_static_eval: c_int = q_value_none;
    const correction_value = qCorrectionValue(w, pos, ss);
    var eval: c_int = undefined;
    if (ss.in_check) {
        ss.static_eval = ss2.static_eval;
        eval = ss2.static_eval;
    } else if (excluded_move != 0) {
        unadjusted_static_eval = ss.static_eval;
        eval = ss.static_eval;
    } else if (ss.tt_hit) {
        unadjusted_static_eval = tt_eval;
        if (!qIsValid(unadjusted_static_eval)) unadjusted_static_eval = evaluateAcc(ctx, pos_ptr);
        ss.static_eval = search.toCorrectedStaticEval(unadjusted_static_eval, correction_value);
        eval = ss.static_eval;
        if (qIsValid(tt_value) and (tt_bound & (if (tt_value > eval) q_bound_lower else q_bound_upper)) != 0)
            eval = tt_value;
    } else {
        unadjusted_static_eval = evaluateAcc(ctx, pos_ptr);
        ss.static_eval = search.toCorrectedStaticEval(unadjusted_static_eval, correction_value);
        eval = ss.static_eval;
        tt.entrySave(writer, pos_key, q_value_none, @intFromBool(ss.tt_pv), q_bound_none, q_depth_unsearched, q_depth_none, 0, unadjusted_static_eval, ctx.generation);
    }

    var improving = ss.static_eval > ss2.static_eval;
    const opponent_worsening = ss.static_eval > -ss1.static_eval;

    // Hindsight reduction adjustments.
    if (prior_reduction >= 3 and !opponent_worsening) depth += 1;
    if (prior_reduction >= 2 and depth >= 2 and ss.static_eval + ss1.static_eval > 173) depth -= 1;

    // Early TT cutoff (non-PV).
    if (!pv_node and excluded_move == 0 and tt_depth > depth - @as(c_int, @intFromBool(tt_value <= beta)) and
        qIsValid(tt_value) and (tt_bound & (if (tt_value >= beta) q_bound_lower else q_bound_upper)) != 0 and
        (cut_node == (tt_value >= beta) or depth > 4))
    {
        if (tt_move != 0 and tt_value >= beta) {
            if (!tt_capture)
                updateQuietHistoriesWorker(ctx.worker, pos_ptr, ss_ptr, tt_move, @min(114 * depth, 724)); // upstream 73826352d
            if (prev_sq != @as(c_int, sq_none) and ss1.move_count < 4 and !prior_capture)
                updateContinuationHistories(ss1, pos.board[@intCast(prev_sq)], @intCast(prev_sq), -2187);
        }
        if (pos.st.rule50 < 96) {
            if (depth >= 7 and tt_move != 0 and pseudoLegal(pos_ptr, tt_move) and legal(pos_ptr, tt_move) and !qIsDecisive(tt_value)) {
                verifyDoMove(pos_ptr, tt_move, @ptrCast(&st));
                const next_key = adjustKey50(pos);
                const probe_next = tt.probeTable(ctx.table, ctx.cluster_count, next_key, ctx.generation, q_depth_none);
                verifyUndoMove(pos_ptr, tt_move);
                const next_value: c_int = probe_next.data.value16;
                if (!qIsValid(next_value)) return tt_value;
                if ((tt_value >= beta) == (-next_value >= beta)) return tt_value;
            } else return tt_value;
        }
    }
    // upstream 319d61eff: no cutoff, but if a window-bound mismatch is the only reason, penalize the
    // now-useless tte (decrement its stored depth).
    else if (!pv_node and excluded_move == 0 and
        tt_depth > depth - @as(c_int, @intFromBool(tt_value <= beta)) and
        qIsValid(tt_value) and tt_bound != (q_bound_lower | q_bound_upper) and
        (tt_bound & (if (tt_value >= beta) q_bound_upper else q_bound_lower)) != 0 and depth > 5)
    {
        tt.entryPenalize(writer, 1);
    }

    // Step 6. Tablebases: cardinality is 0 in this build; skipped.

    if (!ss.in_check) {
        // Static-eval-difference quiet ordering.
        if (moveIsOk(ss1.current_move) and !ss1.in_check and !prior_capture) {
            const eval_diff = search.evalDiff(ss1.static_eval, ss.static_eval);
            statsUpdate(&w.main_history[@as(usize, us ^ 1) * hist_uint16 + ss1.current_move], eval_diff * 10, 7183);
            if (!tt_hit and (pos.board[@intCast(prev_sq)] & 7) != pawn_pt and moveTypeOf(ss1.current_move) != q_mt_promotion) {
                const psq: u8 = @intCast(prev_sq);
                const row = pawnEntryRow(sharedOf(w), pos);
                statsUpdate(&row[@as(usize, pos.board[psq]) * 64 + psq], eval_diff * 13, 8192);
            }
        }

        // Step 7. Razoring.
        if (!pv_node and eval < alpha - search.razorMargin(depth))
            return qsearchImpl(ctx, pos_ptr, ss_ptr, alpha, beta, false);

        // Step 8. Futility pruning.
        if (!ss.tt_pv and depth < 17 and eval >= beta and (tt_move == 0 or tt_capture) and !qIsLoss(beta) and !qIsWin(eval)) {
            const fm = search.futilityMargin(depth, ss.tt_hit, improving, opponent_worsening, correction_value);
            if (eval - fm >= beta) return search.futilityReturn(beta, eval);
        }

        // Step 9. Null-move search.
        if (cut_node and ss.static_eval >= search.nullMoveThreshold(beta, depth, improving) and
            excluded_move == 0 and pos.st.non_pawn_material[us] != 0 and ss.ply >= ctx.nmp_min_ply.* and !qIsLoss(beta))
        {
            const r = search.nullMoveReduction(depth);
            // Worker::do_null_move, inlined: null moves touch no accumulator, so
            // call the Zig-owned pos.do_null_move, mark the stack move as null
            // (Move::null() == 65), and set the all-NO_PIECE continuation-history
            // pointer -- the work the removed cb_do_null_move callback did.
            doNullMove(pos_ptr, @ptrCast(&st));
            ss.current_move = 65;
            setContHist(ctx.worker, ss_ptr, 0, 0, 0, 0);
            const null_value = -searchImpl(ctx, pos_ptr, @ptrCast(ssAdd(ss, 1)), -beta, -beta + 1, depth - r, false, false, false);
            undoNullMove(pos_ptr);
            if (null_value >= beta and !qIsWin(null_value)) {
                if (ctx.nmp_min_ply.* != 0 or depth < 16) return null_value;
                ctx.nmp_min_ply.* = search.nmpMinPly(ss.ply, depth, r);
                const v = searchImpl(ctx, pos_ptr, ss_ptr, beta - 1, beta, depth - r, false, false, false);
                ctx.nmp_min_ply.* = 0;
                if (v >= beta) return null_value;
            }
        }

        if (ss.static_eval >= beta) improving = true;

        // Step 10. Internal iterative reductions.
        if (!ss.follow_pv and !all_node and depth >= 6 and tt_move == 0) depth -= 1; // upstream b1053e60b: drop priorReduction<=3

        // Step 11. ProbCut.
        const probcut_beta = search.probCutBeta(beta, improving);
        if (depth >= 3 and !qIsDecisive(beta) and !(qIsValid(tt_value) and tt_value < probcut_beta)) {
            var mp_moves2: [256]movepick.SortEntry = undefined;
            var pc_state = movepick.MovePickerState{
                .tt_move_raw = tt_move,
                .stage = movepick.initProbcutStage(tt_move != 0 and captureStage(pos, tt_move) and pseudoLegal(pos_ptr, tt_move)),
                .threshold = probcut_beta - ss.static_eval,
                .depth = 0,
                .skip_quiets = 0,
                .cur = 0,
                .end_cur = 0,
                .end_bad_captures = 0,
                .end_captures = 0,
                .end_generated = 0,
                .moves = &mp_moves2,
            };
            const pc_ctx = movepick.MovePickerContext{
                .pos = pos_ptr,
                .main_history = null,
                .low_ply_history = null,
                .capture_history = @ptrCast(&w.capture_history),
                .continuation_history = null,
                .shared_history = null,
                .ply = 0,
            };
            const probcut_depth = depth - 4 - @as(c_int, @intFromBool(improving)); // upstream d64835051
            while (true) {
                const move = movepick.nextMove(&pc_state, &pc_ctx);
                if (move == 0) break;
                if (move == excluded_move or !legal(pos_ptr, move)) continue;
                doMoveAcc(ctx, pos_ptr, move, @ptrCast(&st), @intFromBool(givesCheck(pos_ptr, move)), ss_ptr);
                var value = -qsearchImpl(ctx, pos_ptr, @ptrCast(ssAdd(ss, 1)), -probcut_beta, -probcut_beta + 1, false);
                if (value >= probcut_beta and probcut_depth > 0)
                    value = -searchImpl(ctx, pos_ptr, @ptrCast(ssAdd(ss, 1)), -probcut_beta, -probcut_beta + 1, probcut_depth, !cut_node, false, false);
                undoMoveAcc(ctx, pos_ptr, move);
                if (value >= probcut_beta) {
                    tt.entrySave(writer, pos_key, search.valueToTt(value, ss.ply), @intFromBool(ss.tt_pv), q_bound_lower, probcut_depth + 1, q_depth_none, move, unadjusted_static_eval, ctx.generation);
                    if (!qIsDecisive(value)) return value - (probcut_beta - beta);
                }
            }
        }
    }

    // moves_loop:
    // Step 12. Deep-probcut TT idea.
    const probcut_beta2 = search.probCutBetaDeep(beta);
    if ((tt_bound & q_bound_lower) != 0 and tt_depth >= depth - 4 and tt_value >= probcut_beta2 and
        !qIsDecisive(beta) and qIsValid(tt_value) and !qIsDecisive(tt_value)) return probcut_beta2;

    // contHist[6] = {(ss-1)..(ss-6)}.continuation_history.
    var cont_hist = [6]?*const anyopaque{
        ss1.continuation_history,        ssSub(ss, 2).continuation_history,
        ssSub(ss, 3).continuation_history, ssSub(ss, 4).continuation_history,
        ssSub(ss, 5).continuation_history, ssSub(ss, 6).continuation_history,
    };

    var mp_moves: [256]movepick.SortEntry = undefined;
    var mp_state = movepick.MovePickerState{
        .tt_move_raw = tt_move,
        .stage = movepick.initMainStage(pos.st.checkers_bb != 0, tt_move != 0 and pseudoLegal(pos_ptr, tt_move), depth),
        .threshold = 0,
        .depth = depth,
        .skip_quiets = 0,
        .cur = 0,
        .end_cur = 0,
        .end_bad_captures = 0,
        .end_captures = 0,
        .end_generated = 0,
        .moves = &mp_moves,
    };
    const mp_ctx = movepick.MovePickerContext{
        .pos = pos_ptr,
        .main_history = @ptrCast(&w.main_history),
        .low_ply_history = @ptrCast(&w.low_ply_history),
        .capture_history = @ptrCast(&w.capture_history),
        .continuation_history = @ptrCast(&cont_hist),
        .shared_history = w.shared_history,
        .ply = ss.ply,
    };

    var value: c_int = best_value;
    var move_count: c_int = 0;
    var quiets_searched: [32]u16 = undefined;
    var n_quiets: usize = 0;
    var captures_searched: [32]u16 = undefined;
    var n_captures: usize = 0;

    // Step 13. Move loop.
    while (true) {
        const move = movepick.nextMove(&mp_state, &mp_ctx);
        if (move == 0) break;
        if (move == excluded_move) continue;
        if (!legal(pos_ptr, move)) continue;
        if (root_node and !rootInList(ctx, move)) continue;

        move_count += 1;
        ss.move_count = move_count;

        if (root_node and ctx.nodes.* > 10_000_000)
            searchCbRootOnIter(ctx.worker, depth, move, move_count);

        if (pv_node) ssAdd(ss, 1).pv = null;

        var extension: c_int = 0;
        const capture = captureStage(pos, move);
        const moved_piece = pos.board[moveFrom(move)];
        const to = moveTo(move);
        const gc = givesCheck(pos_ptr, move);

        var new_depth = depth - 1;
        const delta = beta - alpha;
        var r = reductionAcc(ctx, improving, depth, move_count, delta);
        if (ss.tt_pv) r += 1006;

        // Step 14. Shallow-depth pruning.
        if (!root_node and pos.st.non_pawn_material[us] != 0 and !qIsLoss(best_value)) {
            if (move_count >= search.moveCountLimit(depth, improving)) mp_state.skip_quiets = 1;
            var lmr_depth = new_depth - @divTrunc(r, 1024);
            if (capture or gc) {
                const captured = pos.board[to];
                const capt_hist = captVal(w, moved_piece, to, captured & 7);
                if (!gc and lmr_depth < 7) {
                    const fv = search.captureFutilityValue(ss.static_eval, lmr_depth, q_piece_value[captured], capt_hist);
                    if (fv <= alpha) continue;
                }
                const margin = search.captureSeeMargin(depth, capt_hist);
                if ((alpha >= q_value_draw or pos.st.non_pawn_material[us] != q_piece_value[moved_piece]) and !seeGe(pos_ptr, move, -margin)) continue;
            } else if (!ss.follow_pv or !pv_node) {
                const d_index: usize = @intCast(@min(depth, @as(c_int, lmr_divisor.len)) - 1);
                var history = contVal(cont_hist[0], moved_piece, to) + contVal(cont_hist[1], moved_piece, to) +
                    pawnEntryRow(sharedOf(w), pos)[@as(usize, moved_piece) * 64 + to];
                if (history < search.historyPruneThreshold(depth)) continue;
                history += @divTrunc(64 * @as(c_int, w.main_history[@as(usize, us) * hist_uint16 + move]), 32);
                lmr_depth += @divTrunc(history, lmr_divisor[d_index]);
                const fv = search.quietFutilityValue(ss.static_eval, best_move == 0, lmr_depth, ss.static_eval > alpha);
                if (!ss.in_check and lmr_depth < 12 and fv <= alpha) {
                    if (best_value <= fv and !qIsDecisive(best_value) and !qIsWin(fv)) best_value = fv;
                    continue;
                }
                if (lmr_depth < 0) lmr_depth = 0;
                if (!seeGe(pos_ptr, move, -search.quietSeeMargin(lmr_depth))) continue;
            }
        }

        // Step 15. Extensions (singular).
        if (!root_node and move == tt_move and excluded_move == 0 and depth >= 6 + @as(c_int, @intFromBool(ss.tt_pv)) and
            qIsValid(tt_value) and !qIsDecisive(tt_value) and (tt_bound & q_bound_lower) != 0 and
            tt_depth >= depth - 3 and !isShuffling(pos_ptr, ss_ptr, move))
        {
            const singular_beta = search.singularBeta(tt_value, ss.tt_pv and !pv_node, depth);
            const singular_depth = @divTrunc(new_depth, 2);
            ss.excluded_move = move;
            value = searchImpl(ctx, pos_ptr, ss_ptr, singular_beta - 1, singular_beta, singular_depth, cut_node, false, false);
            ss.excluded_move = 0;
            if (value < singular_beta) {
                const ply_gt_root = ss.ply > ctx.root_depth.*;
                const double_margin = search.singularDoubleMargin(pv_node, !tt_capture, correction_value, w.tt_move_history, ply_gt_root);
                const triple_margin = search.singularTripleMargin(pv_node, !tt_capture, ss.tt_pv, correction_value, ply_gt_root);
                extension = 1 + @as(c_int, @intFromBool(value < singular_beta - double_margin)) + @as(c_int, @intFromBool(value < singular_beta - triple_margin));
                depth += 1;
            } else if (value >= beta and !qIsDecisive(value)) {
                ttMoveHistoryUpdate(w, search.ttMoveHistoryDepthBonus(depth));
                return value;
            } else if (tt_value >= beta) {
                extension = -3;
            } else if (cut_node) {
                extension = -2;
            }
        }

        const node_count: u64 = if (root_node) ctx.nodes.* else 0;

        // Step 16. Make the move.
        doMoveAcc(ctx, pos_ptr, move, @ptrCast(&st), @intFromBool(gc), ss_ptr);
        new_depth += extension;

        if (ss.tt_pv)
            r -= search.lmrTtpvReduction(pv_node, tt_value > alpha, tt_depth >= depth, cut_node);
        r += 714;
        r -= move_count * 62;
        r -= search.lmrCorrReduction(correction_value);
        if (cut_node) r += 3995 + 1059 * @as(c_int, @intFromBool(tt_move == 0));
        if (ssAdd(ss, 1).cutoff_cnt > 1) {
            r += 236 + 1079 * @as(c_int, @intFromBool(ssAdd(ss, 1).cutoff_cnt > 2)) + 1143 * @as(c_int, @intFromBool(all_node));
        } else if (move == tt_move) {
            r = @max(@as(c_int, 0), r - 2016); // upstream 3c858c19e: simplify ttMove reduction
        }
        if (tt_capture) r += 1039;

        if (capture)
            ss.stat_score = search.captureStatScore(q_piece_value[pos.st.captured_piece], captVal(w, moved_piece, to, pos.st.captured_piece & 7))
        else
            ss.stat_score = search.quietStatScore(w.main_history[@as(usize, us) * hist_uint16 + move], contVal(cont_hist[0], moved_piece, to), contVal(cont_hist[1], moved_piece, to));

        r -= search.lmrStatScoreReduction(ss.stat_score);
        if (all_node) r += search.lmrAllNodeScale(r, depth);

        // Step 17/18. LMR + full-depth search.
        if (depth >= 2 and move_count > 1) {
            const d = @max(@as(c_int, 1), @min(new_depth - @divTrunc(r, 1024), new_depth + 2)) + @as(c_int, @intFromBool(pv_node));
            ss.reduction = new_depth - d;
            value = -searchImpl(ctx, pos_ptr, @ptrCast(ssAdd(ss, 1)), -(alpha + 1), -alpha, d, true, false, false);
            ss.reduction = 0;
            if (value > alpha) {
                const do_deeper = d < new_depth and value > best_value + 52;
                const do_shallower = value < best_value + 9;
                new_depth += @as(c_int, @intFromBool(do_deeper)) - @as(c_int, @intFromBool(do_shallower));
                if (new_depth > d)
                    value = -searchImpl(ctx, pos_ptr, @ptrCast(ssAdd(ss, 1)), -(alpha + 1), -alpha, new_depth, !cut_node, false, false);
                updateContinuationHistories(ss, moved_piece, to, 1415);
            }
        } else if (!pv_node or move_count > 1) {
            if (tt_move == 0) r += 1085;
            value = -searchImpl(ctx, pos_ptr, @ptrCast(ssAdd(ss, 1)), -(alpha + 1), -alpha, new_depth - @as(c_int, @intFromBool(r > 5039)) - @as(c_int, @intFromBool(r > 5223 and new_depth > 2)), !cut_node, false, false);
        }

        if (pv_node and (move_count == 1 or value > alpha)) {
            ssAdd(ss, 1).pv = @ptrCast(&pv);
            pvClear(&pv);
            if (move == tt_move and ((qIsValid(tt_value) and qIsDecisive(tt_value) and tt_depth > 0) or tt_depth > 1))
                new_depth = @max(new_depth, 1);
            value = -searchImpl(ctx, pos_ptr, @ptrCast(ssAdd(ss, 1)), -beta, -alpha, new_depth, false, true, false);
        }

        // Step 19. Undo move.
        undoMoveAcc(ctx, pos_ptr, move);

        // Step 20. Check for a new best move.
        if (searchStopped(ctx)) return q_value_draw;

        if (root_node) {
            // (ss+1)->pv is only valid (non-null) when this move ran a PV search,
            // i.e. move_count == 1 or value > alpha; otherwise the C++ ignores it.
            const cpv: ?*const PVMoves = if (move_count == 1 or value > alpha) @ptrCast(@alignCast(ssAdd(ss, 1).pv.?)) else null;
            rootUpdate(ctx, move, value, ctx.nodes.* - node_count, move_count, alpha, beta, cpv);
        }

        const av = if (value < 0) -value else value;
        const inc: c_int = @intFromBool(value == best_value and ss.ply + 2 >= ctx.root_depth.* and (@as(c_int, @intCast(ctx.nodes.* & 14)) == 0) and !qIsWin(av + 1));
        if (value + inc > best_value) {
            best_value = value;
            if (value + inc > alpha) {
                best_move = move;
                if (pv_node and !root_node) pvUpdate(@ptrCast(@alignCast(ss.pv.?)), move, @ptrCast(@alignCast(ssAdd(ss, 1).pv.?)));
                if (value >= beta) {
                    ss.cutoff_cnt += @intFromBool(extension < 2 or pv_node);
                    break;
                }
                if (depth > 2 and depth < 13 and !qIsDecisive(value)) depth -= 2;
                alpha = value;
            }
        }

        if (move != best_move and move_count <= 32) {
            if (capture) {
                captures_searched[n_captures] = move;
                n_captures += 1;
            } else {
                quiets_searched[n_quiets] = move;
                n_quiets += 1;
            }
        }
    }

    // Step 21. Mate / stalemate / fail-high adjust.
    if (best_value >= beta and !qIsDecisive(best_value) and !qIsDecisive(alpha))
        best_value = @divTrunc(best_value * depth + beta, depth + 1);

    if (move_count == 0) {
        best_value = if (excluded_move != 0) alpha else if (ss.in_check) qMatedIn(ss.ply) else q_value_draw;
    } else if (best_move != 0) {
        updateAllStats(ctx.worker, pos_ptr, ss_ptr, best_move, prev_sq, &quiets_searched, n_quiets, &captures_searched, n_captures, depth, tt_move, @intFromBool(pv_node));
        if (!pv_node) ttMoveHistoryUpdate(w, search.ttMoveHistoryMatchBonus(best_move == tt_move));
    } else if (!prior_capture and prev_sq != @as(c_int, sq_none)) {
        const psq: u8 = @intCast(prev_sq);
        const bonus_scale = search.priorBonusScale(ss1.stat_score, depth, ss1.move_count > 8, !ss.in_check and best_value <= ss.static_eval - 103, !ss1.in_check and best_value <= -ss1.static_eval - 78);
        const scaled_bonus = search.priorScaledBonusBase(depth) * bonus_scale;
        updateContinuationHistories(ss1, pos.board[psq], psq, search.priorConthistScale(scaled_bonus));
        statsUpdate(&w.main_history[@as(usize, us ^ 1) * hist_uint16 + ss1.current_move], search.priorMainhistScale(scaled_bonus), 7183);
        if ((pos.board[psq] & 7) != pawn_pt and moveTypeOf(ss1.current_move) != q_mt_promotion) {
            const row = pawnEntryRow(sharedOf(w), pos);
            statsUpdate(&row[@as(usize, pos.board[psq]) * 64 + psq], search.priorPawnhistScale(scaled_bonus), 8192);
        }
    } else if (prior_capture and prev_sq != @as(c_int, sq_none)) {
        const psq: u8 = @intCast(prev_sq);
        statsUpdate(captEntry(w, pos.board[psq], psq, pos.st.captured_piece & 7), 901, 10692);
    }

    if (pv_node) best_value = @min(best_value, max_value);

    if (best_value <= alpha) ss.tt_pv = ss.tt_pv or ss1.tt_pv;

    if (excluded_move == 0 and !(root_node and ctx.pv_idx.* != 0)) {
        const bound: u8 = if (best_value >= beta) q_bound_lower else if (pv_node and best_move != 0) q_bound_exact else q_bound_upper;
        const wdepth: c_int = if (move_count != 0) depth else @min(q_max_ply - 1, depth + 6);
        tt.entrySave(writer, pos_key, search.valueToTt(best_value, ss.ply), @intFromBool(ss.tt_pv), bound, wdepth, q_depth_none, best_move, unadjusted_static_eval, ctx.generation);
    }

    // Adjust correction history.
    if (!ss.in_check and !(best_move != 0 and posCapture(pos, best_move)) and (best_value > ss.static_eval) == (best_move != 0)) {
        updateCorrectionHistory(ctx.worker, pos_ptr, ss_ptr, search.correctionHistoryBonus(best_value - ss.static_eval, depth, best_move != 0));
    }

    return best_value;
}

pub fn sideToMove(pos_ptr: *const anyopaque) u8 {
    const pos: *const Position = @ptrCast(@alignCast(pos_ptr));
    return pos.side_to_move;
}

pub fn isChess960(pos_ptr: *const anyopaque) bool {
    const pos: *const Position = @ptrCast(@alignCast(pos_ptr));
    return pos.chess960;
}

pub fn gamePly(pos_ptr: *const anyopaque) c_int {
    const pos: *const Position = @ptrCast(@alignCast(pos_ptr));
    return pos.game_ply;
}

// WDL-model material count (src/uci.cpp): pawns + 3*(knights+bishops) +
// 5*rooks + 9*queens, both colours. piece_count is indexed by piece
// (white type at 1..5, black type at 9..13).
pub fn hasCheckers(pos_ptr: *const anyopaque) bool {
    const pos: *const Position = @ptrCast(@alignCast(pos_ptr));
    return pos.st.checkers_bb != 0;
}

pub fn wdlMaterial(pos_ptr: *const anyopaque) c_int {
    const pos: *const Position = @ptrCast(@alignCast(pos_ptr));
    const pc = pos.piece_count;
    return (pc[1] + pc[9]) + 3 * (pc[2] + pc[10]) + 3 * (pc[3] + pc[11]) +
        5 * (pc[4] + pc[12]) + 9 * (pc[5] + pc[13]);
}

// Layout matches position_snapshot.PositionSnapshot / the bridge
// ZfishPositionSnapshot. Read straight from the Position memory mirror.
const FillSnapshot = struct {
    side_to_move: u8,
    pieces_all: u64,
    pieces_by_color: [2]u64,
    pieces_by_type: [8]u64,
    blockers_for_king: [2]u64,
    pinners: [2]u64,
    king_square: [2]u8,
    ep_square: u8,
    castling_rights: u8,
    castling_impeded: [16]u8,
    castling_rook_square: [16]u8,
    checkers: u64,
    board: [64]u8,
    pawn_key: u64,
    key: u64,
    material_value: c_int,
    rule50_count: c_int,
    game_ply: c_int,
    is_chess960: u8,
};

// Position::fill_snapshot, ported from the C++ bridge: derive the NNUE/board
// snapshot from the live Position. Reads the memory mirror directly, no C++.
pub fn fillSnapshot(pos_ptr: *const anyopaque, out_ptr: *anyopaque) void {
    const pos: *const Position = @ptrCast(@alignCast(pos_ptr));
    const st = pos.st;
    const out: *FillSnapshot = @ptrCast(@alignCast(out_ptr));

    out.side_to_move = pos.side_to_move;
    out.pieces_all = pos.by_type_bb[0];
    out.pieces_by_color[0] = pos.by_color_bb[0];
    out.pieces_by_color[1] = pos.by_color_bb[1];
    var t: usize = 0;
    while (t < 8) : (t += 1) out.pieces_by_type[t] = pos.by_type_bb[t];
    out.blockers_for_king = st.blockers_for_king;
    out.pinners = st.pinners;
    out.king_square[0] = @intCast(@ctz(pos.by_color_bb[0] & pos.by_type_bb[king_pt]));
    out.king_square[1] = @intCast(@ctz(pos.by_color_bb[1] & pos.by_type_bb[king_pt]));
    out.ep_square = st.ep_square;
    out.checkers = st.checkers_bb;

    out.castling_rights = @intCast(st.castling_rights);
    for ([_]u8{ 1, 2, 4, 8 }) |cr| {
        out.castling_impeded[cr] = if ((pos.by_type_bb[0] & pos.castling_path[cr]) != 0) 1 else 0;
        out.castling_rook_square[cr] = pos.castling_rook_square[cr];
    }

    out.pawn_key = st.pawn_key;
    out.key = st.key;
    const pawns = pos.piece_count[1] + pos.piece_count[9];
    out.material_value = 534 * pawns + st.non_pawn_material[0] + st.non_pawn_material[1];
    out.rule50_count = st.rule50;
    out.game_ply = pos.game_ply;
    out.is_chess960 = @intFromBool(pos.chess960);

    var s: usize = 0;
    while (s < 64) : (s += 1) out.board[s] = pos.board[s];
}

// The 64-square piece board only, for NNUE piece-count/accumulator callers that
// need just the board (not the full snapshot). Relocated from main.zig (M16.7).
pub fn accumulatorSnapshot(pos_ptr: *const anyopaque, pieces_out: [*]u8) void {
    const pos: *const Position = @ptrCast(@alignCast(pos_ptr));
    var s: usize = 0;
    while (s < 64) : (s += 1) pieces_out[s] = pos.board[s];
}

inline fn captVal(w: *WorkerHistories, pc: u8, to: u8, captured_type: u8) c_int {
    return w.capture_history[@as(usize, pc) * 512 + @as(usize, to) * 8 + captured_type];
}
inline fn captEntry(w: *WorkerHistories, pc: u8, to: u8, captured_type: u8) *i16 {
    return &w.capture_history[@as(usize, pc) * 512 + @as(usize, to) * 8 + captured_type];
}

pub fn searchEntry(worker: *anyopaque, pos_ptr: *anyopaque, ss_ptr: *anyopaque, alpha: c_int, beta: c_int, depth: c_int, cut_node: u8, pv_node: u8, root_node: u8) c_int {
    var table: ?*anyopaque = null;
    var cc: usize = 0;
    var gen: u8 = 0;
    searchCbTtContext(worker, &table, &cc, &gen);
    const ctx = buildCtx(worker, table, cc, gen);
    return searchImpl(&ctx, pos_ptr, ss_ptr, alpha, beta, depth, cut_node != 0, pv_node != 0, root_node != 0);
}

// ==================== iterative_deepening() (ported to Zig) ====================
// Compatibility-surface externs: the UCI pv() sink, and the cross-thread
// bestMoveChanges collection (sum + reset, returned as a double) so multi-thread
// stays correct. The skill-enabled handicap path stays in C++ (the seam only
// redirects here when skill is off), so no skill/RNG logic is needed in Zig.

const id_nodes_limit_output: u64 = 10_000_000;

inline fn idIsLoss(v: c_int) bool {
    return v <= -q_value_tb_win;
}
inline fn idIsMate(v: c_int) bool {
    return v >= q_value_mate_in_max;
}
inline fn idIsMated(v: c_int) bool {
    return v <= -q_value_mate_in_max;
}
// RootMove::operator<: descending by (score, previousScore).
inline fn rootLess(a: *const RootMove, b: *const RootMove) bool {
    return if (a.score != b.score) a.score > b.score else a.previous_score > b.previous_score;
}
// Stable insertion sort over root_moves[lo, hi): matches std::stable_sort with
// RootMove::operator< (equal elements keep their relative order).
fn stableSortRoot(rm: [*]RootMove, lo: usize, hi: usize) void {
    if (hi <= lo) return;
    var i: usize = lo + 1;
    while (i < hi) : (i += 1) {
        const key = rm[i];
        var j: usize = i;
        while (j > lo and rootLess(&key, &rm[j - 1])) : (j -= 1) rm[j] = rm[j - 1];
        rm[j] = key;
    }
}
// Utility::move_to_front: rotate the first RootMove whose pv[0]==target to front.
fn moveToFront(rm: [*]RootMove, count: usize, target: u16) void {
    var fi: usize = 0;
    while (fi < count and rm[fi].pv.moves[0] != target) : (fi += 1) {}
    if (fi >= count) return;
    const tmp = rm[fi];
    var z: usize = fi;
    while (z > 0) : (z -= 1) rm[z] = rm[z - 1];
    rm[0] = tmp;
}
inline fn idElapsed(id: *const ZfishIdState) i64 {
    return if (id.tm_use_nodes_time != 0) @intCast(id.nodes.*) else clock.now() - id.tm_start_time;
}
inline fn fclamp(v: f64, lo: f64, hi: f64) f64 {
    return @max(lo, @min(v, hi));
}

// Skill (strength handicap). Move::none() == 0. The PRNG matches misc.h's
// xorshift*, seeded once from now() on first use (non-deterministic by design).
const skill_pawn_value: c_int = 208;
var skill_rng_state: u64 = 0;
fn skillRand64() u64 {
    if (skill_rng_state == 0) skill_rng_state = @bitCast(clock.now());
    var s = skill_rng_state;
    s ^= s >> 12;
    s ^= s << 25;
    s ^= s >> 27;
    skill_rng_state = s;
    return s *% 2685821657736338717;
}
inline fn skillTimeToPick(level: f64, depth: c_int) bool {
    return depth == 1 + @as(c_int, @intFromFloat(level));
}
// Skill::pick_best: a statistical rule over the (descending-sorted) rootMoves.
fn skillPickBest(id: *const ZfishIdState, multi_pv: usize) u16 {
    const top_score = id.root_moves[0].score;
    const span = top_score - id.root_moves[multi_pv - 1].score;
    const delta: c_int = if (span < skill_pawn_value) span else skill_pawn_value;
    const weakness: f64 = 120.0 - 2.0 * id.skill_level;
    const modw: u32 = @intFromFloat(weakness);
    var max_score: c_int = -q_value_inf;
    var best: u16 = 0;
    var i: usize = 0;
    while (i < multi_pv) : (i += 1) {
        const r: u32 = @truncate(skillRand64());
        const term1 = weakness * @as(f64, @floatFromInt(top_score - id.root_moves[i].score));
        const term2: c_int = delta * @as(c_int, @intCast(r % modw));
        const push = @divTrunc(@as(c_int, @intFromFloat(term1 + @as(f64, @floatFromInt(term2)))), 128);
        if (id.root_moves[i].score + push >= max_score) {
            max_score = id.root_moves[i].score + push;
            best = id.root_moves[i].pv.moves[0];
        }
    }
    return best;
}
// std::swap(rootMoves[0], *find(rootMoves, move)).
fn skillSwapBest(id: *const ZfishIdState, move: u16) void {
    var i: usize = 0;
    while (i < id.root_moves_count and id.root_moves[i].pv.moves[0] != move) : (i += 1) {}
    if (i >= id.root_moves_count or i == 0) return;
    const tmp = id.root_moves[0];
    id.root_moves[0] = id.root_moves[i];
    id.root_moves[i] = tmp;
}

pub fn iterativeDeepening(worker: *anyopaque) u8 {
    var id: ZfishIdState = undefined;
    searchIdState(worker, &id);
    const main_thread = id.is_main != 0;

    var table: ?*anyopaque = null;
    var cc: usize = 0;
    var gen: u8 = 0;
    searchCbTtContext(worker, &table, &cc, &gen);
    const ctx = buildCtx(worker, table, cc, gen);

    var pv: PVMoves = undefined;
    pv.length = 0;

    var last_best_move_depth: c_int = 0;
    var best_value: c_int = -q_value_inf;
    const us: usize = @intCast(sideToMove(id.root_pos));
    var time_reduction: f64 = 1;
    var tot_best_move_changes: f64 = 0;
    var iter_idx: usize = 0;

    // Stack[MAX_PLY+10] = {} with (ss-7..ss-1) sentinels and ss[i].ply = i.
    const stack_n: usize = @intCast(q_max_ply + 10);
    var stack: [stack_n]SearchStack = std.mem.zeroes([stack_n]SearchStack);
    {
        var k: usize = 0;
        while (k < 7) : (k += 1) {
            setContHist(worker, &stack[k], 0, 0, 0, 0); // sentinel (NO_PIECE)
            stack[k].static_eval = q_value_none;
        }
        const ply_hi: usize = @intCast(q_max_ply + 2);
        var p: usize = 0;
        while (p <= ply_hi) : (p += 1) stack[7 + p].ply = @intCast(p);
        stack[7].pv = &pv;
    }

    if (main_thread) {
        const fv: c_int = if (id.best_previous_score == q_value_inf) 0 else id.best_previous_score;
        id.iter_value[0] = fv;
        id.iter_value[1] = fv;
        id.iter_value[2] = fv;
        id.iter_value[3] = fv;
    }

    var multi_pv: usize = id.multipv_option;
    if (id.skill_enabled != 0 and multi_pv < 4) multi_pv = 4;
    if (multi_pv > id.root_moves_count) multi_pv = id.root_moves_count;
    var skill_best: u16 = 0;

    fillLowPlyHistory(worker);
    ageMainHistory(worker);

    var search_again_counter: c_int = 0;
    var uci_pv_sent = false;

    // Iterative deepening loop.
    while (id.root_depth.* + 1 < q_max_ply and @atomicLoad(u8, id.stop, .monotonic) == 0 and
        !(id.limits_depth != 0 and main_thread and id.root_depth.* >= id.limits_depth))
    {
        id.root_depth.* += 1;

        if (main_thread) {
            tot_best_move_changes /= 2;
            uci_pv_sent = false;
        }

        // Save last iteration scores.
        var ri: usize = 0;
        while (ri < id.root_moves_count) : (ri += 1)
            id.root_moves[ri].previous_score = id.root_moves[ri].score;

        var pv_first: usize = 0;
        id.pv_last.* = 0;

        if (@atomicLoad(u8, id.increase_depth, .monotonic) == 0) search_again_counter += 1;

        // MultiPV loop.
        id.pv_idx.* = 0;
        while (id.pv_idx.* < multi_pv) : (id.pv_idx.* += 1) {
            if (id.pv_idx.* == id.pv_last.*) {
                pv_first = id.pv_last.*;
                id.pv_last.* += 1;
                while (id.pv_last.* < id.root_moves_count) : (id.pv_last.* += 1) {
                    if (id.root_moves[id.pv_last.*].tb_rank != id.root_moves[pv_first].tb_rank) break;
                }
            }

            id.sel_depth.* = 0;

            var delta = search.aspirationInitialDelta(id.thread_idx, id.root_moves[id.pv_idx.*].mean_squared_score);
            const avg = id.root_moves[id.pv_idx.*].average_score;
            var alpha = @max(avg - delta, -q_value_inf);
            var beta = @min(avg + delta, q_value_inf);
            id.optimism[us] = search.optimism(avg);
            id.optimism[us ^ 1] = -id.optimism[us];

            var failed_high_cnt: c_int = 0;
            while (true) {
                const adjusted_depth = @max(@as(c_int, 1), id.root_depth.* - failed_high_cnt - @divTrunc(3 * (search_again_counter + 1), 4));
                id.root_delta.* = beta - alpha;
                best_value = searchImpl(&ctx, id.root_pos, &stack[7], alpha, beta, adjusted_depth, false, true, true);

                stableSortRoot(id.root_moves, id.pv_idx.*, id.pv_last.*);

                if (@atomicLoad(u8, id.stop, .monotonic) != 0) break;

                if (main_thread and multi_pv == 1 and (best_value <= alpha or best_value >= beta) and id.nodes.* > id_nodes_limit_output)
                    searchIdPv(worker, id.root_depth.*);

                if (best_value <= alpha) {
                    beta = alpha;
                    alpha = @max(best_value - delta, -q_value_inf);
                    failed_high_cnt = 0;
                    if (main_thread) id.stop_on_ponderhit.* = 0;
                } else if (best_value >= beta) {
                    alpha = @max(beta - delta, alpha);
                    beta = @min(best_value + delta, q_value_inf);
                    failed_high_cnt += 1;
                } else break;

                delta = search.aspirationDeltaGrow(delta);
            }

            // MultiPV mated-in/TB-loss protection for aborted later PV lines.
            if (@atomicLoad(u8, id.stop, .monotonic) != 0 and id.pv_idx.* != 0 and
                idIsLoss(id.root_moves[id.pv_idx.* - 1].score) and
                rootLess(&id.root_moves[id.pv_idx.*], &id.root_moves[id.pv_idx.* - 1]))
            {
                const prev = id.root_moves[id.pv_idx.* - 1].score;
                const cur_prev = id.root_moves[id.pv_idx.*].previous_score;
                id.root_moves[id.pv_idx.*].score = if (cur_prev != -q_value_inf and cur_prev < prev) cur_prev else prev;
                id.root_moves[id.pv_idx.*].uci_score = id.root_moves[id.pv_idx.*].score;
                id.root_moves[id.pv_idx.*].previous_score = -q_value_inf;
                id.root_moves[id.pv_idx.*].score_lowerbound = false;
                id.root_moves[id.pv_idx.*].score_upperbound = false;
                id.root_moves[id.pv_idx.*].pv.length = 1;
            }

            stableSortRoot(id.root_moves, pv_first, id.pv_idx.* + 1);

            if (main_thread and @atomicLoad(u8, id.stop, .monotonic) == 0 and
                (id.pv_idx.* + 1 == multi_pv or id.nodes.* > id_nodes_limit_output))
            {
                searchIdPv(worker, id.root_depth.*);
                uci_pv_sent = (id.pv_idx.* + 1 == multi_pv);
            }

            if (@atomicLoad(u8, id.stop, .monotonic) != 0) break;
        }

        if (@atomicLoad(u8, id.stop, .monotonic) == 0) {
            if (id.last_iter_pv.length == 0 or id.root_moves[0].pv.moves[0] != id.last_iter_pv.moves[0])
                last_best_move_depth = id.root_depth.*;
            id.last_iter_pv.* = id.root_moves[0].pv;
        } else if (id.pv_idx.* == 0 and id.root_moves[0].score != -q_value_inf and
            idIsLoss(id.root_moves[0].score) and
            !(id.root_moves[0].score_lowerbound or id.root_moves[0].score_upperbound))
        {
            if (id.last_iter_pv.length != 0) {
                moveToFront(id.root_moves, id.root_moves_count, id.last_iter_pv.moves[0]);
                id.root_moves[0].pv = id.last_iter_pv.*;
                id.root_moves[0].score = id.root_moves[0].previous_score;
                id.root_moves[0].uci_score = id.root_moves[0].previous_score;
                if (main_thread) uci_pv_sent = false;
            } else id.root_moves[0].score_lowerbound = true;
        }

        // Mate in x found?
        if (id.limits_mate != 0 and @atomicLoad(u8, id.stop, .monotonic) == 0 and
            ((idIsMate(id.root_moves[0].score) and q_value_mate - id.root_moves[0].score <= 2 * id.limits_mate) or
                (idIsMated(id.root_moves[0].score) and q_value_mate + id.root_moves[0].score <= 2 * id.limits_mate)))
            @atomicStore(u8, id.stop, 1, .monotonic);

        if (!main_thread) continue;

        // If the skill level is enabled and time is up, pick a sub-optimal move.
        if (id.skill_enabled != 0 and skillTimeToPick(id.skill_level, id.root_depth.*))
            skill_best = skillPickBest(&id, multi_pv);

        tot_best_move_changes += searchIdCollectBmc(worker);

        // Time management: do we have time for the next iteration / can we stop?
        if (id.use_time_management != 0 and @atomicLoad(u8, id.stop, .monotonic) == 0 and id.stop_on_ponderhit.* == 0) {
            const nodes_effort: u64 = @divTrunc(id.root_moves[0].effort * 100000, @max(@as(u64, 1), id.nodes.*));

            var falling_eval = (11.87 + 2.21 * @as(f64, @floatFromInt(id.best_previous_average_score - best_value)) +
                1.0 * @as(f64, @floatFromInt(id.iter_value[iter_idx] - best_value))) / 100.0;
            falling_eval = fclamp(falling_eval, 0.572, 1.708);

            const tr_x = @as(f64, @floatFromInt(id.root_depth.* - last_best_move_depth));
            time_reduction = fclamp(0.65 + (1.55 - 0.65) * (tr_x - 5.0) / (18.0 - 5.0), 0.65, 1.55);

            const reduction = (1.48 + id.previous_time_reduction.*) / (2.157 * time_reduction);
            const best_move_instability = 1.096 + 2.29 * tot_best_move_changes / @as(f64, @floatFromInt(id.threads_size));

            const hbme_x = @as(f64, @floatFromInt(@as(i64, @intCast(nodes_effort))));
            const high_best_move_effort = fclamp(0.924 + (0.71 - 0.924) * (hbme_x - 79219.0) / (101822.0 - 79219.0), 0.71, 0.924);

            var total_time = @as(f64, @floatFromInt(id.tm_optimum)) * falling_eval * reduction * best_move_instability * high_best_move_effort;
            if (id.root_moves_count == 1) total_time = @min(561.7, total_time);

            const elapsed_time = @as(f64, @floatFromInt(idElapsed(&id)));
            if (elapsed_time > @min(total_time, @as(f64, @floatFromInt(id.tm_maximum)))) {
                if (@atomicLoad(u8, id.ponder, .monotonic) != 0) id.stop_on_ponderhit.* = 1 else @atomicStore(u8, id.stop, 1, .monotonic);
            } else {
                const inc: u8 = if (@atomicLoad(u8, id.ponder, .monotonic) != 0 or elapsed_time <= total_time * 0.50) 1 else 0;
                @atomicStore(u8, id.increase_depth, inc, .monotonic);
            }
        }

        id.iter_value[iter_idx] = best_value;
        iter_idx = (iter_idx + 1) & 3;
    }

    if (!main_thread) return 0;

    id.previous_time_reduction.* = time_reduction;
    // If the skill level is enabled, swap the best PV line with the sub-optimal one.
    if (id.skill_enabled != 0) {
        const sel = if (skill_best != 0) skill_best else skillPickBest(&id, multi_pv);
        skillSwapBest(&id, sel);
    }
    return if (uci_pv_sent) 1 else 0;
}


const low_ply_history_size: c_int = 5;

// Compute the three quiet-history entries for `move` from the table bases the
// bridge passed and apply the shared quiet-history update. mainHistory is
// [2][65536], lowPlyHistory [5][65536], pawn_row is one fixed [16][64] page.
// update_all_stats (search.cpp): credit the best move and debit the searched-but-
// rejected quiets/captures. The bridge passes only the Worker, Position, and
// Stack pointers and the two move lists (ptr+len); Zig resolves captureHistory
// from the Worker mirror and the quiet entries via updateQuietHistoriesWorker,
// and owns all bonus/malus scaling, the running malus decay, and the gravity.
pub fn updateAllStats(
    worker_ptr: *anyopaque,
    pos_ptr: *anyopaque,
    ss_ptr: *anyopaque,
    best_move: u16,
    prev_sq: c_int,
    quiets: [*]const u16,
    n_quiets: usize,
    captures: [*]const u16,
    n_captures: usize,
    depth: c_int,
    tt_move: u16,
    pv_node: u8,
) void {
    const w: *WorkerHistories = @ptrCast(@alignCast(worker_ptr));
    const pos: *const Position = @ptrCast(@alignCast(pos_ptr));
    const ss: *SearchStack = @ptrCast(@alignCast(ss_ptr));
    const ss_prev: *SearchStack = @ptrFromInt(@intFromPtr(ss) - @sizeOf(SearchStack));
    const capture_base: [*]i16 = &w.capture_history;

    const is_tt: u8 = if (best_move == tt_move) 1 else 0;
    var bonus = search.statBonus(depth, is_tt != 0, ss_prev.stat_score);
    const malus = search.statMalus(depth);

    // upstream 645b636df: at non-PV nodes, scale the best-move bonus by the number of searched moves.
    // Replicate C++ `bonus += bonus * uint64_t(N) / 256` EXACTLY: the mul/div are UNSIGNED (int promoted
    // to uint64_t), which differs from signed when bonus < 0; the u64 sum narrows back to i32.
    if (pv_node == 0) {
        const n: u64 = @intCast(n_quiets + n_captures);
        const bu: u64 = @bitCast(@as(i64, bonus));
        bonus = @bitCast(@as(u32, @truncate(bu +% ((bu *% n) / 256))));
    }

    if (!captureStage(pos, best_move)) {
        updateQuietHistoriesWorker(worker_ptr, pos_ptr, ss_ptr, best_move, @divTrunc(bonus * 824, 1024));
        var actual_malus: c_int = @divTrunc(malus * 1136, 1024);
        var i: usize = 0;
        while (i < n_quiets) : (i += 1) {
            actual_malus = @divTrunc(actual_malus * 956, 1024);
            updateQuietHistoriesWorker(worker_ptr, pos_ptr, ss_ptr, quiets[i], -actual_malus);
        }
    } else {
        const moved_pc = pos.board[moveFrom(best_move)];
        const to = moveTo(best_move);
        const captured_pt = pieceTypeOn(pos, to);
        const ce = &capture_base[@as(usize, moved_pc) * 512 + @as(usize, to) * 8 + captured_pt];
        statsUpdate(ce, @divTrunc(bonus * 1366, 1024), 10692);
    }

    if (prev_sq != @as(c_int, sq_none) and
        ss_prev.move_count == 1 + @as(c_int, @intFromBool(ss_prev.tt_hit)) and
        pos.st.captured_piece == 0)
    {
        const psq: u8 = @intCast(prev_sq);
        updateContinuationHistories(ss_prev, pos.board[psq], psq, @divTrunc(-malus * 683, 1024));
    }

    var j: usize = 0;
    while (j < n_captures) : (j += 1) {
        const move = captures[j];
        const moved_pc = pos.board[moveFrom(move)];
        const to = moveTo(move);
        const captured_pt = pieceTypeOn(pos, to);
        const ce = &capture_base[@as(usize, moved_pc) * 512 + @as(usize, to) * 8 + captured_pt];
        statsUpdate(ce, @divTrunc(-malus * 1518, 1024), 10692);
    }
}

const correction_history_limit: c_int = 1024;

// correctionHistory[key & sizeMinus1][us] bundle, via the SharedHistories mirror.
inline fn corrBundle(shared: *SharedHistories, key: u64) *[2]CorrectionBundle {
    const idx: usize = @intCast(key & @as(u64, shared.size_minus1));
    return &shared.corr_data[idx];
}

// update_correction_history (search.cpp): nudge the four shared correction
// tables plus the (ss-2)/(ss-4) continuation correction entries toward the
// search/static-eval delta. Zig resolves all four key-masked, color-indexed
// correction entries from the SharedHistories mirror (the Worker pointer gives
// the shared block) and owns the bonus weighting, gravity, and the stack-
// relative continuation correction writes.
pub fn updateCorrectionHistory(
    worker_ptr: *anyopaque,
    pos_ptr: *const anyopaque,
    ss_ptr: *anyopaque,
    bonus: c_int,
) void {
    const w: *WorkerHistories = @ptrCast(@alignCast(worker_ptr));
    const pos: *const Position = @ptrCast(@alignCast(pos_ptr));
    const shared = sharedOf(w);
    const us = pos.side_to_move;

    const pawn_entry = &corrBundle(shared, pos.st.pawn_key)[us].pawn;
    const minor_entry = &corrBundle(shared, pos.st.minor_piece_key)[us].minor;
    const npw_entry = &corrBundle(shared, pos.st.non_pawn_key[0])[us].nonpawn_white;
    const npb_entry = &corrBundle(shared, pos.st.non_pawn_key[1])[us].nonpawn_black;

    statsUpdate(pawn_entry, bonus, correction_history_limit);
    statsUpdate(minor_entry, @divTrunc(bonus * 152, 128), correction_history_limit);
    statsUpdate(npw_entry, @divTrunc(bonus * 186, 128), correction_history_limit);
    statsUpdate(npb_entry, @divTrunc(bonus * 186, 128), correction_history_limit);

    const ss: *SearchStack = @ptrCast(@alignCast(ss_ptr));
    const ss_prev: *SearchStack = @ptrFromInt(@intFromPtr(ss) - @sizeOf(SearchStack));
    const m = ss_prev.current_move;
    if (moveIsOk(m)) {
        const to = moveTo(m);
        const pc = pos.board[to];
        const idx = @as(usize, pc) * 64 + to;
        const ss2: *SearchStack = @ptrFromInt(@intFromPtr(ss) - 2 * @sizeOf(SearchStack));
        const ss4: *SearchStack = @ptrFromInt(@intFromPtr(ss) - 4 * @sizeOf(SearchStack));
        const cc2: [*]i16 = @ptrCast(@alignCast(ss2.continuation_correction_history.?));
        const cc4: [*]i16 = @ptrCast(@alignCast(ss4.continuation_correction_history.?));
        statsUpdate(&cc2[idx], @divTrunc(bonus * 136, 128), correction_history_limit);
        statsUpdate(&cc4[idx], @divTrunc(bonus * 68, 128), correction_history_limit);
    }
}

inline fn colorOfPiece(pc: u8) u8 {
    return pc >> 3;
}
inline fn isEmpty(pos: *const Position, s: u8) bool {
    return pos.board[s] == 0;
}

const rank1_bb: u64 = 0xFF;
const rank8_bb: u64 = 0xFF << 56;

// attacks_bb<PAWN>(s, c): squares a color-c pawn on `s` attacks.
fn pawnAttacks(color: u8, sq: u8) u64 {
    const b: u64 = @as(u64, 1) << @intCast(sq);
    if (color == color_white) {
        return ((b & ~file_h_bb) << 9) | ((b & ~file_a_bb) << 7);
    }
    return ((b & ~file_h_bb) >> 7) | ((b & ~file_a_bb) >> 9);
}

const white_oo: u8 = 1;
const white_ooo: u8 = 2;
const black_oo: u8 = 4;
const black_ooo: u8 = 8;
const black: u8 = 1;
const sq_none: u8 = 64;

const piece_to_char = " PNBRQK  pnbrqk";


// Memory mirror of upstream Stockfish StateInfo (src/position.h). Field order,
// types, and C-ABI alignment match the C++ struct exactly so Zig can read the
// live state stack that the C++ Position owns. Only used via pointer (never
// allocated here), so it must stay byte-compatible with the C++ layout.
pub const StateInfo = struct {
    material_key: u64,
    pawn_key: u64,
    minor_piece_key: u64,
    non_pawn_key: [2]u64,
    non_pawn_material: [2]c_int,
    castling_rights: c_int,
    rule50: c_int,
    plies_from_null: c_int,
    ep_square: u8,
    key: u64,
    checkers_bb: u64,
    previous: ?*StateInfo,
    blockers_for_king: [2]u64,
    pinners: [2]u64,
    check_squares: [8]u64,
    captured_piece: u8,
    repetition: c_int,
};

// Full memory image of upstream Position (src/position.h): the leading data
// members the ported code reaches through a pointer, plus the trailing NNUE
// scratch (scratch_dp/scratch_dts) that completes the object. With the scratch
// members the struct is the whole 1032-byte object, so the native graph can own
// and allocate a Position outright rather than only borrowing the C++ one.
pub const Position = struct {
    board: [64]u8,
    by_type_bb: [8]u64,
    by_color_bb: [2]u64,
    piece_count: [16]c_int,
    castling_rights_mask: [64]c_int,
    castling_rook_square: [16]u8,
    castling_path: [16]u64,
    st: *StateInfo,
    game_ply: c_int,
    side_to_move: u8,
    chess960: bool,
    scratch_dp: DirtyPiece,
    scratch_dts: DirtyThreats,
};

comptime {
    // Native struct (M16.8 de-mirror): Zig owns the field order. The only external
    // layout pin is the network's board/side reads (graph_layout.positionBoard/
    // positionSideToMove); assert they stay in sync, and that Position still fits the
    // 1032-byte slot the Worker (worker_off.root_pos) and side storage reserve for it.
    std.debug.assert(@sizeOf(Position) <= graph_layout.position_size);
    std.debug.assert(@offsetOf(Position, "side_to_move") == graph_layout.position_side_to_move_off);
    std.debug.assert(@offsetOf(Position, "board") == graph_layout.position_board_off);
}

const sq_none_u8: u8 = 64;

// Zobrist + cuckoo tables, owned by Zig (built by initRuntime, mirroring
// upstream Position::init and the xorshift64* PRNG seeded with 1070372).
var zob_psq: [16 * 64]u64 = undefined;
var zob_enpassant: [8]u64 = undefined;
var zob_castling: [16]u64 = undefined;
var zob_side_val: u64 = undefined;
var zob_no_pawns: u64 = undefined;
var cuckoo_tbl: [8192]u64 = undefined;
var cuckoo_move_tbl: [8192]u16 = undefined;

const Prng = struct {
    s: u64,
    fn rand64(self: *Prng) u64 {
        self.s ^= self.s >> 12;
        self.s ^= self.s << 25;
        self.s ^= self.s >> 27;
        return self.s *% 2685821657736338717;
    }
};

const init_pieces = [_]u8{ 1, 2, 3, 4, 5, 6, 9, 10, 11, 12, 13, 14 };

pub fn initRuntime() void {
    // Register the cycle-break hooks movegen/movepick/nnue/uci_move call (they can't
    // import position). Replaces the zfish_position_fill_snapshot / _move_is_legal
    // C-ABI exports.
    position_snapshot_port.fill_fn = &fillSnapshot;
    position_snapshot_port.move_is_legal_fn = &legal;

    var rng = Prng{ .s = 1070372 };
    @memset(&zob_psq, 0);
    for (init_pieces) |pc| {
        for (0..64) |s| zob_psq[@as(usize, pc) * 64 + s] = rng.rand64();
    }
    for (56..64) |s| zob_psq[1 * 64 + s] = 0; // W_PAWN promotion rank
    for (0..8) |s| zob_psq[9 * 64 + s] = 0; // B_PAWN promotion rank
    for (0..8) |f| zob_enpassant[f] = rng.rand64();
    for (0..16) |cr| zob_castling[cr] = rng.rand64();
    zob_side_val = rng.rand64();
    zob_no_pawns = rng.rand64();

    @memset(&cuckoo_tbl, 0);
    @memset(&cuckoo_move_tbl, 0);
    for (init_pieces) |pc| {
        const pt = pc & 7;
        var s1: u8 = 0;
        while (s1 < 64) : (s1 += 1) {
            var s2: u8 = s1 + 1;
            while (s2 < 64) : (s2 += 1) {
                if ((bitboard.attacks(pt, s1, 0) & sqBb(s2)) != 0) {
                    var move: u16 = (@as(u16, s1) << 6) | s2;
                    var key = zob_psq[psqIdx(pc, s1)] ^ zob_psq[psqIdx(pc, s2)] ^ zob_side_val;
                    var i = h1(key);
                    while (true) {
                        const tk = cuckoo_tbl[i];
                        cuckoo_tbl[i] = key;
                        key = tk;
                        const tm = cuckoo_move_tbl[i];
                        cuckoo_move_tbl[i] = move;
                        move = tm;
                        if (move == 0) break;
                        i = if (i == h1(key)) h2(key) else h1(key);
                    }
                }
            }
        }
    }
}

pub fn doNullMove(pos_ptr: *anyopaque, new_st_ptr: *anyopaque) void {
    const pos: *Position = @ptrCast(@alignCast(pos_ptr));
    const new_st: *StateInfo = @ptrCast(@alignCast(new_st_ptr));

    new_st.* = pos.st.*; // memcpy(&newSt, st, sizeof(StateInfo))
    new_st.previous = pos.st;
    pos.st = new_st;

    if (pos.st.ep_square != sq_none_u8) {
        pos.st.key ^= zob_enpassant[fileOf(pos.st.ep_square)];
        pos.st.ep_square = sq_none_u8;
    }
    pos.st.key ^= zob_side_val;
    pos.st.plies_from_null = 0;

    // Upstream 782852b26: the StateInfo was copied from the previous ply (incl. its capturedPiece);
    // a null move captures nothing, so clear it or prior_capture detection reads a stale value.
    pos.st.captured_piece = 0; // NO_PIECE

    pos.side_to_move ^= 1;
    setCheckInfo(pos_ptr);
    pos.st.repetition = 0;
}

pub fn undoNullMove(pos_ptr: *anyopaque) void {
    const pos: *Position = @ptrCast(@alignCast(pos_ptr));
    pos.st = pos.st.previous.?;
    pos.side_to_move ^= 1;
}

inline fn h1(key: u64) usize {
    return @intCast(key & 0x1fff);
}
inline fn h2(key: u64) usize {
    return @intCast((key >> 16) & 0x1fff);
}

pub fn upcomingRepetition(pos_ptr: *const anyopaque, ply: c_int) bool {
    const cuckoo: [*]const u64 = &cuckoo_tbl;
    const cuckoo_move: [*]const u16 = &cuckoo_move_tbl;
    const pos: *const Position = @ptrCast(@alignCast(pos_ptr));
    const end = @min(pos.st.rule50, pos.st.plies_from_null);
    if (end < 3) return false;

    const original_key = pos.st.key;
    var stp: *const StateInfo = pos.st.previous.?;
    var other = original_key ^ stp.key ^ zob_side_val;

    var i: c_int = 3;
    while (i <= end) : (i += 2) {
        stp = stp.previous.?;
        other ^= stp.key ^ stp.previous.?.key ^ zob_side_val;
        stp = stp.previous.?;
        if (other != 0) continue;

        const move_key = original_key ^ stp.key;
        var j = h1(move_key);
        if (cuckoo[j] != move_key) {
            j = h2(move_key);
            if (cuckoo[j] != move_key) continue;
        }

        const mv = cuckoo_move[j];
        const s1 = moveFrom(mv);
        const s2 = moveTo(mv);
        if (((bitboard.between(s1, s2) ^ sqBb(s2)) & pos.by_type_bb[0]) == 0) {
            if (ply > i) return true;
            if (stp.repetition != 0) return true;
        }
    }
    return false;
}

pub fn isDraw(pos_ptr: *const anyopaque, ply: c_int) bool {
    const pos: *const Position = @ptrCast(@alignCast(pos_ptr));
    if (pos.st.rule50 > 99) {
        if (pos.st.checkers_bb == 0) return true;
        var buf: [256]u16 = undefined;
        if (movegen.generateLegal(pos_ptr, &buf) != 0) return true;
    }
    return isRepetition(pos_ptr, ply);
}

pub fn isRepetition(pos_ptr: *const anyopaque, ply: c_int) bool {
    const pos: *const Position = @ptrCast(@alignCast(pos_ptr));
    const rep = pos.st.repetition;
    return rep != 0 and rep < ply;
}

pub fn hasRepeated(pos_ptr: *const anyopaque) bool {
    const pos: *const Position = @ptrCast(@alignCast(pos_ptr));
    var stc: *const StateInfo = pos.st;
    var end = @min(pos.st.rule50, pos.st.plies_from_null);
    while (end >= 4) : (end -= 1) {
        if (stc.repetition != 0) return true;
        stc = stc.previous.?;
    }
    return false;
}

pub fn attackersTo(pos_ptr: *const anyopaque, s: u8, occupied: u64) u64 {
    const pos: *const Position = @ptrCast(@alignCast(pos_ptr));
    const rook_queen = pos.by_type_bb[rook_pt] | pos.by_type_bb[queen_pt];
    const bishop_queen = pos.by_type_bb[bishop_pt] | pos.by_type_bb[queen_pt];
    const white_pawns = pos.by_color_bb[color_white] & pos.by_type_bb[pawn_pt];
    const black_pawns = pos.by_color_bb[color_black] & pos.by_type_bb[pawn_pt];
    return (bitboard.attacks(rook_pt, s, occupied) & rook_queen) |
        (bitboard.attacks(bishop_pt, s, occupied) & bishop_queen) |
        (pawnAttacks(color_black, s) & white_pawns) |
        (pawnAttacks(color_white, s) & black_pawns) |
        (bitboard.attacks(knight_pt, s, 0) & pos.by_type_bb[knight_pt]) |
        (bitboard.attacks(king_pt, s, 0) & pos.by_type_bb[king_pt]);
}

fn kingSquare(pos: *const Position, c: u8) u8 {
    return @intCast(@ctz(pos.by_color_bb[c] & pos.by_type_bb[king_pt]));
}

pub fn flipFen(fen_ptr: [*]const u8, fen_len: usize) ?[*:0]u8 {
    return flipFenAlloc(fen_ptr[0..fen_len]) catch null;
}

fn flipFenAlloc(fen: []const u8) ![*:0]u8 {
    const alloc = std.heap.c_allocator;
    var it = std.mem.tokenizeScalar(u8, fen, ' ');
    const placement = it.next() orelse return error.BadFen;
    const active = it.next() orelse return error.BadFen;
    const castling = it.next() orelse return error.BadFen;
    const ep = it.next() orelse return error.BadFen;
    const rest = it.rest(); // half/full move counters

    var out = std.ArrayList(u8).empty;
    defer out.deinit(alloc);

    // Piece placement with the rank order reversed (vertical mirror).
    var ranks: [8][]const u8 = undefined;
    var nr: usize = 0;
    var rank_it = std.mem.splitScalar(u8, placement, '/');
    while (rank_it.next()) |r| : (nr += 1) ranks[nr] = r;
    var ri: usize = nr;
    while (ri > 0) {
        ri -= 1;
        try out.appendSlice(alloc, ranks[ri]);
        if (ri > 0) try out.append(alloc, '/');
    }
    try out.append(alloc, ' ');
    try out.append(alloc, if (active[0] == 'w') 'B' else 'W');
    try out.append(alloc, ' ');
    try out.appendSlice(alloc, castling);

    // Swap the case of everything so far: flips piece colors, the active color,
    // and castling-rights case in one pass (matches upstream flip()).
    for (out.items) |*ch| {
        ch.* = if (std.ascii.isLower(ch.*)) std.ascii.toUpper(ch.*) else std.ascii.toLower(ch.*);
    }

    try out.append(alloc, ' ');
    if (std.mem.eql(u8, ep, "-")) {
        try out.append(alloc, '-');
    } else {
        try out.append(alloc, ep[0]);
        try out.append(alloc, if (ep[1] == '3') @as(u8, '6') else @as(u8, '3'));
    }
    try out.append(alloc, ' ');
    try out.appendSlice(alloc, rest);

    return try allocCString(out.items);
}

pub fn setCastlingRight(pos_ptr: *anyopaque, c: u8, rfrom: u8) void {
    const pos: *Position = @ptrCast(@alignCast(pos_ptr));
    const kfrom = kingSquare(pos, c);
    const side_mask: u8 = if (kfrom < rfrom) 5 else 10; // KING_SIDE : QUEEN_SIDE
    const color_castling: u8 = if (c == color_white) 3 else 12; // WHITE_CASTLING : BLACK_CASTLING
    const cr: u8 = color_castling & side_mask;

    pos.st.castling_rights |= @as(c_int, cr);
    pos.castling_rights_mask[kfrom] |= @as(c_int, cr);
    pos.castling_rights_mask[rfrom] |= @as(c_int, cr);
    pos.castling_rook_square[cr] = rfrom;

    const king_side = (cr & 5) != 0;
    const kto = relativeSquare(c, if (king_side) 6 else 2); // SQ_G1 : SQ_C1
    const rto = relativeSquare(c, if (king_side) 5 else 3); // SQ_F1 : SQ_D1
    pos.castling_path[cr] = (bitboard.between(rfrom, rto) | bitboard.between(kfrom, kto)) &
        ~(sqBb(kfrom) | sqBb(rfrom));
}

pub fn updateSliderBlockers(pos_ptr: *const anyopaque, c: u8) void {
    const pos: *const Position = @ptrCast(@alignCast(pos_ptr));
    const ksq = kingSquare(pos, c);
    const nc = c ^ 1;
    pos.st.blockers_for_king[c] = 0;
    pos.st.pinners[nc] = 0;

    const queen_rook = pos.by_type_bb[queen_pt] | pos.by_type_bb[rook_pt];
    const queen_bishop = pos.by_type_bb[queen_pt] | pos.by_type_bb[bishop_pt];
    var snipers = ((bitboard.attacks(rook_pt, ksq, 0) & queen_rook) |
        (bitboard.attacks(bishop_pt, ksq, 0) & queen_bishop)) & pos.by_color_bb[nc];
    const occupancy = pos.by_type_bb[0] ^ snipers;

    while (snipers != 0) {
        const sniper_sq: u8 = @intCast(@ctz(snipers));
        snipers &= snipers - 1;
        const b = bitboard.between(ksq, sniper_sq) & occupancy;
        if (b != 0 and (b & (b -% 1)) == 0) {
            pos.st.blockers_for_king[c] |= b;
            if ((b & pos.by_color_bb[c]) != 0) {
                pos.st.pinners[nc] |= (@as(u64, 1) << @intCast(sniper_sq));
            }
        }
    }
}

const max_u64: u64 = 0xFFFFFFFFFFFFFFFF;

// Mirrors of the NNUE dirty-state structs (src/types.h) the accumulator consumes.
const DirtyPiece = struct {
    pc: u8,
    from: u8,
    to: u8,
    remove_sq: u8,
    add_sq: u8,
    remove_pc: u8,
    add_pc: u8,
};
const DirtyThreats = struct {
    list_values: [96]u32, // ValueList<DirtyThreat,96>::values_
    list_size: usize, // ValueList<...>::size_
    us: u8,
    prev_ksq: u8,
    ksq: u8,
};

fn addDirtyThreat(dts: *DirtyThreats, put_piece: bool, pc: u8, threatened: u8, s: u8, threatened_sq: u8) void {
    const data: u32 = (@as(u32, @intFromBool(put_piece)) << 31) |
        (@as(u32, pc) << 20) | (@as(u32, threatened) << 16) |
        (@as(u32, threatened_sq) << 8) | @as(u32, s);
    dts.list_values[dts.list_size] = data;
    dts.list_size += 1;
}

fn pawnPushOrAttacks(c: u8, s: u8) u64 {
    const b = sqBb(s);
    const push = if (c == color_white) b << 8 else b >> 8;
    return push | pawnAttacks(c, s);
}

fn processSliders(
    pos: *const Position,
    dts: *DirtyThreats,
    sliders_in: u64,
    s: u8,
    pc: u8,
    put_piece: bool,
    no_rays: u64,
    r_attacks: u64,
    b_attacks: u64,
    occupied_no_k: u64,
    add_direct: bool,
) void {
    var sliders = sliders_in;
    while (sliders != 0) {
        const slider_sq: u8 = @intCast(@ctz(sliders));
        sliders &= sliders - 1;
        const slider = pos.board[slider_sq];
        const ray = bitboard.rayPass(slider_sq, s);
        const discovered = ray & (r_attacks | b_attacks) & occupied_no_k;
        if (discovered != 0 and (ray & no_rays) != no_rays) {
            const tsq: u8 = @intCast(@ctz(discovered));
            addDirtyThreat(dts, !put_piece, slider, pos.board[tsq], slider_sq, tsq);
        }
        if (add_direct) addDirtyThreat(dts, put_piece, slider, pc, slider_sq, s);
    }
}

fn updatePieceThreats(
    pos: *const Position,
    pc: u8,
    put_piece: bool,
    s: u8,
    dts: *DirtyThreats,
    no_rays: u64,
    compute_ray: bool,
) void {
    const occupied = pos.by_type_bb[0];
    const rook_queens = pos.by_type_bb[rook_pt] | pos.by_type_bb[queen_pt];
    const bishop_queens = pos.by_type_bb[bishop_pt] | pos.by_type_bb[queen_pt];
    const r_attacks = bitboard.attacks(rook_pt, s, occupied);
    const b_attacks = bitboard.attacks(bishop_pt, s, occupied);
    const kings = pos.by_type_bb[king_pt];
    const occupied_no_k = occupied ^ kings;
    const sliders = (rook_queens & r_attacks) | (bishop_queens & b_attacks);

    if ((pc & 7) == king_pt) {
        if (compute_ray)
            processSliders(pos, dts, sliders, s, pc, put_piece, no_rays, r_attacks, b_attacks, occupied_no_k, false);
        return;
    }

    const knights = pos.by_type_bb[knight_pt];
    const white_pawns = pos.by_color_bb[color_white] & pos.by_type_bb[pawn_pt];
    const black_pawns = pos.by_color_bb[color_black] & pos.by_type_bb[pawn_pt];

    var threatened = (if ((pc & 7) == pawn_pt) pawnAttacks(pc >> 3, s) else bitboard.attacks(pc & 7, s, occupied)) & occupied_no_k;
    var incoming = (bitboard.attacks(knight_pt, s, 0) & knights) | (bitboard.attacks(king_pt, s, 0) & kings);

    if ((pc & 7) == pawn_pt) {
        const white_attacks = pawnPushOrAttacks(color_white, s);
        const black_attacks = pawnPushOrAttacks(color_black, s);
        threatened |= (if ((pc >> 3) == color_white) white_attacks else black_attacks) & pos.by_type_bb[pawn_pt];
        incoming |= white_attacks & black_pawns;
        incoming |= black_attacks & white_pawns;
    } else {
        incoming |= (pawnAttacks(color_white, s) & black_pawns) | (pawnAttacks(color_black, s) & white_pawns);
    }

    while (threatened != 0) {
        const tsq: u8 = @intCast(@ctz(threatened));
        threatened &= threatened - 1;
        addDirtyThreat(dts, put_piece, pc, pos.board[tsq], s, tsq);
    }

    if (compute_ray) {
        processSliders(pos, dts, sliders, s, pc, put_piece, no_rays, r_attacks, b_attacks, occupied_no_k, true);
    } else {
        incoming |= sliders;
    }

    while (incoming != 0) {
        const src_sq: u8 = @intCast(@ctz(incoming));
        incoming &= incoming - 1;
        addDirtyThreat(dts, put_piece, pos.board[src_sq], pc, src_sq, s);
    }
}

fn removePieceDts(pos: *Position, s: u8, dts: *DirtyThreats) void {
    const pc = pos.board[s];
    updatePieceThreats(pos, pc, false, s, dts, max_u64, true);
    const bb = sqBb(s);
    pos.by_type_bb[0] ^= bb;
    pos.by_type_bb[pc & 7] ^= bb;
    pos.by_color_bb[pc >> 3] ^= bb;
    pos.board[s] = 0;
    pos.piece_count[pc] -= 1;
    pos.piece_count[(pc >> 3) << 3] -= 1;
}

fn putPieceDts(pos: *Position, pc: u8, s: u8, dts: *DirtyThreats) void {
    const bb = sqBb(s);
    pos.board[s] = pc;
    pos.by_type_bb[pc & 7] |= bb;
    pos.by_type_bb[0] |= pos.by_type_bb[pc & 7];
    pos.by_color_bb[pc >> 3] |= bb;
    pos.piece_count[pc] += 1;
    pos.piece_count[(pc >> 3) << 3] += 1;
    updatePieceThreats(pos, pc, true, s, dts, max_u64, true);
}

fn movePieceDts(pos: *Position, from: u8, to: u8, dts: *DirtyThreats) void {
    const pc = pos.board[from];
    const from_to = sqBb(from) | sqBb(to);
    updatePieceThreats(pos, pc, false, from, dts, from_to, true);
    pos.by_type_bb[0] ^= from_to;
    pos.by_type_bb[pc & 7] ^= from_to;
    pos.by_color_bb[pc >> 3] ^= from_to;
    pos.board[from] = 0;
    pos.board[to] = pc;
    updatePieceThreats(pos, pc, true, to, dts, from_to, true);
}

fn swapPieceDts(pos: *Position, s: u8, pc: u8, dts: *DirtyThreats) void {
    const old = pos.board[s];
    removePiece(pos, s); // dts=nullptr in swap_piece
    updatePieceThreats(pos, old, false, s, dts, max_u64, false);
    putPiece(pos, pc, s);
    updatePieceThreats(pos, pc, true, s, dts, max_u64, false);
}

fn removePiece(pos: *Position, s: u8) void {
    const pc = pos.board[s];
    const bb = sqBb(s);
    pos.by_type_bb[0] ^= bb;
    pos.by_type_bb[pc & 7] ^= bb;
    pos.by_color_bb[pc >> 3] ^= bb;
    pos.board[s] = 0;
    pos.piece_count[pc] -= 1;
    pos.piece_count[(pc >> 3) << 3] -= 1;
}

fn movePieceQuiet(pos: *Position, from: u8, to: u8) void {
    const pc = pos.board[from];
    const from_to = sqBb(from) | sqBb(to);
    pos.by_type_bb[0] ^= from_to;
    pos.by_type_bb[pc & 7] ^= from_to;
    pos.by_color_bb[pc >> 3] ^= from_to;
    pos.board[from] = 0;
    pos.board[to] = pc;
}

fn swapPiece(pos: *Position, s: u8, pc: u8) void {
    removePiece(pos, s);
    putPiece(pos, pc, s);
}

inline fn psqIdx(pc: u8, sq: u8) usize {
    return @as(usize, pc) * 64 + sq;
}

const CastleSquares = struct { to: u8, rfrom: u8, rto: u8 };

fn doCastlingDo(pos: *Position, us: u8, from: u8, to_in: u8, dp: *DirtyPiece, dts: *DirtyThreats) CastleSquares {
    const king_side = to_in > from;
    const rfrom = to_in; // king-captures-rook encoding
    const rto = relativeSquare(us, if (king_side) 5 else 3); // SQ_F1 : SQ_D1
    const to = relativeSquare(us, if (king_side) 6 else 2); // SQ_G1 : SQ_C1
    dp.to = to;
    dp.remove_pc = (us << 3) | rook_pt;
    dp.add_pc = (us << 3) | rook_pt;
    dp.remove_sq = rfrom;
    dp.add_sq = rto;
    removePieceDts(pos, from, dts);
    removePieceDts(pos, rfrom, dts);
    putPieceDts(pos, (us << 3) | king_pt, to, dts);
    putPieceDts(pos, (us << 3) | rook_pt, rto, dts);
    return .{ .to = to, .rfrom = rfrom, .rto = rto };
}

pub fn doMove(
    pos_ptr: *anyopaque,
    m: u16,
    new_st_ptr: *anyopaque,
    gives_check: u8,
    dp_ptr: *anyopaque,
    dts_ptr: *anyopaque,
) void {
    const psq: [*]const u64 = &zob_psq;
    const enpassant: [*]const u64 = &zob_enpassant;
    const castling: [*]const u64 = &zob_castling;
    const zob_side = zob_side_val;
    const pos: *Position = @ptrCast(@alignCast(pos_ptr));
    const new_st: *StateInfo = @ptrCast(@alignCast(new_st_ptr));
    const dp: *DirtyPiece = @ptrCast(@alignCast(dp_ptr));
    const dts: *DirtyThreats = @ptrCast(@alignCast(dts_ptr));

    var k = pos.st.key ^ zob_side;

    // Carry the "copied when making a move" StateInfo fields (the C++ memcpy prefix up
    // to offsetof(key)); StateInfo is a native struct now, so copy them by field rather
    // than assuming a byte-contiguous 64-byte prefix.
    new_st.material_key = pos.st.material_key;
    new_st.pawn_key = pos.st.pawn_key;
    new_st.minor_piece_key = pos.st.minor_piece_key;
    new_st.non_pawn_key = pos.st.non_pawn_key;
    new_st.non_pawn_material = pos.st.non_pawn_material;
    new_st.castling_rights = pos.st.castling_rights;
    new_st.rule50 = pos.st.rule50;
    new_st.plies_from_null = pos.st.plies_from_null;
    new_st.ep_square = pos.st.ep_square;
    new_st.previous = pos.st;
    pos.st = new_st;

    pos.game_ply += 1;
    pos.st.rule50 += 1;
    pos.st.plies_from_null += 1;

    const us = pos.side_to_move;
    const them = us ^ 1;
    const from = moveFrom(m);
    var to = moveTo(m);
    const mt = moveTypeOf(m);
    const pc = pos.board[from];
    var captured: u8 = if (mt == mt_en_passant) (them << 3) | pawn_pt else pos.board[to];

    dp.pc = pc;
    dp.from = from;
    dp.to = to;
    dp.add_sq = sq_none_u8;
    dts.us = us;
    dts.prev_ksq = kingSquare(pos, us);

    if (mt == mt_castling) {
        const r = doCastlingDo(pos, us, from, to, dp, dts);
        to = r.to; // do_castling takes `to` by reference and sets it to the king's destination
        k ^= psq[psqIdx(captured, r.rfrom)] ^ psq[psqIdx(captured, r.rto)];
        pos.st.non_pawn_key[us] ^= psq[psqIdx(captured, r.rfrom)] ^ psq[psqIdx(captured, r.rto)];
        captured = 0;
    } else if (captured != 0) {
        var capsq = to;
        if ((captured & 7) == pawn_pt) {
            if (mt == mt_en_passant) {
                capsq = @intCast(@as(i16, to) - pawnPush(us));
                removePieceDts(pos, capsq, dts);
            }
            pos.st.pawn_key ^= psq[psqIdx(captured, capsq)];
        } else {
            pos.st.non_pawn_material[them] -= piece_value_by_type[captured & 7];
            pos.st.non_pawn_key[them] ^= psq[psqIdx(captured, capsq)];
            if ((captured & 7) <= bishop_pt) pos.st.minor_piece_key ^= psq[psqIdx(captured, capsq)];
        }
        dp.remove_pc = captured;
        dp.remove_sq = capsq;
        k ^= psq[psqIdx(captured, capsq)];
        const mat_slot: u8 = @intCast(8 + pos.piece_count[captured] - @as(c_int, if (mt != mt_en_passant) 1 else 0));
        pos.st.material_key ^= psq[psqIdx(captured, mat_slot)];
        pos.st.rule50 = 0;
    } else {
        dp.remove_sq = sq_none_u8;
    }

    k ^= psq[psqIdx(pc, from)] ^ psq[psqIdx(pc, to)];

    if (pos.st.ep_square != sq_none_u8) {
        k ^= enpassant[fileOf(pos.st.ep_square)];
        pos.st.ep_square = sq_none_u8;
    }

    k ^= castling[@intCast(pos.st.castling_rights)];
    pos.st.castling_rights &= ~(pos.castling_rights_mask[from] | pos.castling_rights_mask[to]);
    k ^= castling[@intCast(pos.st.castling_rights)];

    if (mt != mt_castling) {
        var to_pc = pc;
        if (mt == mt_promotion) to_pc = (us << 3) | movePromotionType(m);
        if (captured != 0 and mt != mt_en_passant) {
            removePieceDts(pos, from, dts);
            swapPieceDts(pos, to, to_pc, dts);
        } else if (pc == to_pc) {
            movePieceDts(pos, from, to, dts);
        } else {
            removePieceDts(pos, from, dts);
            putPieceDts(pos, to_pc, to, dts);
        }
    }

    if ((pc & 7) == pawn_pt) {
        if ((@as(i32, to) ^ @as(i32, from)) == 16) {
            const ep_sq: u8 = @intCast(@as(i16, to) - pawnPush(us));
            const their_pawns = pos.by_color_bb[them] & pos.by_type_bb[pawn_pt];
            const pawns = pawnAttacks(us, ep_sq) & their_pawns;
            if (pawns != 0) {
                const ksq = kingSquare(pos, them);
                const not_blockers = ~pos.st.previous.?.blockers_for_king[them];
                const no_discovery = (sqBb(from) & not_blockers) != 0 or fileOf(from) == fileOf(ksq);
                if (no_discovery and (pawns & (not_blockers | bitboard.line(ep_sq, ksq))) != 0) {
                    pos.st.ep_square = ep_sq;
                    k ^= enpassant[fileOf(ep_sq)];
                }
            }
        } else if (mt == mt_promotion) {
            const pt = movePromotionType(m);
            const promotion = (us << 3) | pt;
            dp.add_pc = promotion;
            dp.add_sq = to;
            dp.to = sq_none_u8;
            k ^= psq[psqIdx(promotion, to)];
            const prom_slot: u8 = @intCast(8 + pos.piece_count[promotion] - 1);
            const pawn_slot: u8 = @intCast(8 + pos.piece_count[pc]);
            pos.st.material_key ^= psq[psqIdx(promotion, prom_slot)] ^ psq[psqIdx(pc, pawn_slot)];
            pos.st.non_pawn_key[us] ^= psq[psqIdx(promotion, to)];
            if (pt <= bishop_pt) pos.st.minor_piece_key ^= psq[psqIdx(promotion, to)];
            pos.st.non_pawn_material[us] += piece_value_by_type[pt];
        }
        pos.st.pawn_key ^= psq[psqIdx(pc, from)] ^ psq[psqIdx(pc, to)];
        pos.st.rule50 = 0;
    } else {
        pos.st.non_pawn_key[us] ^= psq[psqIdx(pc, from)] ^ psq[psqIdx(pc, to)];
        if ((pc & 7) <= bishop_pt) pos.st.minor_piece_key ^= psq[psqIdx(pc, from)] ^ psq[psqIdx(pc, to)];
    }

    pos.st.key = k;
    pos.st.captured_piece = captured;
    pos.st.checkers_bb = if (gives_check != 0)
        attackersTo(pos_ptr, kingSquare(pos, them), pos.by_type_bb[0]) & pos.by_color_bb[us]
    else
        0;
    pos.side_to_move ^= 1;
    setCheckInfo(pos_ptr);

    pos.st.repetition = 0;
    const end = @min(pos.st.rule50, pos.st.plies_from_null);
    if (end >= 4) {
        var stp = pos.st.previous.?.previous.?;
        var i: c_int = 4;
        while (i <= end) : (i += 2) {
            stp = stp.previous.?.previous.?;
            if (stp.key == pos.st.key) {
                pos.st.repetition = if (stp.repetition != 0) -i else i;
                break;
            }
        }
    }

    dts.ksq = kingSquare(pos, us);
}

pub fn undoMove(pos_ptr: *anyopaque, m: u16) void {
    const pos: *Position = @ptrCast(@alignCast(pos_ptr));
    pos.side_to_move ^= 1;
    const us = pos.side_to_move;
    const from = moveFrom(m);
    const to = moveTo(m);
    const mt = moveTypeOf(m);

    if (mt == mt_promotion) {
        swapPiece(pos, to, (us << 3) | pawn_pt);
    }

    if (mt == mt_castling) {
        const king_side = to > from;
        const rfrom = to; // encoded as king-captures-rook
        const rto = relativeSquare(us, if (king_side) 5 else 3); // SQ_F1 : SQ_D1
        const king_dest = relativeSquare(us, if (king_side) 6 else 2); // SQ_G1 : SQ_C1
        removePiece(pos, king_dest);
        removePiece(pos, rto);
        putPiece(pos, (us << 3) | king_pt, from);
        putPiece(pos, (us << 3) | rook_pt, rfrom);
    } else {
        movePieceQuiet(pos, to, from);
        if (pos.st.captured_piece != 0) {
            var capsq = to;
            if (mt == mt_en_passant) capsq = @intCast(@as(i16, to) - pawnPush(us));
            putPiece(pos, pos.st.captured_piece, capsq);
        }
    }

    pos.st = pos.st.previous.?;
    pos.game_ply -= 1;
}

fn putPiece(pos: *Position, pc: u8, s: u8) void {
    const bb = sqBb(s);
    pos.board[s] = pc;
    pos.by_type_bb[pc & 7] |= bb;
    pos.by_type_bb[0] |= pos.by_type_bb[pc & 7];
    pos.by_color_bb[pc >> 3] |= bb;
    pos.piece_count[pc] += 1;
    pos.piece_count[(pc >> 3) << 3] += 1; // make_piece(color, ALL_PIECES)
}

inline fn countPt(pos: *const Position, c: u8, pt: u8) c_int {
    return pos.piece_count[(c << 3) | pt];
}
inline fn pawnPush(c: u8) i16 {
    return if (c == color_white) 8 else -8;
}
fn pieceCharIndex(token: u8) ?u8 {
    for (piece_to_char, 0..) |ch, idx| {
        if (ch == token and ch != ' ') return @intCast(idx);
    }
    return null;
}
fn setErr(comptime msg: []const u8) ?[*:0]u8 {
    return allocCString(msg) catch null;
}

const FenCursor = struct {
    fen: []const u8,
    i: usize = 0,
    fn next(self: *FenCursor) ?u8 {
        if (self.i >= self.fen.len) return null;
        const ch = self.fen[self.i];
        self.i += 1;
        return ch;
    }
    fn skipWs(self: *FenCursor) void {
        while (self.i < self.fen.len and std.ascii.isWhitespace(self.fen[self.i])) self.i += 1;
    }
};

pub fn setPosition(
    pos_ptr: *anyopaque,
    fen_ptr: [*]const u8,
    fen_len: usize,
    is_chess960: u8,
    st_ptr: *anyopaque,
    pos_size: usize,
    st_size: usize,
) ?[*:0]u8 {
    const pos: *Position = @ptrCast(@alignCast(pos_ptr));
    @memset(@as([*]u8, @ptrCast(pos))[0..pos_size], 0);
    @memset(@as([*]u8, @ptrCast(st_ptr))[0..st_size], 0);
    pos.st = @ptrCast(@alignCast(st_ptr));

    var cur = FenCursor{ .fen = fen_ptr[0..fen_len] };

    // 1. Piece placement
    var num_pieces: c_int = 0;
    var file: i32 = 0;
    var rank: i32 = 7;
    while (cur.next()) |token| {
        if (std.ascii.isWhitespace(token)) break;
        if (token >= '0' and token <= '9') {
            const diff: i32 = token - '0';
            if (diff < 1 or diff > 8) return setErr("Invalid FEN. Invalid number of squares to skip.");
            file += diff;
            if (file > 8) return setErr("Invalid FEN. Invalid file reached.");
        } else if (token == '/') {
            if (file != 8) return setErr("Invalid FEN. Trying to end rank when not at the end of it.");
            rank -= 1;
            file = 0;
            if (rank < 0) return setErr("Invalid FEN. Invalid rank reached.");
        } else {
            if (file >= 8) return setErr("Invalid FEN. Invalid file reached.");
            const idx = pieceCharIndex(token) orelse return setErr("Invalid FEN. Invalid piece.");
            num_pieces += 1;
            if (num_pieces > 32) return setErr("Invalid FEN. More than 32 pieces on the board.");
            putPiece(pos, idx, makeSquare(@intCast(file), @intCast(rank)));
            file += 1;
        }
    }
    if (rank != 0 or file != 8)
        return setErr("Invalid FEN. Board state encoding ended but cursor not at end.");
    if ((pos.by_type_bb[pawn_pt] & (rank1_bb | rank8_bb)) != 0)
        return setErr("Unsupported position. Pawns on the first or eighth rank.");
    if (countPt(pos, color_white, king_pt) != 1 or countPt(pos, color_black, king_pt) != 1)
        return setErr("Unsupported position. Incorrect number of kings.");

    // 2. Active color
    const active = cur.next() orelse return setErr("Invalid FEN. Unexpected end of stream.");
    if (active != 'w' and active != 'b') return setErr("Invalid FEN. Invalid side to move.");
    pos.side_to_move = if (active == 'w') color_white else color_black;
    const stm = pos.side_to_move;
    const them = stm ^ 1;
    const ws = cur.next();
    if (ws == null or !std.ascii.isWhitespace(ws.?) or cur.i >= cur.fen.len)
        return setErr("Invalid FEN. Expected whitespace after side to move.");

    // 3. Castling availability
    var num_castling: c_int = 0;
    while (cur.next()) |tok0| {
        var token = tok0;
        if (std.ascii.isWhitespace(token)) break;
        if (num_castling == 0 and token == '-') {
            cur.skipWs();
            break;
        }
        num_castling += 1;
        if (num_castling > 4) return setErr("Invalid FEN. Maximum of 4 castling rights can be specified.");

        const c: u8 = if (std.ascii.isLower(token)) color_black else color_white;
        const rook = (c << 3) | rook_pt;
        const king = (c << 3) | king_pt;
        token = std.ascii.toUpper(token);

        var rsq: i32 = -1;
        var ksq: i32 = -1;
        if (token == 'K' or token == 'Q') {
            const dir: i32 = if (token == 'K') -1 else 1;
            var sq: i32 = relativeSquare(c, if (token == 'K') 7 else 0); // SQ_H1 : SQ_A1
            var n: usize = 0;
            while (n < 7) : (n += 1) {
                const pc = pos.board[@intCast(sq)];
                if (pc == king) {
                    ksq = sq;
                    break;
                } else if (pc == rook and rsq == -1) {
                    rsq = sq;
                }
                sq += dir;
            }
        } else if (token >= 'A' and token <= 'H') {
            const rel_rank1 = relativeSquare(c, 0) >> 3; // rank of relative SQ_A1
            const rsq_cand = makeSquare(token - 'A', rel_rank1);
            if (pos.board[rsq_cand] == rook) rsq = rsq_cand;
            var sq: i32 = relativeSquare(c, 1); // SQ_B1
            var n: usize = 0;
            while (n < 6) : (n += 1) {
                if (pos.board[@intCast(sq)] == king) ksq = sq;
                sq += 1;
            }
        } else return setErr("Invalid FEN. Expected castling rights.");

        if (ksq != -1 and rsq != -1) setCastlingRight(pos_ptr, c, @intCast(rsq));
    }

    // 4. En passant square
    var enpassant_ok = false;
    var legal_ep = false;
    const col = cur.next() orelse '-';
    if (col != '-') {
        const row = cur.next() orelse return setErr("Invalid FEN. Unexpected end of stream.");
        if ((col >= 'a' and col <= 'h') and (row == (if (stm == color_white) @as(u8, '6') else '3'))) {
            const ep = makeSquare(col - 'a', row - '1');
            pos.st.ep_square = ep;
            const all = pos.by_type_bb[0];
            const our_pawns = pos.by_color_bb[stm] & pos.by_type_bb[pawn_pt];
            const their_pawns = pos.by_color_bb[them] & pos.by_type_bb[pawn_pt];
            var pawns = pawnAttacks(them, ep) & our_pawns;
            const target_sq: u8 = @intCast(@as(i16, ep) + pawnPush(them));
            const target = their_pawns & sqBb(target_sq);
            const behind_sq: u8 = @intCast(@as(i16, ep) + pawnPush(stm));
            enpassant_ok = pawns != 0 and target != 0 and (all & (sqBb(ep) | sqBb(behind_sq))) == 0;
            const occ = all ^ target ^ sqBb(ep);
            const ksq = kingSquare(pos, stm);
            while (pawns != 0) {
                const pawn_sq: u8 = @intCast(@ctz(pawns));
                pawns &= pawns - 1;
                if ((attackersTo(pos_ptr, ksq, occ ^ sqBb(pawn_sq)) & pos.by_color_bb[them] & ~target) == 0)
                    legal_ep = true;
            }
        } else return setErr("Invalid FEN. Invalid en-passant square.");
    }
    if (!enpassant_ok or !legal_ep) pos.st.ep_square = sq_none_u8;

    // 5-6. Halfmove clock and fullmove number
    cur.skipWs();
    const rule50 = parseInt(&cur) orelse 0;
    cur.skipWs();
    var game_ply = parseInt(&cur) orelse 0;
    if (rule50 < 0 or rule50 > 32767) return setErr("Unsupported position. Rule50 counter out of range.");
    if (game_ply < 0 or game_ply > 100000) return setErr("Unsupported position. Game ply out of range.");
    pos.st.rule50 = rule50;
    game_ply = @max(2 * (game_ply - 1), 0) + @as(c_int, if (stm == color_black) 1 else 0);
    pos.game_ply = game_ply;

    pos.chess960 = is_chess960 != 0;
    setState(pos_ptr);

    if (attackersToExist(pos_ptr, kingSquare(pos, them), pos.by_type_bb[0], stm))
        return setErr("Unsupported position. King can be captured.");

    return null;
}

fn parseInt(cur: *FenCursor) ?c_int {
    var val: c_int = 0;
    var any = false;
    var neg = false;
    if (cur.i < cur.fen.len and (cur.fen[cur.i] == '-' or cur.fen[cur.i] == '+')) {
        neg = cur.fen[cur.i] == '-';
        cur.i += 1;
    }
    while (cur.i < cur.fen.len and cur.fen[cur.i] >= '0' and cur.fen[cur.i] <= '9') {
        val = val * 10 + @as(c_int, cur.fen[cur.i] - '0');
        cur.i += 1;
        any = true;
    }
    if (!any) return null;
    return if (neg) -val else val;
}

pub fn setState(pos_ptr: *const anyopaque) void {
    const psq: [*]const u64 = &zob_psq;
    const enpassant: [*]const u64 = &zob_enpassant;
    const castling: [*]const u64 = &zob_castling;
    const zob_side = zob_side_val;
    const no_pawns = zob_no_pawns;
    const pos: *const Position = @ptrCast(@alignCast(pos_ptr));
    const st = pos.st;
    st.key = 0;
    st.minor_piece_key = 0;
    st.non_pawn_key[0] = 0;
    st.non_pawn_key[1] = 0;
    st.pawn_key = no_pawns;
    st.non_pawn_material[0] = 0;
    st.non_pawn_material[1] = 0;

    const stm = pos.side_to_move;
    st.checkers_bb = attackersTo(pos_ptr, kingSquare(pos, stm), pos.by_type_bb[0]) &
        pos.by_color_bb[stm ^ 1];
    setCheckInfo(pos_ptr);

    var b = pos.by_type_bb[0];
    while (b != 0) {
        const s: u8 = @intCast(@ctz(b));
        b &= b - 1;
        const pc = pos.board[s];
        const idx = @as(usize, pc) * 64 + s;
        st.key ^= psq[idx];
        const pt = pc & 7;
        if (pt == pawn_pt) {
            st.pawn_key ^= psq[idx];
        } else {
            const col = pc >> 3;
            st.non_pawn_key[col] ^= psq[idx];
            if (pt != king_pt) {
                st.non_pawn_material[col] += piece_value_by_type[pt];
                if (pt <= bishop_pt) st.minor_piece_key ^= psq[idx];
            }
        }
    }

    if (st.ep_square != sq_none_u8) st.key ^= enpassant[fileOf(st.ep_square)];
    if (stm == color_black) st.key ^= zob_side;
    st.key ^= castling[@intCast(st.castling_rights)];
    st.material_key = computeMaterialKey(&pos.piece_count, 16);
}

pub fn setCheckInfo(pos_ptr: *const anyopaque) void {
    const pos: *const Position = @ptrCast(@alignCast(pos_ptr));
    updateSliderBlockers(pos_ptr, color_white);
    updateSliderBlockers(pos_ptr, color_black);

    const them = pos.side_to_move ^ 1;
    const ksq = kingSquare(pos, them);
    const all = pos.by_type_bb[0];
    pos.st.check_squares[pawn_pt] = pawnAttacks(them, ksq);
    pos.st.check_squares[knight_pt] = bitboard.attacks(knight_pt, ksq, 0);
    pos.st.check_squares[bishop_pt] = bitboard.attacks(bishop_pt, ksq, all);
    pos.st.check_squares[rook_pt] = bitboard.attacks(rook_pt, ksq, all);
    pos.st.check_squares[queen_pt] = pos.st.check_squares[bishop_pt] | pos.st.check_squares[rook_pt];
    pos.st.check_squares[king_pt] = 0;
}

pub fn legal(pos_ptr: *const anyopaque, m: u16) bool {
    const pos: *const Position = @ptrCast(@alignCast(pos_ptr));
    const us = pos.side_to_move;
    const them = us ^ 1;
    const from = moveFrom(m);
    const orig_to = moveTo(m);
    const all = pos.by_type_bb[0];

    if (moveTypeOf(m) == mt_castling) {
        const king_dest_rel: u8 = if (orig_to > from) 6 else 2; // SQ_G1 : SQ_C1
        const to = relativeSquare(us, king_dest_rel);
        const step: i8 = if (to > from) -1 else 1; // WEST : EAST
        var s: u8 = to;
        while (s != from) : (s = @intCast(@as(i16, s) + step)) {
            if (attackersToExist(pos_ptr, s, all, them)) return false;
        }
        if (!pos.chess960) return true;
        return (pos.st.blockers_for_king[us] & sqBb(orig_to)) == 0;
    }

    if (pieceTypeOn(pos, from) == king_pt) {
        return !attackersToExist(pos_ptr, orig_to, all ^ sqBb(from), them);
    }

    return (pos.st.blockers_for_king[us] & sqBb(from)) == 0 or
        (bitboard.line(from, orig_to) & (pos.by_color_bb[us] & pos.by_type_bb[king_pt])) != 0;
}

const piece_value_by_type = [8]c_int{ 0, 208, 781, 825, 1276, 2538, 0, 0 };

inline fn lsbBb(bb: u64) u64 {
    return bb & (~bb +% 1);
}

pub fn seeGe(pos_ptr: *const anyopaque, m: u16, threshold: c_int) bool {
    const pos: *const Position = @ptrCast(@alignCast(pos_ptr));
    if (moveTypeOf(m) != mt_normal) return 0 >= threshold;

    const from = moveFrom(m);
    const to = moveTo(m);

    var swap: c_int = piece_value_by_type[pos.board[to] & 7] - threshold;
    if (swap < 0) return false;
    swap = piece_value_by_type[pos.board[from] & 7] - swap;
    if (swap <= 0) return true;

    var occupied = pos.by_type_bb[0] ^ sqBb(from) ^ sqBb(to);
    var stm = pos.side_to_move;
    var attackers = attackersTo(pos_ptr, to, occupied);
    var res: c_int = 1;

    const bishops_queens = pos.by_type_bb[bishop_pt] | pos.by_type_bb[queen_pt];
    const rooks_queens = pos.by_type_bb[rook_pt] | pos.by_type_bb[queen_pt];

    while (true) {
        stm ^= 1;
        attackers &= occupied;

        var stm_attackers = attackers & pos.by_color_bb[stm];
        if (stm_attackers == 0) break;

        if ((pos.st.pinners[stm ^ 1] & occupied) != 0) {
            stm_attackers &= ~pos.st.blockers_for_king[stm];
            if (stm_attackers == 0) break;
        }

        res ^= 1;
        var bb = stm_attackers & pos.by_type_bb[pawn_pt];
        if (bb != 0) {
            swap = 208 - swap;
            if (swap < res) break;
            occupied ^= lsbBb(bb);
            attackers |= bitboard.attacks(bishop_pt, to, occupied) & bishops_queens;
        } else if (blk: {
            bb = stm_attackers & pos.by_type_bb[knight_pt];
            break :blk bb != 0;
        }) {
            swap = 781 - swap;
            if (swap < res) break;
            occupied ^= lsbBb(bb);
        } else if (blk: {
            bb = stm_attackers & pos.by_type_bb[bishop_pt];
            break :blk bb != 0;
        }) {
            swap = 825 - swap;
            if (swap < res) break;
            occupied ^= lsbBb(bb);
            attackers |= bitboard.attacks(bishop_pt, to, occupied) & bishops_queens;
        } else if (blk: {
            bb = stm_attackers & pos.by_type_bb[rook_pt];
            break :blk bb != 0;
        }) {
            swap = 1276 - swap;
            if (swap < res) break;
            occupied ^= lsbBb(bb);
            attackers |= bitboard.attacks(rook_pt, to, occupied) & rooks_queens;
        } else if (blk: {
            bb = stm_attackers & pos.by_type_bb[queen_pt];
            break :blk bb != 0;
        }) {
            swap = 2538 - swap;
            occupied ^= lsbBb(bb);
            attackers |= (bitboard.attacks(bishop_pt, to, occupied) & bishops_queens) |
                (bitboard.attacks(rook_pt, to, occupied) & rooks_queens);
        } else {
            // King capture: if the opponent still has attackers, reverse the result.
            return if ((attackers & ~pos.by_color_bb[stm]) != 0) (res ^ 1) != 0 else res != 0;
        }
    }

    return res != 0;
}

pub fn pseudoLegal(pos_ptr: *const anyopaque, m: u16) bool {
    const pos: *const Position = @ptrCast(@alignCast(pos_ptr));
    const us = pos.side_to_move;
    const them = us ^ 1;
    const from = moveFrom(m);
    const to = moveTo(m);
    const pc = pos.board[from];
    const all = pos.by_type_bb[0];

    // Slower but simpler path for non-NORMAL moves: membership in the generator.
    if (moveTypeOf(m) != mt_normal) {
        var buf: [256]u16 = undefined;
        const n = if (pos.st.checkers_bb != 0)
            movegen.generateEvasions(pos_ptr, &buf)
        else
            movegen.generateNonEvasions(pos_ptr, &buf);
        for (buf[0..n]) |mv| {
            if (mv == m) return true;
        }
        return false;
    }

    if (pc == 0 or colorOfPiece(pc) != us) return false;
    if ((pos.by_color_bb[us] & sqBb(to)) != 0) return false;

    if ((pc & 7) == pawn_pt) {
        if (((rank8_bb | rank1_bb) & sqBb(to)) != 0) return false;

        const push: i16 = if (us == color_white) 8 else -8;
        const is_capture = (pawnAttacks(us, from) & pos.by_color_bb[them] & sqBb(to)) != 0;
        const is_single_push = (@as(i16, from) + push == @as(i16, to)) and isEmpty(pos, to);
        const rel_rank = rankOf(from) ^ (us * 7);
        const is_double_push = (@as(i16, from) + 2 * push == @as(i16, to)) and rel_rank == 1 and
            isEmpty(pos, to) and isEmpty(pos, @intCast(@as(i16, to) - push));
        if (!(is_capture or is_single_push or is_double_push)) return false;
    } else if ((bitboard.attacks(pc & 7, from, all) & sqBb(to)) == 0) {
        return false;
    }

    const checkers = pos.st.checkers_bb;
    if (checkers != 0) {
        if ((pc & 7) != king_pt) {
            if ((checkers & (checkers -% 1)) != 0) return false; // double check
            const ksq = kingSquare(pos, us);
            const checker_sq: u8 = @intCast(@ctz(checkers));
            if ((bitboard.between(ksq, checker_sq) & sqBb(to)) == 0) return false;
        } else if (attackersToExist(pos_ptr, to, all ^ sqBb(from), them)) {
            return false;
        }
    }

    return true;
}

pub fn givesCheck(pos_ptr: *const anyopaque, m: u16) bool {
    const pos: *const Position = @ptrCast(@alignCast(pos_ptr));
    const stm = pos.side_to_move;
    const them = stm ^ 1;
    const from = moveFrom(m);
    const to = moveTo(m);
    const mt = moveTypeOf(m);
    const all = pos.by_type_bb[0];
    const their_king_bb = pos.by_color_bb[them] & pos.by_type_bb[king_pt];

    // Direct check.
    if ((pos.st.check_squares[pieceTypeOn(pos, from)] & sqBb(to)) != 0) return true;

    // Discovered check.
    if ((pos.st.blockers_for_king[them] & sqBb(from)) != 0) {
        return (bitboard.line(from, to) & their_king_bb) == 0 or mt == mt_castling;
    }

    switch (mt) {
        mt_normal => return false,
        mt_promotion => return (bitboard.attacks(movePromotionType(m), to, all ^ sqBb(from)) &
            their_king_bb) != 0,
        mt_en_passant => {
            const capsq = makeSquare(fileOf(to), rankOf(from));
            const b = (all ^ sqBb(from) ^ sqBb(capsq)) | sqBb(to);
            const ksq = kingSquare(pos, them);
            const our = pos.by_color_bb[stm];
            const our_qr = our & (pos.by_type_bb[queen_pt] | pos.by_type_bb[rook_pt]);
            const our_qb = our & (pos.by_type_bb[queen_pt] | pos.by_type_bb[bishop_pt]);
            return ((bitboard.attacks(rook_pt, ksq, b) & our_qr) |
                (bitboard.attacks(bishop_pt, ksq, b) & our_qb)) != 0;
        },
        else => { // castling
            const rto = relativeSquare(stm, if (to > from) 5 else 3); // SQ_F1 : SQ_D1
            return (pos.st.check_squares[rook_pt] & sqBb(rto)) != 0;
        },
    }
}

pub fn attackersToExist(pos_ptr: *const anyopaque, s: u8, occupied: u64, c: u8) bool {
    const pos: *const Position = @ptrCast(@alignCast(pos_ptr));
    const them = pos.by_color_bb[c];
    const rook_queen = them & (pos.by_type_bb[rook_pt] | pos.by_type_bb[queen_pt]);
    const bishop_queen = them & (pos.by_type_bb[bishop_pt] | pos.by_type_bb[queen_pt]);
    if ((bitboard.attacks(rook_pt, s, occupied) & rook_queen) != 0) return true;
    if ((bitboard.attacks(bishop_pt, s, occupied) & bishop_queen) != 0) return true;
    if ((pawnAttacks(c ^ 1, s) & (them & pos.by_type_bb[pawn_pt])) != 0) return true;
    if ((bitboard.attacks(knight_pt, s, 0) & (them & pos.by_type_bb[knight_pt])) != 0) return true;
    if ((bitboard.attacks(king_pt, s, 0) & (them & pos.by_type_bb[king_pt])) != 0) return true;
    return false;
}

pub fn buildEndgameFen(code_ptr: [*]const u8, code_len: usize, color: u8) ?[*:0]u8 {
    return buildEndgameFenAlloc(code_ptr[0..code_len], color) catch null;
}

pub fn formatFen(
    board_ptr: [*]const u8,
    side_to_move: u8,
    chess960: u8,
    castling_rights: u8,
    white_oo_rook_square: u8,
    white_ooo_rook_square: u8,
    black_oo_rook_square: u8,
    black_ooo_rook_square: u8,
    ep_square: u8,
    rule50: c_int,
    game_ply: c_int,
) ?[*:0]u8 {
    return formatFenAlloc(
        board_ptr[0..64],
        side_to_move,
        chess960 != 0,
        castling_rights,
        white_oo_rook_square,
        white_ooo_rook_square,
        black_oo_rook_square,
        black_ooo_rook_square,
        ep_square,
        rule50,
        game_ply,
    ) catch null;
}

pub fn computeMaterialKey(piece_counts_ptr: [*]const c_int, piece_count_len: usize) u64 {
    const piece_counts = piece_counts_ptr[0..piece_count_len];
    var key: u64 = 0;

    for (piece_counts, 0..) |count, piece_index| {
        if (!isMaterialPiece(@intCast(piece_index))) {
            continue;
        }

        var slot: usize = 0;
        while (slot < @as(usize, @intCast(count))) : (slot += 1) {
            key ^= zob_psq[@as(usize, @intCast(piece_index)) * 64 + 8 + slot];
        }
    }

    return key;
}

fn buildEndgameFenAlloc(code: []const u8, color: u8) ![*:0]u8 {
    std.debug.assert(code.len > 0 and code[0] == 'K');

    const second_king = std.mem.indexOfScalarPos(u8, code, 1, 'K') orelse unreachable;
    const versus = std.mem.indexOfScalar(u8, code, 'v') orelse unreachable;
    const strong_end = @min(second_king, versus);

    const weak_side = code[second_king..];
    const strong_side = code[0..strong_end];

    var builder = std.ArrayList(u8).empty;
    defer builder.deinit(std.heap.c_allocator);

    try builder.appendSlice(std.heap.c_allocator, "8/");
    try appendSide(&builder, weak_side, color == 0);
    try builder.append(std.heap.c_allocator, digitChar(@as(u8, @intCast(8 - weak_side.len))));
    try builder.appendSlice(std.heap.c_allocator, "/8/8/8/8/");
    try appendSide(&builder, strong_side, color == 1);
    try builder.append(std.heap.c_allocator, digitChar(@as(u8, @intCast(8 - strong_side.len))));
    try builder.appendSlice(std.heap.c_allocator, "/8 w - - 0 10");

    return try allocCString(builder.items);
}

fn formatFenAlloc(
    board: []const u8,
    side_to_move: u8,
    chess960: bool,
    castling_rights: u8,
    white_oo_rook_square: u8,
    white_ooo_rook_square: u8,
    black_oo_rook_square: u8,
    black_ooo_rook_square: u8,
    ep_square: u8,
    rule50: c_int,
    game_ply: c_int,
) ![*:0]u8 {
    var builder = std.ArrayList(u8).empty;
    defer builder.deinit(std.heap.c_allocator);

    var rank: i32 = 7;
    while (rank >= 0) : (rank -= 1) {
        var file: usize = 0;
        var empty_count: u8 = 0;

        while (file < 8) : (file += 1) {
            const rank_index: usize = @intCast(rank);
            const square_index = rank_index * 8 + file;
            const piece = board[square_index];
            if (piece == 0) {
                empty_count += 1;
                continue;
            }

            if (empty_count != 0) {
                try builder.append(std.heap.c_allocator, digitChar(empty_count));
                empty_count = 0;
            }

            try builder.append(std.heap.c_allocator, piece_to_char[@as(usize, piece)]);
        }

        if (empty_count != 0) {
            try builder.append(std.heap.c_allocator, digitChar(empty_count));
        }

        if (rank != 0) {
            try builder.append(std.heap.c_allocator, '/');
        }
    }

    try builder.appendSlice(std.heap.c_allocator, if (side_to_move == 0) " w " else " b ");

    var has_castling = false;
    if ((castling_rights & white_oo) != 0) {
        has_castling = true;
        try builder.append(std.heap.c_allocator, if (chess960) rookFileCharUpper(white_oo_rook_square) else 'K');
    }
    if ((castling_rights & white_ooo) != 0) {
        has_castling = true;
        try builder.append(std.heap.c_allocator, if (chess960) rookFileCharUpper(white_ooo_rook_square) else 'Q');
    }
    if ((castling_rights & black_oo) != 0) {
        has_castling = true;
        try builder.append(std.heap.c_allocator, if (chess960) rookFileCharLower(black_oo_rook_square) else 'k');
    }
    if ((castling_rights & black_ooo) != 0) {
        has_castling = true;
        try builder.append(std.heap.c_allocator, if (chess960) rookFileCharLower(black_ooo_rook_square) else 'q');
    }
    if (!has_castling) {
        try builder.append(std.heap.c_allocator, '-');
    }

    if (ep_square == sq_none) {
        try builder.appendSlice(std.heap.c_allocator, " - ");
    } else {
        try builder.append(std.heap.c_allocator, ' ');
        try appendSquare(&builder, ep_square);
        try builder.append(std.heap.c_allocator, ' ');
    }

    try appendInt(&builder, rule50);
    try builder.append(std.heap.c_allocator, ' ');
    const side_offset: c_int = if (side_to_move == black) 1 else 0;
    const fullmove = 1 + @divTrunc(game_ply - side_offset, 2);
    try appendInt(&builder, fullmove);

    return try allocCString(builder.items);
}

fn appendSide(builder: *std.ArrayList(u8), side: []const u8, lower: bool) !void {
    for (side) |byte| {
        try builder.append(std.heap.c_allocator, if (lower) std.ascii.toLower(byte) else byte);
    }
}

fn appendSquare(builder: *std.ArrayList(u8), square: u8) !void {
    try builder.append(std.heap.c_allocator, 'a' + fileOf(square));
    try builder.append(std.heap.c_allocator, '1' + rankOf(square));
}

fn appendInt(builder: *std.ArrayList(u8), value: c_int) !void {
    var buffer: [32]u8 = undefined;
    const text = try std.fmt.bufPrint(&buffer, "{d}", .{value});
    try builder.appendSlice(std.heap.c_allocator, text);
}

fn allocCString(value: []const u8) ![*:0]u8 {
    const result = try std.heap.c_allocator.allocSentinel(u8, value.len, 0);
    @memcpy(result[0..value.len], value);
    return result.ptr;
}

fn digitChar(value: u8) u8 {
    return '0' + value;
}

fn fileOf(square: u8) u8 {
    return square & 7;
}

fn rankOf(square: u8) u8 {
    return square >> 3;
}

fn rookFileCharUpper(square: u8) u8 {
    return 'A' + fileOf(square);
}

fn rookFileCharLower(square: u8) u8 {
    return 'a' + fileOf(square);
}

fn isMaterialPiece(piece: u8) bool {
    return switch (piece) {
        1...6, 9...14 => true,
        else => false,
    };
}
