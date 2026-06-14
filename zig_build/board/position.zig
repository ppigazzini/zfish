const std = @import("std");
const bitboard = @import("bitboard");
const movegen = @import("movegen");
const tt = @import("tt");
const movepick = @import("movepick");
const search = @import("search");

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
pub const SearchStack = extern struct {
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
pub const WorkerHistories = extern struct {
    main_history: [hist_color_nb * hist_uint16]i16, // ButterflyHistory [2][65536]
    low_ply_history: [hist_low_ply * hist_uint16]i16, // LowPlyHistory [5][65536]
    capture_history: [hist_piece_nb * hist_square_nb * hist_piece_type_nb]i16, // [16][64][8]
    continuation_history: [2 * 2 * hist_pieceto * hist_pieceto]i16, // [2][2] of [16][64]->[16][64]
    continuation_correction_history: [hist_pieceto * hist_pieceto]i16, // [16][64]->[16][64]
    tt_move_history: i16,
    shared_history: ?*anyopaque, // &SharedHistories (8-byte aligned; 6 bytes pad before)
};

// One CorrectionBundle (src/history.h): the four correction StatsEntry<int16>
// fields, one [2] page per correctionHistory index (indexed by color).
const CorrectionBundle = extern struct {
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
pub const SharedHistories = extern struct {
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
        e.* = @intCast(@divTrunc((v + 5) * 789, 1024));
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

extern fn zfish_search_conthist_delta(bonus: c_int, weight: c_int, positive_count: c_int, i: c_int) c_int;
extern fn zfish_search_quiet_low_ply_scale(bonus: c_int) c_int;
extern fn zfish_search_quiet_cont_scale(bonus: c_int) c_int;
extern fn zfish_search_quiet_pawn_scale(bonus: c_int) c_int;

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
    if (lowply_entry) |e| statsUpdate(e, zfish_search_quiet_low_ply_scale(bonus), 7183);
    updateContinuationHistories(ss_ptr, pc, to, zfish_search_quiet_cont_scale(bonus));
    statsUpdate(pawn_entry, zfish_search_quiet_pawn_scale(bonus), 8192);
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
            const delta = zfish_search_conthist_delta(bonus, b.w, positive_count, @intCast(b.i));
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
pub const PVMoves = extern struct {
    moves: [247]u16,
    length: usize,
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

extern fn zfish_search_cb_evaluate(worker: *anyopaque, pos: *const anyopaque) c_int;
extern fn zfish_search_cb_tt_context(worker: *anyopaque, out_table: *?*anyopaque, out_cc: *usize, out_gen: *u8) void;
extern fn zfish_search_cb_nodes(worker: *anyopaque) u64;
extern fn zfish_search_cb_update_seldepth(worker: *anyopaque, ply: c_int) void;

// One-shot fetch of the Worker make/unmake state: the NNUE accumulator stack and
// the node counter, both stable for the whole search. Cached in QCtx at entry so
// the inlined do_move/undo_move (below) touch no C++ — the accumulator push/pop
// are Zig-owned and pos.do_move routes to the Zig make-move directly.
extern fn zfish_search_cb_worker_make_state(worker: *anyopaque, out_acc_stack: *?*anyopaque, out_nodes: *?*u64) void;

// Zig-owned accumulator stack push/pop (defined in stockfish_zcu.o). push() bumps
// the stack and hands back pointers to the just-reserved DirtyPiece/DirtyThreats
// scratch that pos.do_move fills in; pop() drops the top entry.
const StackPushOutput = extern struct {
    dirty_piece: *anyopaque,
    dirty_threats: *anyopaque,
};
extern fn zfish_accumulator_stack_push(stack: *anyopaque) StackPushOutput;
extern fn zfish_accumulator_stack_pop(stack: *anyopaque) void;

const QCtx = struct {
    worker: *anyopaque,
    table: ?*anyopaque,
    cluster_count: usize,
    generation: u8,
    acc_stack: *anyopaque,
    nodes: *u64,
};

// Worker::do_move inlined: count the node, push a fresh accumulator slot, make the
// move (the Zig make-move records the dirty piece/threats into that slot), then set
// the Stack's current move and continuation-history pointer. Mirrors search.cpp
// do_move exactly; capture_stage is read pre-move, dirtyPiece.pc post-move.
inline fn doMoveAcc(ctx: *const QCtx, pos_ptr: *anyopaque, move: u16, st_ptr: *anyopaque, gives_check: u8, ss_ptr: *anyopaque) void {
    const pos: *Position = @ptrCast(@alignCast(pos_ptr));
    const ss: *SearchStack = @ptrCast(@alignCast(ss_ptr));
    const capture = captureStage(pos, move);
    ctx.nodes.* +%= 1;
    const out = zfish_accumulator_stack_push(ctx.acc_stack);
    doMove(pos_ptr, move, st_ptr, gives_check, out.dirty_piece, out.dirty_threats);
    const dp: *const DirtyPiece = @ptrCast(@alignCast(out.dirty_piece));
    ss.current_move = move;
    setContHist(ctx.worker, ss_ptr, @intFromBool(ss.in_check), @intFromBool(capture), dp.pc, moveTo(move));
}

// Worker::undo_move inlined: unmake the move, then drop the accumulator slot.
inline fn undoMoveAcc(ctx: *const QCtx, pos_ptr: *anyopaque, move: u16) void {
    undoMove(pos_ptr, move);
    zfish_accumulator_stack_pop(ctx.acc_stack);
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
        alpha = search.valueDraw(zfish_search_cb_nodes(ctx.worker));
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
        zfish_search_cb_update_seldepth(ctx.worker, ss.ply);
    }

    // Step 2. Immediate draw or max ply.
    if (isDraw(pos_ptr, ss.ply) or ss.ply >= q_max_ply) {
        if (ss.ply >= q_max_ply and !ss.in_check) return zfish_search_cb_evaluate(ctx.worker, pos_ptr);
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
                unadjusted_static_eval = zfish_search_cb_evaluate(ctx.worker, pos_ptr);
            ss.static_eval = search.toCorrectedStaticEval(unadjusted_static_eval, correction_value);
            best_value = ss.static_eval;
            if (qIsValid(tt_value) and !qIsDecisive(tt_value) and
                (tt_bound & (if (tt_value > best_value) q_bound_lower else q_bound_upper)) != 0)
                best_value = tt_value;
        } else {
            unadjusted_static_eval = zfish_search_cb_evaluate(ctx.worker, pos_ptr);
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

pub fn qsearchEntry(worker: *anyopaque, pos_ptr: *anyopaque, ss_ptr: *anyopaque, alpha: c_int, beta: c_int, pv_node: u8) c_int {
    var table: ?*anyopaque = null;
    var cc: usize = 0;
    var gen: u8 = 0;
    zfish_search_cb_tt_context(worker, &table, &cc, &gen);
    var acc_stack: ?*anyopaque = null;
    var nodes: ?*u64 = null;
    zfish_search_cb_worker_make_state(worker, &acc_stack, &nodes);
    const ctx = QCtx{ .worker = worker, .table = table, .cluster_count = cc, .generation = gen, .acc_stack = acc_stack.?, .nodes = nodes.? };
    return qsearchImpl(&ctx, pos_ptr, ss_ptr, alpha, beta, pv_node != 0);
}

// ======================= search() (ported to Zig, non-root) =======================
// Mirrors Search::Worker::search for PV/NonPV nodes (Root stays C++ in search.cpp,
// so rootMoves never crosses the boundary). Reuses the qsearch infrastructure
// (mirrors, TT, MovePicker, callbacks) plus do_null_move / pos_do_move (2-arg) /
// reduction / followPV / nmpMinPly callbacks.
extern fn zfish_search_cb_pos_do_move(pos: *anyopaque, move: u16, st: *anyopaque) void;
extern fn zfish_search_cb_pos_undo_move(pos: *anyopaque, move: u16) void;
extern fn zfish_search_cb_reduction(worker: *anyopaque, i: u8, d: c_int, mn: c_int, delta: c_int) c_int;
extern fn zfish_search_cb_check_time(worker: *anyopaque) void;
extern fn zfish_search_cb_in_last_iter_pv(worker: *anyopaque, ply_minus_1: c_int, move: u16) u8;
extern fn zfish_search_cb_get_nmp_min_ply(worker: *anyopaque) c_int;
extern fn zfish_search_cb_set_nmp_min_ply(worker: *anyopaque, v: c_int) void;
extern fn zfish_search_cb_root_depth(worker: *anyopaque) c_int;
extern fn zfish_search_cb_stop(worker: *anyopaque) u8;
extern fn zfish_search_cb_root_tt_move(worker: *anyopaque) u16;
extern fn zfish_search_cb_root_in_list(worker: *anyopaque, move: u16) u8;
extern fn zfish_search_cb_root_pvidx_nonzero(worker: *anyopaque) u8;
extern fn zfish_search_cb_root_on_iter(worker: *anyopaque, depth: c_int, move: u16, move_count: c_int) void;
extern fn zfish_search_cb_root_update(worker: *anyopaque, move: u16, value: c_int, nodes_delta: u64, move_count: c_int, alpha: c_int, beta: c_int, child_pv: [*]const u16, child_pv_len: usize) void;

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
        alpha = search.valueDraw(zfish_search_cb_nodes(ctx.worker));
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

    ss.follow_pv = root_node or (ss1.follow_pv and zfish_search_cb_in_last_iter_pv(ctx.worker, ss.ply - 1, ss1.current_move) != 0);

    zfish_search_cb_check_time(ctx.worker);

    if (pv_node) zfish_search_cb_update_seldepth(ctx.worker, ss.ply);

    if (!root_node) {
        // Step 2. Aborted search / immediate draw / max ply.
        if (zfish_search_cb_stop(ctx.worker) != 0 or isDraw(pos_ptr, ss.ply) or ss.ply >= q_max_ply) {
            if (ss.ply >= q_max_ply and !ss.in_check) return zfish_search_cb_evaluate(ctx.worker, pos_ptr);
            return search.valueDraw(zfish_search_cb_nodes(ctx.worker));
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
    const tt_move: u16 = if (root_node) zfish_search_cb_root_tt_move(ctx.worker) else if (tt_hit) probe.data.move16 else 0;
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
        if (!qIsValid(unadjusted_static_eval)) unadjusted_static_eval = zfish_search_cb_evaluate(ctx.worker, pos_ptr);
        ss.static_eval = search.toCorrectedStaticEval(unadjusted_static_eval, correction_value);
        eval = ss.static_eval;
        if (qIsValid(tt_value) and (tt_bound & (if (tt_value > eval) q_bound_lower else q_bound_upper)) != 0)
            eval = tt_value;
    } else {
        unadjusted_static_eval = zfish_search_cb_evaluate(ctx.worker, pos_ptr);
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
                updateQuietHistoriesWorker(ctx.worker, pos_ptr, ss_ptr, tt_move, @min(114 * depth - 73, 797));
            if (prev_sq != @as(c_int, sq_none) and ss1.move_count < 4 and !prior_capture)
                updateContinuationHistories(ss1, pos.board[@intCast(prev_sq)], @intCast(prev_sq), -2187);
        }
        if (pos.st.rule50 < 96) {
            if (depth >= 7 and tt_move != 0 and pseudoLegal(pos_ptr, tt_move) and legal(pos_ptr, tt_move) and !qIsDecisive(tt_value)) {
                zfish_search_cb_pos_do_move(pos_ptr, tt_move, @ptrCast(&st));
                const next_key = adjustKey50(pos);
                const probe_next = tt.probeTable(ctx.table, ctx.cluster_count, next_key, ctx.generation, q_depth_none);
                zfish_search_cb_pos_undo_move(pos_ptr, tt_move);
                const next_value: c_int = probe_next.data.value16;
                if (!qIsValid(next_value)) return tt_value;
                if ((tt_value >= beta) == (-next_value >= beta)) return tt_value;
            } else return tt_value;
        }
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
            excluded_move == 0 and pos.st.non_pawn_material[us] != 0 and ss.ply >= zfish_search_cb_get_nmp_min_ply(ctx.worker) and !qIsLoss(beta))
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
                if (zfish_search_cb_get_nmp_min_ply(ctx.worker) != 0 or depth < 16) return null_value;
                zfish_search_cb_set_nmp_min_ply(ctx.worker, search.nmpMinPly(ss.ply, depth, r));
                const v = searchImpl(ctx, pos_ptr, ss_ptr, beta - 1, beta, depth - r, false, false, false);
                zfish_search_cb_set_nmp_min_ply(ctx.worker, 0);
                if (v >= beta) return null_value;
            }
        }

        if (ss.static_eval >= beta) improving = true;

        // Step 10. Internal iterative reductions.
        if (!ss.follow_pv and !all_node and depth >= 6 and tt_move == 0 and prior_reduction <= 3) depth -= 1;

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
            const probcut_depth = depth - 4;
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
        if (root_node and zfish_search_cb_root_in_list(ctx.worker, move) == 0) continue;

        move_count += 1;
        ss.move_count = move_count;

        if (root_node and zfish_search_cb_nodes(ctx.worker) > 10_000_000)
            zfish_search_cb_root_on_iter(ctx.worker, depth, move, move_count);

        if (pv_node) ssAdd(ss, 1).pv = null;

        var extension: c_int = 0;
        const capture = captureStage(pos, move);
        const moved_piece = pos.board[moveFrom(move)];
        const to = moveTo(move);
        const gc = givesCheck(pos_ptr, move);

        var new_depth = depth - 1;
        const delta = beta - alpha;
        var r = zfish_search_cb_reduction(ctx.worker, @intFromBool(improving), depth, move_count, delta);
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
                const ply_gt_root = ss.ply > zfish_search_cb_root_depth(ctx.worker);
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

        const node_count: u64 = if (root_node) zfish_search_cb_nodes(ctx.worker) else 0;

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
            r = @max(@as(c_int, -10), r - 2016 + 150 * @as(c_int, @intFromBool(cut_node)));
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
        if (zfish_search_cb_stop(ctx.worker) != 0) return q_value_draw;

        if (root_node) {
            // (ss+1)->pv is only valid (non-null) when this move ran a PV search,
            // i.e. move_count == 1 or value > alpha; otherwise the C++ ignores it.
            const cpv: ?*PVMoves = if (move_count == 1 or value > alpha) @ptrCast(@alignCast(ssAdd(ss, 1).pv.?)) else null;
            var dummy: [1]u16 = undefined;
            const pv_ptr: [*]const u16 = if (cpv) |c| &c.moves else &dummy;
            const pv_len: usize = if (cpv) |c| c.length else 0;
            zfish_search_cb_root_update(ctx.worker, move, value, zfish_search_cb_nodes(ctx.worker) - node_count, move_count, alpha, beta, pv_ptr, pv_len);
        }

        const av = if (value < 0) -value else value;
        const inc: c_int = @intFromBool(value == best_value and ss.ply + 2 >= zfish_search_cb_root_depth(ctx.worker) and (@as(c_int, @intCast(zfish_search_cb_nodes(ctx.worker) & 14)) == 0) and !qIsWin(av + 1));
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
        updateAllStats(ctx.worker, pos_ptr, ss_ptr, best_move, prev_sq, &quiets_searched, n_quiets, &captures_searched, n_captures, depth, tt_move);
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

    if (excluded_move == 0 and !(root_node and zfish_search_cb_root_pvidx_nonzero(ctx.worker) != 0)) {
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
    zfish_search_cb_tt_context(worker, &table, &cc, &gen);
    var acc_stack: ?*anyopaque = null;
    var nodes: ?*u64 = null;
    zfish_search_cb_worker_make_state(worker, &acc_stack, &nodes);
    const ctx = QCtx{ .worker = worker, .table = table, .cluster_count = cc, .generation = gen, .acc_stack = acc_stack.?, .nodes = nodes.? };
    return searchImpl(&ctx, pos_ptr, ss_ptr, alpha, beta, depth, cut_node != 0, pv_node != 0, root_node != 0);
}

extern fn zfish_search_stat_bonus(depth: c_int, is_tt_move: u8, prev_stat_score: c_int) c_int;
extern fn zfish_search_stat_malus(depth: c_int) c_int;

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
) void {
    const w: *WorkerHistories = @ptrCast(@alignCast(worker_ptr));
    const pos: *const Position = @ptrCast(@alignCast(pos_ptr));
    const ss: *SearchStack = @ptrCast(@alignCast(ss_ptr));
    const ss_prev: *SearchStack = @ptrFromInt(@intFromPtr(ss) - @sizeOf(SearchStack));
    const capture_base: [*]i16 = &w.capture_history;

    const is_tt: u8 = if (best_move == tt_move) 1 else 0;
    const bonus = zfish_search_stat_bonus(depth, is_tt, ss_prev.stat_score);
    const malus = zfish_search_stat_malus(depth);

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
pub const StateInfo = extern struct {
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

// Memory mirror of the leading data members of upstream Position (src/position.h),
// up to `chess960`. The trailing NNUE scratch members (DirtyPiece/DirtyThreats)
// are intentionally omitted: this struct is only ever used through a pointer to
// the live C++ object, so leading-field offsets are all that must match.
pub const Position = extern struct {
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
};

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
const DirtyPiece = extern struct {
    pc: u8,
    from: u8,
    to: u8,
    remove_sq: u8,
    add_sq: u8,
    remove_pc: u8,
    add_pc: u8,
};
const DirtyThreats = extern struct {
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

    // Copy the "copied when making a move" StateInfo prefix: offsetof(key) == 64.
    @memcpy(@as([*]u8, @ptrCast(new_st))[0..64], @as([*]const u8, @ptrCast(pos.st))[0..64]);
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
