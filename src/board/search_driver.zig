// Search driver (M17.3q): the per-Worker history subsystem plus the full
// alpha-beta / quiescence search, iterative deepening, skill level, and the
// UCI-info emit callbacks -- the mutually-recursive search core extracted whole
// from position.zig. It drives a Worker (the WorkerLayout in graph_layout) over a
// Position, calling the board leaves (move_do / legality / repetition /
// state_setup / fen_parse) and the engine support modules (movepick / tt / nnue /
// evaluate / timeman / uci_* / threads). None of those import position, so this
// leaf never closes a module cycle; position.zig re-exports the public entry
// points (searchEntry / qsearchEntry / iterativeDeepening / workerStartSearching /
// the history updates / create-destroy-setPositionState glue) so the engine,
// thread, and main callers resolve through the position surface unchanged.

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
const shared_hist = @import("shared_histories");
const shared_histories_map = @import("shared_histories_map");
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
const worker_histories = @import("worker_histories");
const position_types = @import("position_types");
const search_types = @import("search_types");
const search_ctx = @import("search_ctx");
const fen = @import("fen");
const board_core = @import("board_core");
const legality = @import("legality");
const zobrist = @import("zobrist");
const repetition = @import("repetition");
const position_query = @import("position_query");
const state_setup = @import("state_setup");
const move_do = @import("move_do");
const shared_history = @import("shared_history");
const search_common = @import("search_common");
const workerHistories = search_common.workerHistories;
const captureStage = search_common.captureStage;
const moveIsOk = search_common.moveIsOk;
const statsUpdate = search_common.statsUpdate;
const captVal = search_common.captVal;
const captEntry = search_common.captEntry;
const history_mod = @import("history");
// History-update functions live in the history leaf (M17.3t); aliased for the
// search bodies and re-exported onward for position.zig's port surface.
pub const updateQuietHistoriesWorker = history_mod.updateQuietHistoriesWorker;
pub const setContHist = history_mod.setContHist;
pub const ageMainHistory = history_mod.ageMainHistory;
pub const fillLowPlyHistory = history_mod.fillLowPlyHistory;
pub const clearWorkerHistories = history_mod.clearWorkerHistories;
pub const updateQuietHistories = history_mod.updateQuietHistories;
pub const updateContinuationHistories = history_mod.updateContinuationHistories;
pub const updateAllStats = history_mod.updateAllStats;
pub const updateCorrectionHistory = history_mod.updateCorrectionHistory;

// Types.
const Position = position_types.Position;
const StateInfo = position_types.StateInfo;
const DirtyPiece = position_types.DirtyPiece;
const DirtyThreats = position_types.DirtyThreats;
const SearchStack = search_types.SearchStack;
const WorkerHistories = worker_histories.WorkerHistories;

// board_core primitives (M17.3f/g).
const pawn_pt = board_core.pawn_pt;
const knight_pt = board_core.knight_pt;
const bishop_pt = board_core.bishop_pt;
const rook_pt = board_core.rook_pt;
const queen_pt = board_core.queen_pt;
const king_pt = board_core.king_pt;
const color_white = board_core.color_white;
const color_black = board_core.color_black;
const file_a_bb = board_core.file_a_bb;
const file_h_bb = board_core.file_h_bb;
const rank1_bb = board_core.rank1_bb;
const rank8_bb = board_core.rank8_bb;
const mt_normal = board_core.mt_normal;
const mt_promotion = board_core.mt_promotion;
const mt_en_passant = board_core.mt_en_passant;
const mt_castling = board_core.mt_castling;
const piece_value_by_type = board_core.piece_value_by_type;
const sqBb = board_core.sqBb;
const lsbBb = board_core.lsbBb;
const moveFrom = board_core.moveFrom;
const moveTo = board_core.moveTo;
const moveTypeOf = board_core.moveTypeOf;
const movePromotionType = board_core.movePromotionType;
const relativeSquare = board_core.relativeSquare;
const makeSquare = board_core.makeSquare;
const pieceTypeOn = board_core.pieceTypeOn;
const pawnAttacks = board_core.pawnAttacks;
const kingSquare = board_core.kingSquare;
const fileOf = board_core.fileOf;
const rankOf = board_core.rankOf;
const colorOfPiece = board_core.colorOfPiece;
const isEmpty = board_core.isEmpty;

// zobrist index helpers (M17.3i).
const psqIdx = zobrist.psqIdx;
const h1 = zobrist.h1;
const h2 = zobrist.h2;

// worker_histories dimensions (M17.2p).
const hist_color_nb = worker_histories.hist_color_nb;
const hist_uint16 = worker_histories.hist_uint16;
const hist_low_ply = worker_histories.hist_low_ply;
const hist_piece_nb = worker_histories.hist_piece_nb;
const hist_square_nb = worker_histories.hist_square_nb;
const hist_piece_type_nb = worker_histories.hist_piece_type_nb;
const hist_pieceto = worker_histories.hist_pieceto;
const worker_shared_history_off = worker_histories.worker_shared_history_off;

// Board-op aliases -- the leaves position.zig re-exports, named here so the moved
// bodies stay verbatim.
const doNullMove = move_do.doNullMove;
const undoNullMove = move_do.undoNullMove;
const doMove = move_do.doMove;
const undoMove = move_do.undoMove;
const putPiece = move_do.putPiece;
const upcomingRepetition = repetition.upcomingRepetition;
const isDraw = repetition.isDraw;
const isRepetition = repetition.isRepetition;
const hasRepeated = repetition.hasRepeated;
const sideToMove = position_query.sideToMove;
const isChess960 = position_query.isChess960;
const gamePly = position_query.gamePly;
const hasCheckers = position_query.hasCheckers;
const wdlMaterial = position_query.wdlMaterial;
const fillSnapshot = position_query.fillSnapshot;
const accumulatorSnapshot = position_query.accumulatorSnapshot;
const setCastlingRight = state_setup.setCastlingRight;
const updateSliderBlockers = state_setup.updateSliderBlockers;
const setState = state_setup.setState;
const setCheckInfo = state_setup.setCheckInfo;
const computeMaterialKey = state_setup.computeMaterialKey;
const flipFen = fen.flipFen;
const formatFen = fen.formatFen;
const buildEndgameFen = fen.buildEndgameFen;
const attackersTo = legality.attackersTo;
const attackersToExist = legality.attackersToExist;
const legal = legality.legal;
const seeGe = legality.seeGe;
const pseudoLegal = legality.pseudoLegal;
const givesCheck = legality.givesCheck;

const sq_none: u8 = 64;
const sq_none_u8: u8 = 64;

// ======================================================================== //
// The search + history subsystem, moved verbatim from position.zig (M17.3q).  //
// ======================================================================== //
comptime {
    // graph_layout.WorkerLayout uses opaque byte regions for these position-module
    // sub-blocks; assert its sizes match the real structs so worker_off stays correct.
    std.debug.assert(graph_layout.worker_histories_bytes == @sizeOf(WorkerHistories));
    std.debug.assert(graph_layout.position_size == @sizeOf(Position));
    std.debug.assert(graph_layout.state_info_size == @sizeOf(StateInfo));
}

const CorrectionBundle = search_types.CorrectionBundle;

// Shared-history arena lives in the shared_history leaf (M17.3r); the accessors are
// aliased here so the search bodies stay verbatim, and the public management
// functions are re-exported onward so position.zig's port surface is unchanged.
pub const SharedHistories = shared_history.SharedHistories;
const sharedOf = shared_history.sharedOf;
const pawnEntryRow = shared_history.pawnEntryRow;
const corrBundle = shared_history.corrBundle;
pub const SharedHistoriesMap = shared_history.SharedHistoriesMap;
pub const clearSharedHistory = shared_history.clearSharedHistory;
pub const constructSharedHistories = shared_history.constructSharedHistories;
pub const deinitSharedHistories = shared_history.deinitSharedHistories;
pub const verifySharedHistories = shared_history.verifySharedHistories;

// update_quiet_histories addressed through the Worker + SharedHistories mirrors:
// the caller passes only the Worker and Position pointers and the move, and Zig
// resolves mainHistory[us][move], lowPlyHistory[ply][move], and the pawn entry
// itself (no per-call base pointers).

pub fn isShuffling(pos_ptr: *const Position, ss_ptr: *const SearchStack, move: u16) bool {
    const pos = pos_ptr;
    const ss = ss_ptr;
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
// predicates, and search-formula helpers directly. All history/correction
// tables are read from the Worker + SharedHistories mirrors.
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

pub const PVMoves = search_types.PVMoves;
pub const RootMove = search_types.RootMove;

// M17.3x: the search UCI-reporting family (info/bestmove/currmove lines + the
// MultiPV walk) lives in the search_emit leaf; the driver calls these emitters
// directly, so alias the driver-facing ones to keep call sites unqualified.
const search_emit = @import("search_emit");
const ssEmitNoMoves = search_emit.ssEmitNoMoves;
const ssEmitBestmove = search_emit.ssEmitBestmove;
const searchCbRootOnIter = search_emit.searchCbRootOnIter;
const ssEmitPv = search_emit.ssEmitPv;
const searchIdPv = search_emit.searchIdPv;
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

const SsCtx = search_ctx.SsCtx;

// Search-manager driver callbacks that touch only the Worker graph (via graph_layout)
// + the accumulator stack; the driver (workerStartSearching) calls them locally.
// Worker-graph accessors moved to the search_ctx leaf (M18.7) so the coming search_id
// leaf and this file share them without a cycle; aliased here to keep call sites.
const workerThreadsPool = search_ctx.workerThreadsPool;
const workerManager = search_ctx.workerManager;
const workerRootMove0 = search_ctx.workerRootMove0;
const workerTT = search_ctx.workerTT;

// Per-search reset: clear the worker's accumulator stack + last-iteration PV.
fn ssPrologue(wl: *graph_layout.WorkerLayout) void {
    nnue_acc.stackReset(@ptrCast(&wl.accumulator_stack));
    wl.last_iteration_pv.length = 0;
}

// Sum and reset each thread's worker bestMoveChanges (atomic u64), as a double.
fn searchIdCollectBmc(wl: *const graph_layout.WorkerLayout) f64 {
    const tp = wl.threads;
    const count = tp.numThreads();
    var tot: f64 = 0;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const wkr = tp.threadTyped(i).worker.?;
        const bmc = &wkr.best_move_changes;
        tot += @floatFromInt(bmc.*);
        bmc.* = 0;
    }
    return tot;
}

fn ssSetStop(wl: *const graph_layout.WorkerLayout) void {
    workerThreadsPool(wl).stop = 1;
}

// !threads.stop && (manager->ponder || limits.infinite).
fn ssShouldBusywait(wl: *const graph_layout.WorkerLayout) u8 {
    if (workerThreadsPool(wl).stop != 0) return 0;
    const ponder = workerManager(wl).?.ponder;
    const infinite = wl.limits.infinite;
    return if (ponder != 0 or infinite != 0) 1 else 0;
}

fn ssSetPrevScores(wl: *const graph_layout.WorkerLayout, best: *const graph_layout.WorkerLayout) void {
    const rmv = workerRootMove0(best);
    const sm = workerManager(wl).?;
    sm.best_previous_score = rmv.score;
    sm.best_previous_average_score = rmv.average_score;
}

// best->rootMoves[0].pv.size()==1 && extract_ponder_from_tt(worker->tt, worker->rootPos).
fn ssPvOneAndPonder(wl: *graph_layout.WorkerLayout, best: *const graph_layout.WorkerLayout) u8 {
    const pv = &workerRootMove0(best).pv;
    if (pv.length != 1) return 0;
    const tp = workerTT(wl);
    return extractPonderFromTt(@ptrCast(pv), tp.table, tp.cluster_count, tp.generation8, &wl.root_pos);
}

const searchCbTtContext = search_ctx.searchCbTtContext;

fn optInt(name: []const u8) c_int {
    return option_port.intByName(name);
}

// Per-search context flags read off the worker graph + the native OptionsModel.
fn ssContext(wl: *const graph_layout.WorkerLayout, out: *SsCtx) void {
    // root_moves is the {begin,end,cap} vector header; empty iff begin == end.
    const rm_begin = wl.root_moves[0];
    const rm_end = wl.root_moves[1];

    const limit_strength = optInt("UCI_LimitStrength") != 0;
    const uci_elo: c_int = if (limit_strength) optInt("UCI_Elo") else 0;
    const skill_level = optInt("Skill Level");
    const skill_enabled = uci_elo != 0 or skill_level < 20;

    out.is_mainthread = @intFromBool(wl.thread_idx == 0);
    out.root_moves_empty = @intFromBool(rm_begin == rm_end);
    out.npmsec = @intFromBool(wl.limits.npmsec != 0);
    out.limits_depth = wl.limits.depth;
    out.skill_enabled = @intFromBool(skill_enabled);
}

// Per-search TimeManagement::init + TT::new_search (main thread). Builds the timeman
// input from the worker's limits/rootPos + the manager's tm, reads nodestime/Move
// Overhead/Ponder from the native model, writes the outputs back, and bumps the TT
// generation. Relocated from main.zig (M16.7).
fn ssTmInit(wl: *graph_layout.WorkerLayout) void {
    const lim = &wl.limits;
    const smgr = wl.manager.?;
    const tm = &smgr.tm;
    const root_pos = &wl.root_pos;

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

    const gen = &wl.tt.generation8;
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
fn searchIdState(wl: *graph_layout.WorkerLayout, out: *ZfishIdState) void {
    const thread_idx = wl.thread_idx;
    const is_main = thread_idx == 0;
    const tp = wl.threads;

    // root_moves is the {begin,end,cap} vector header.
    const rm_begin = wl.root_moves[0];
    const rm_end = wl.root_moves[1];

    out.root_pos = &wl.root_pos;
    out.root_moves = @ptrFromInt(rm_begin);
    out.pv_idx = &wl.pv_idx;
    out.pv_last = &wl.pv_last;
    out.sel_depth = &wl.sel_depth;
    out.root_depth = &wl.root_depth;
    out.root_delta = &wl.root_delta;
    out.optimism = &wl.optimism;
    out.nodes = &wl.nodes;
    out.stop = &tp.stop;
    out.increase_depth = &tp.increase_depth;
    // wl.last_iteration_pv and ZfishIdState's field are now the one canonical
    // PVMoves (M18.2 de-mirror), so this is a plain mut->const coercion, no cast.
    out.last_iter_pv = &wl.last_iteration_pv;
    out.root_moves_count = (rm_end - rm_begin) / graph_layout.root_move_size;
    out.thread_idx = thread_idx;
    out.threads_size = tp.numThreads();
    out.multipv_option = @intCast(@max(optInt("MultiPV"), 0));
    out.limits_depth = wl.limits.depth;
    out.limits_mate = wl.limits.mate;
    out.use_time_management = @intFromBool(wl.limits.time[0] != 0 or wl.limits.time[1] != 0);
    out.is_main = @intFromBool(is_main);

    const sl = skillLevel();
    out.skill_level = sl;
    out.skill_enabled = @intFromBool(sl < 20.0);

    if (is_main) {
        const smgr = wl.manager.?;
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
        // pointer as a harmless valid placeholder (they are otherwise null/unused).
        out.stop_on_ponderhit = @ptrCast(wl);
        out.ponder = @ptrCast(wl);
        out.iter_value = @ptrCast(@alignCast(wl));
        out.previous_time_reduction = @ptrCast(@alignCast(wl));
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
fn ssThreadsStart(wl: *const graph_layout.WorkerLayout) void {
    native_thread.startPoolSiblings(wl.threads);
}
fn ssWaitFinished(wl: *const graph_layout.WorkerLayout) void {
    native_thread.waitPoolSiblings(wl.threads);
}

// Worker of the vote-winning thread (Lazy-SMP best-thread selection via the leaf
// thread_vote model). Relocated from main.zig (M16.7).
fn ssGetBestThread(wl: *const graph_layout.WorkerLayout) ?*graph_layout.WorkerLayout {
    const pool = wl.threads;
    return thread_vote.bestThreadWorker(pool);
}

// nodestime available-nodes advance (tm.advance_nodes_time). Relocated from main.zig (M16.7).
fn ssNpmsecAdvance(wl: *const graph_layout.WorkerLayout) void {
    const avail = &wl.manager.?.tm.available_nodes;
    const us: usize = sideToMove(&wl.root_pos);
    const inc = wl.limits.inc[us];
    const nodes: i64 = @intCast(graph_layout.poolNodesSearched(wl.threads));
    avail.* = @max(@as(i64, 0), avail.* - (nodes - inc));
}

// Worker::start_searching control flow. Zig owns every branch and the sequencing;
// the leaf helpers run the individual time-management, thread-pool, skill, and
// UCI-output operations.
pub fn workerStartSearching(worker: ?*anyopaque) void {
    const wl: *graph_layout.WorkerLayout = @ptrCast(@alignCast(worker.?));
    ssPrologue(wl);

    var ctx: SsCtx = undefined;
    ssContext(wl, &ctx);

    if (ctx.is_mainthread == 0) {
        _ = iterativeDeepening(worker.?);
        return;
    }

    ssTmInit(wl);

    if (ctx.root_moves_empty != 0) {
        ssEmitNoMoves(wl);
        return;
    }

    ssThreadsStart(wl);
    var uci_pv_sent = iterativeDeepening(worker.?) != 0;

    while (ssShouldBusywait(wl) != 0) {}

    ssSetStop(wl);
    ssWaitFinished(wl);

    if (ctx.npmsec != 0) ssNpmsecAdvance(wl);

    var best: ?*graph_layout.WorkerLayout = wl;
    if (ctx.limits_depth == 0 and ctx.skill_enabled == 0)
        best = ssGetBestThread(wl);

    ssSetPrevScores(wl, best.?);

    if (ssPvOneAndPonder(wl, best.?) != 0)
        uci_pv_sent = false;

    if (!uci_pv_sent or best != wl)
        ssEmitPv(wl, best);

    ssEmitBestmove(wl, best);
}

// One-shot fetch of the Worker state the inlined search needs, all stable for the
// whole search: the NNUE accumulator stack, the node counter, the (numa-resolved)
// Network, the accumulator-refresh cache, the optimism[2] array, and the three
// scalar Worker fields the search reads/writes directly — nmpMinPly, selDepth, and
// rootDepth. Cached in QCtx at entry; do_move/undo_move/evaluate and these scalar
// accesses are all Zig-owned (the accumulator push/pop, pos.do_move, and the network
// forward pass + eval scaling).
// Once-per-search snapshot of the Worker's live member pointers + shared stop flag,
// and -- on the main thread -- the SearchManager/TimeManagement/LimitsType time inputs.
// Relocated from main.zig (M16.7): graph_layout offset reads + the native FT pointer
// (the network handle is never dereferenced -- weights serve from native storage).
fn searchCbWorkerState(wl: *graph_layout.WorkerLayout, out_acc_stack: *?*anyopaque, out_nodes: *?*u64, out_cache: *?*anyopaque, out_optimism: *?*const [2]c_int, out_nmp_min_ply: *?*c_int, out_sel_depth: *?*c_int, out_root_depth: *?*c_int, out_reductions: *?[*]const c_int, out_root_delta: *?*const c_int, out_last_iter_pv: *?*const PVMoves, out_stop: *?*const u8, out_pv_idx: *?*const usize, out_root_moves: *?*anyopaque, out_pv_last: *?*const usize, out_best_move_changes: *?*u64, out_time: *SearchTimeState) void {
    const stop = &wl.threads.stop;

    out_acc_stack.* = &wl.accumulator_stack;
    out_nodes.* = &wl.nodes;
    out_cache.* = &wl.refresh_table;
    out_optimism.* = &wl.optimism;
    out_nmp_min_ply.* = &wl.nmp_min_ply;
    out_sel_depth.* = &wl.sel_depth;
    out_root_depth.* = &wl.root_depth;
    out_reductions.* = &wl.reductions;
    out_root_delta.* = &wl.root_delta;
    // One canonical PVMoves now (M18.2 de-mirror) -- plain mut->const, no cast.
    out_last_iter_pv.* = &wl.last_iteration_pv;
    out_stop.* = stop;
    out_pv_idx.* = &wl.pv_idx;
    // root_moves[0] is the vector's begin pointer (the first element's address).
    out_root_moves.* = @ptrFromInt(wl.root_moves[0]);
    out_pv_last.* = &wl.pv_last;
    out_best_move_changes.* = &wl.best_move_changes;

    if (wl.thread_idx == 0) {
        const smgr = wl.manager.?;
        out_time.calls_cnt = &smgr.calls_cnt;
        out_time.stop_write = stop;
        out_time.ponder = &smgr.ponder;
        out_time.stop_on_ponderhit = &smgr.stop_on_ponderhit;
        out_time.tm_start_time = smgr.tm.start_time;
        out_time.tm_maximum_time = smgr.tm.maximum_time;
        out_time.lim_nodes = wl.limits.nodes;
        out_time.lim_movetime = wl.limits.movetime;
        out_time.tm_use_nodes_time = smgr.tm.use_nodes_time;
        out_time.use_time_management = @intFromBool(wl.limits.time[0] != 0 or wl.limits.time[1] != 0);
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
const SearchTimeState = search_ctx.SearchTimeState;

// iterative_deepening state, snapshotted once at entry (skill-off path only). Live
// fields are pointers into Worker/SearchManager/ThreadPool; the rest are values
// read once.
const ZfishIdState = search_ctx.ZfishIdState;

const QCtx = search_ctx.QCtx;

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
inline fn evaluateAcc(ctx: *const QCtx, pos_ptr: *const Position) c_int {
    const pos = pos_ptr;
    const out = network_port.evaluate(pos_ptr, ctx.acc_stack, ctx.cache);
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
inline fn doMoveAcc(ctx: *const QCtx, pos_ptr: *Position, move: u16, st_ptr: *StateInfo, gives_check: u8, ss_ptr: *SearchStack) void {
    const pos = pos_ptr;
    const ss = ss_ptr;
    const capture = captureStage(pos, move);
    ctx.nodes.* +%= 1;
    const out = nnue_acc.stackPush(@ptrCast(ctx.acc_stack));
    doMove(pos_ptr, move, st_ptr, gives_check, out.dirty_piece, out.dirty_threats);
    const dp: *const DirtyPiece = out.dirty_piece;
    ss.current_move = move;
    setContHist(ctx.worker, ss_ptr, @intFromBool(ss.in_check), @intFromBool(capture), dp.pc, moveTo(move));
}

// Worker::undo_move inlined: unmake the move, then drop the accumulator slot.
inline fn undoMoveAcc(ctx: *const QCtx, pos_ptr: *Position, move: u16) void {
    undoMove(pos_ptr, move);
    nnue_acc.stackPop(@ptrCast(ctx.acc_stack));
}

// Position-level verification make/unmake used by the qsearch TT-move cutoff.
// Mirrors Position::do_move(Move, StateInfo&): gives_check is computed here, a
// fresh DirtyThreats list and a throwaway DirtyPiece are passed as scratch (no
// accumulator slot is pushed, so the dirty state doMove writes is never
// consumed). undo is the plain Position-level unmake.
inline fn verifyDoMove(pos_ptr: *Position, move: u16, st_ptr: *StateInfo) void {
    var dp: DirtyPiece = undefined;
    var dts: DirtyThreats = undefined;
    dts.list_size = 0;
    doMove(pos_ptr, move, st_ptr, @intFromBool(givesCheck(pos_ptr, move)), &dp, &dts);
}

inline fn verifyUndoMove(pos_ptr: *Position, move: u16) void {
    undoMove(pos_ptr, move);
}

// Is `move` in the legal move list of the current position?
fn legalContains(pos_ptr: *const Position, move: u16) bool {
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
// cluster count, generation) is handed over by the caller.
pub fn extractPonderFromTt(pv_ptr: *anyopaque, table: ?*anyopaque, cluster_count: usize, generation: u8, pos_ptr: *Position) u8 {
    const pv: *PVMoves = @ptrCast(@alignCast(pv_ptr));
    const move = pv.moves[0];
    var st: StateInfo = undefined;
    verifyDoMove(pos_ptr, move, &st);
    if (!isDraw(pos_ptr, 1)) {
        const pos = pos_ptr;
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

fn qsearchImpl(ctx: *const QCtx, pos_ptr: *Position, ss_ptr: *SearchStack, alpha_in: c_int, beta: c_int, pv_node: bool) c_int {
    const w: *WorkerHistories = workerHistories(ctx.worker);
    const pos = pos_ptr;
    const ss = ss_ptr;
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
        doMoveAcc(ctx, pos_ptr, move, &st, @intFromBool(gc), ss_ptr);
        const value = -qsearchImpl(ctx, pos_ptr, ss_next, -beta, -alpha, pv_node);
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
fn buildCtx(worker: *graph_layout.WorkerLayout, table: ?*anyopaque, cc: usize, gen: u8) QCtx {
    var acc_stack: ?*anyopaque = null;
    var nodes: ?*u64 = null;
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
    searchCbWorkerState(worker, &acc_stack, &nodes, &cache, &optimism, &nmp_min_ply, &sel_depth, &root_depth, &reductions, &root_delta, &last_iter_pv, &stop, &pv_idx, &root_moves, &pv_last, &best_move_changes, &time_state);
    return .{
        .worker = worker,
        .table = table,
        .cluster_count = cc,
        .generation = gen,
        .acc_stack = acc_stack.?,
        .nodes = nodes.?,
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
    // Single erasure boundary: the hook signature is *anyopaque; the whole search
    // recursion below runs on typed *WorkerLayout / *Position / *SearchStack.
    const wl: *graph_layout.WorkerLayout = @ptrCast(@alignCast(worker));
    var table: ?*anyopaque = null;
    var cc: usize = 0;
    var gen: u8 = 0;
    searchCbTtContext(wl, &table, &cc, &gen);
    const ctx = buildCtx(wl, table, cc, gen);
    const pos: *Position = @ptrCast(@alignCast(pos_ptr));
    const ss: *SearchStack = @ptrCast(@alignCast(ss_ptr));
    return qsearchImpl(&ctx, pos, ss, alpha, beta, pv_node != 0);
}

// ======================= search() (ported to Zig) =======================
// Mirrors Search::Worker::search for Root/PV/NonPV nodes (node type selected by the
// root_node/pv_node/cut_node params). Reuses the qsearch infrastructure
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

fn searchImpl(ctx: *const QCtx, pos_ptr: *Position, ss_ptr: *SearchStack, alpha_in: c_int, beta_in: c_int, depth_in: c_int, cut_node: bool, pv_node: bool, root_node: bool) c_int {
    const all_node = !(pv_node or cut_node);

    // Dive into qsearch at depth 0.
    if (depth_in <= 0) return qsearchImpl(ctx, pos_ptr, ss_ptr, alpha_in, beta_in, pv_node);

    const w: *WorkerHistories = workerHistories(ctx.worker);
    const pos = pos_ptr;
    const ss = ss_ptr;
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
                verifyDoMove(pos_ptr, tt_move, &st);
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
            doNullMove(pos_ptr, &st);
            ss.current_move = 65;
            setContHist(ctx.worker, ss_ptr, 0, 0, 0, 0);
            const null_value = -searchImpl(ctx, pos_ptr, ssAdd(ss, 1), -beta, -beta + 1, depth - r, false, false, false);
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
                doMoveAcc(ctx, pos_ptr, move, &st, @intFromBool(givesCheck(pos_ptr, move)), ss_ptr);
                var value = -qsearchImpl(ctx, pos_ptr, ssAdd(ss, 1), -probcut_beta, -probcut_beta + 1, false);
                if (value >= probcut_beta and probcut_depth > 0)
                    value = -searchImpl(ctx, pos_ptr, ssAdd(ss, 1), -probcut_beta, -probcut_beta + 1, probcut_depth, !cut_node, false, false);
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
        ss1.continuation_history,          ssSub(ss, 2).continuation_history,
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
        doMoveAcc(ctx, pos_ptr, move, &st, @intFromBool(gc), ss_ptr);
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
            value = -searchImpl(ctx, pos_ptr, ssAdd(ss, 1), -(alpha + 1), -alpha, d, true, false, false);
            ss.reduction = 0;
            if (value > alpha) {
                const do_deeper = d < new_depth and value > best_value + 52;
                const do_shallower = value < best_value + 9;
                new_depth += @as(c_int, @intFromBool(do_deeper)) - @as(c_int, @intFromBool(do_shallower));
                if (new_depth > d)
                    value = -searchImpl(ctx, pos_ptr, ssAdd(ss, 1), -(alpha + 1), -alpha, new_depth, !cut_node, false, false);
                updateContinuationHistories(ss, moved_piece, to, 1415);
            }
        } else if (!pv_node or move_count > 1) {
            if (tt_move == 0) r += 1085;
            value = -searchImpl(ctx, pos_ptr, ssAdd(ss, 1), -(alpha + 1), -alpha, new_depth - @as(c_int, @intFromBool(r > 5039)) - @as(c_int, @intFromBool(r > 5223 and new_depth > 2)), !cut_node, false, false);
        }

        if (pv_node and (move_count == 1 or value > alpha)) {
            ssAdd(ss, 1).pv = @ptrCast(&pv);
            pvClear(&pv);
            if (move == tt_move and ((qIsValid(tt_value) and qIsDecisive(tt_value) and tt_depth > 0) or tt_depth > 1))
                new_depth = @max(new_depth, 1);
            value = -searchImpl(ctx, pos_ptr, ssAdd(ss, 1), -beta, -alpha, new_depth, false, true, false);
        }

        // Step 19. Undo move.
        undoMoveAcc(ctx, pos_ptr, move);

        // Step 20. Check for a new best move.
        if (searchStopped(ctx)) return q_value_draw;

        if (root_node) {
            // (ss+1)->pv is only valid (non-null) when this move ran a PV search,
            // i.e. move_count == 1 or value > alpha; otherwise it is ignored.
            const cpv: ?*const PVMoves = if (move_count == 1 or value > alpha) @ptrCast(@alignCast(ssAdd(ss, 1).pv.?)) else null;
            rootUpdate(ctx, move, value, ctx.nodes.* - node_count, move_count, alpha, beta, cpv);
        }

        const av = if (value < 0) -value else value;
        const inc: c_int = @intFromBool(value == best_value and ss.ply + 2 >= ctx.root_depth.* and (@as(c_int, @intCast(ctx.nodes.* & 14)) == 0) and !qIsWin(av + 1));
        if (value + inc > best_value) {
            best_value = value;
            if (value + inc > alpha) {
                best_move = move;
                // (ss+1)->pv is only set (1913) when this move ran a PV re-search;
                // if a rare best-move update fires without one it stays null, and
                // pvUpdate takes the child PV as optional (null -> PV is just the
                // move). Force-unwrapping it here was a latent null-deref (silent
                // under ReleaseFast, panics under ReleaseSafe/Debug).
                if (pv_node and !root_node) {
                    const child_pv: ?*PVMoves = if (ssAdd(ss, 1).pv) |cpv| @ptrCast(@alignCast(cpv)) else null;
                    pvUpdate(@ptrCast(@alignCast(ss.pv.?)), move, child_pv);
                }
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

// captVal / captEntry live in the search_common leaf (M17.3s).

pub fn searchEntry(worker: *anyopaque, pos_ptr: *anyopaque, ss_ptr: *anyopaque, alpha: c_int, beta: c_int, depth: c_int, cut_node: u8, pv_node: u8, root_node: u8) c_int {
    // Single erasure boundary: the hook signature is *anyopaque; the whole search
    // recursion below runs on typed *WorkerLayout / *Position / *SearchStack.
    const wl: *graph_layout.WorkerLayout = @ptrCast(@alignCast(worker));
    var table: ?*anyopaque = null;
    var cc: usize = 0;
    var gen: u8 = 0;
    searchCbTtContext(wl, &table, &cc, &gen);
    const ctx = buildCtx(wl, table, cc, gen);
    const pos: *Position = @ptrCast(@alignCast(pos_ptr));
    const ss: *SearchStack = @ptrCast(@alignCast(ss_ptr));
    return searchImpl(&ctx, pos, ss, alpha, beta, depth, cut_node != 0, pv_node != 0, root_node != 0);
}

// ==================== iterative_deepening() (ported to Zig) ====================
// The UCI pv() sink and the cross-thread bestMoveChanges collection (sum + reset,
// returned as a double) keep multi-thread correct. This handles the skill-off path
// only, so no skill/RNG logic is needed here.

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
    // Single erasure boundary: the hook signature is *anyopaque; the whole loop
    // below drives the typed *WorkerLayout graph.
    const wl: *graph_layout.WorkerLayout = @ptrCast(@alignCast(worker));
    var id: ZfishIdState = undefined;
    searchIdState(wl, &id);
    const main_thread = id.is_main != 0;

    var table: ?*anyopaque = null;
    var cc: usize = 0;
    var gen: u8 = 0;
    searchCbTtContext(wl, &table, &cc, &gen);
    const ctx = buildCtx(wl, table, cc, gen);

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
            setContHist(wl, &stack[k], 0, 0, 0, 0); // sentinel (NO_PIECE)
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

    fillLowPlyHistory(wl);
    ageMainHistory(wl);

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
                    searchIdPv(wl, id.root_depth.*);

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
                searchIdPv(wl, id.root_depth.*);
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

        tot_best_move_changes += searchIdCollectBmc(wl);

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

// Compute the three quiet-history entries for `move` from the table bases and
// apply the shared quiet-history update. mainHistory is [2][65536], lowPlyHistory
// [5][65536], pawn_row is one fixed [16][64] page.
// update_all_stats (search.cpp): credit the best move and debit the searched-but-
// rejected quiets/captures. The caller passes only the Worker, Position, and
// Stack pointers and the two move lists (ptr+len); Zig resolves captureHistory
// from the Worker mirror and the quiet entries via updateQuietHistoriesWorker,
// and owns all bonus/malus scaling, the running malus decay, and the gravity.
