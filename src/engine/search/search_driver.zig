// Drive the search: the per-Worker history subsystem plus the full
// alpha-beta / quiescence search, iterative deepening, skill level, and the
// UCI-info emit callbacks -- the mutually-recursive search core. Drive a
// Worker (the WorkerLayout in worker_layout) over a Position, calling the board
// leaves (move_do / legality / repetition / state_setup / fen_parse) and the
// engine support modules (movepick / tt / nnue / evaluate / timeman / uci_* /
// threads). position.zig re-exports the public entry points (searchEntry /
// qsearchEntry / iterativeDeepening / workerStartSearching / the history updates /
// create-destroy-setPositionState glue) so the engine, thread, and main callers
// resolve through the position surface unchanged.

const std = @import("std");
const worker_layout = @import("worker_layout");
const tt = @import("tt");
const movepick = @import("movepick");
const search = @import("search");
const worker_histories = @import("worker_histories");
const position_types = @import("position_types");
const search_types = @import("search_types");
const search_ctx = @import("search_ctx");
const search_id = @import("search_id");
const search_acc = @import("search_acc");
const search_setup = @import("search_setup");
const board_core = @import("board_core");
const legality = @import("legality");
const zobrist = @import("zobrist");
const repetition = @import("repetition");
const state_setup = @import("state_setup");
const move_do = @import("move_do");
const shared_history = @import("shared_history");
const search_common = @import("search_common");
const captVal = search_common.captVal;
const captEntry = search_common.captEntry;
const history_mod = @import("history");
// History-update functions live in the history leaf; aliased for the
// search bodies and re-exported onward for position.zig's surface.
pub const updateQuietHistoriesWorker = history_mod.updateQuietHistoriesWorker;
pub const setContHist = history_mod.setContHist;
pub const ageMainHistory = history_mod.ageMainHistory;
pub const fillLowPlyHistory = history_mod.fillLowPlyHistory;
pub const clearWorkerHistories = history_mod.clearWorkerHistories;
pub const updateQuietHistories = history_mod.updateQuietHistories;
pub const updateContinuationHistories = history_mod.updateContinuationHistories;
pub const updateAllStats = history_mod.updateAllStats;
pub const updateCorrectionHistory = history_mod.updateCorrectionHistory;

// Alias the types.
const Position = position_types.Position;
const StateInfo = position_types.StateInfo;
const DirtyPiece = position_types.DirtyPiece;
const DirtyThreats = position_types.DirtyThreats;
const WorkerHistories = worker_histories.WorkerHistories;

// Alias the board_core primitives.

// Alias the zobrist index helpers.

// Alias the worker_histories dimensions.

// Alias the board ops -- the leaves position.zig re-exports, named here.
const isDraw = repetition.isDraw;
const legal = legality.legal;

// ======================================================================== //
// The search + history subsystem.  //
// ======================================================================== //
comptime {
    // Assert the opaque byte regions worker_layout.WorkerLayout uses for these
    // position-module sub-blocks match the real struct sizes so worker_off stays correct.
    std.debug.assert(worker_layout.worker_histories_bytes == @sizeOf(WorkerHistories));
    std.debug.assert(worker_layout.position_size == @sizeOf(Position));
    std.debug.assert(worker_layout.state_info_size == @sizeOf(StateInfo));
}

// Alias the shared-history accessors here -- the arena lives in the shared_history
// leaf -- and re-export the public management functions onward so
// position.zig's surface is unchanged.
pub const SharedHistories = shared_history.SharedHistories;
pub const SharedHistoriesMap = shared_history.SharedHistoriesMap;
pub const clearSharedHistory = shared_history.clearSharedHistory;
pub const constructSharedHistories = shared_history.constructSharedHistories;
pub const deinitSharedHistories = shared_history.deinitSharedHistories;
pub const verifySharedHistories = shared_history.verifySharedHistories;

// Address update_quiet_histories through the Worker + SharedHistories mirrors:
// the caller passes only the Worker and Position pointers and the move, and Zig
// resolves mainHistory[us][move], lowPlyHistory[ply][move], and the pawn entry
// itself (no per-call base pointers).

// ======================= qsearch() =======================
// Call TT (tt.probeTable/entrySave), MovePicker (movepick.nextMove), position
// predicates, and search-formula helpers directly. Read all history/correction
// tables from the Worker + SharedHistories mirrors.
// Alias the search value model (score sentinels, mate arithmetic, bound/depth enums,
// predicates) back with the short names the two search bodies already use; it lives
// in the search_values leaf now.
const sv = @import("search_values.zig");
const q_depth_none = sv.depth_none;

pub const PVMoves = search_types.PVMoves;
pub const RootMove = search_types.RootMove;

// Alias the driver-facing emitters to keep call sites unqualified: the search
// UCI-reporting family (info/bestmove/currmove lines + the MultiPV walk) lives in the
// search_emit leaf, and the driver calls these emitters directly.
const search_emit = @import("search_emit");
const ssEmitNoMoves = search_emit.ssEmitNoMoves;
const ssEmitBestmove = search_emit.ssEmitBestmove;
const ssEmitPv = search_emit.ssEmitPv;

const SsCtx = search_ctx.SsCtx;

// Provide the search-manager driver callbacks that touch only the Worker graph (via worker_layout)
// + the accumulator stack; the driver (workerStartSearching) calls them locally.
// Alias the Worker-graph accessors here to keep call sites; they live in the search_ctx leaf.
const workerRootMove0 = search_ctx.workerRootMove0;
const workerTT = search_ctx.workerTT;

// Reset per search: clear the worker's accumulator stack + last-iteration PV.
// Alias the iterative-deepening orchestration helpers (they live in the search_id
// leaf) so workerStartSearching/iterativeDeepening call sites are unchanged.
const ssPrologue = search_id.ssPrologue;
const ssSetStop = search_id.ssSetStop;
const ssShouldBusywait = search_id.ssShouldBusywait;
const ssSetPrevScores = search_id.ssSetPrevScores;

// Test best->rootMoves[0].pv.size()==1 && extract_ponder_from_tt(worker->tt, worker->rootPos).
fn ssPvOneAndPonder(wl: *worker_layout.WorkerLayout, best: *const worker_layout.WorkerLayout) u8 {
    const pv = &workerRootMove0(best).pv;
    if (pv.length != 1) return 0;
    const tp = workerTT(wl);
    // A completed search implies a sized table (the QCtx invariant); unwrap here.
    return extractPonderFromTt(pv, tp.table.?, tp.cluster_count, tp.generation8, &wl.root_pos);
}

const ssContext = search_id.ssContext;
const ssTmInit = search_id.ssTmInit;
const ssThreadsStart = search_id.ssThreadsStart;
const ssWaitFinished = search_id.ssWaitFinished;
const ssGetBestThread = search_id.ssGetBestThread;
const ssNpmsecAdvance = search_id.ssNpmsecAdvance;

// Drive the workerStartSearching control flow. The leaf helpers run the individual
// time-management, thread-pool, skill, and UCI-output operations.
// Alias iterative deepening back for workerStartSearching (the only caller) + the
// position.zig entry re-export; it lives in the search_id_loop leaf.
const search_id_loop = @import("search_id_loop.zig");
pub const iterativeDeepening = search_id_loop.iterativeDeepening;

pub fn workerStartSearching(worker: ?*anyopaque) void {
    const wl: *worker_layout.WorkerLayout = @ptrCast(@alignCast(worker.?));
    ssPrologue(wl);

    var ctx: SsCtx = undefined;
    ssContext(wl, &ctx);

    if (ctx.is_mainthread == 0) {
        _ = iterativeDeepening(wl);
        return;
    }

    ssTmInit(wl);

    if (ctx.root_moves_empty != 0) {
        ssEmitNoMoves(wl);
        return;
    }

    ssThreadsStart(wl);
    var uci_pv_sent = iterativeDeepening(wl) != 0;

    while (ssShouldBusywait(wl) != 0) {}

    ssSetStop(wl);
    ssWaitFinished(wl);

    // Read the live limit, not `ctx`: `ssTmInit` is what writes `limits.npmsec`, from the
    // `nodestime` option, and it runs after `ssContext` took its snapshot. Upstream reads the
    // field here too, after `tm.init` (search.cpp:235).
    if (wl.limits.npmsec != 0) ssNpmsecAdvance(wl);

    var best: ?*worker_layout.WorkerLayout = wl;
    if (ctx.limits_depth == 0 and ctx.skill_enabled == 0)
        best = ssGetBestThread(wl);

    ssSetPrevScores(wl, best.?);

    if (ssPvOneAndPonder(wl, best.?) != 0)
        uci_pv_sent = false;

    if (!uci_pv_sent or best != wl)
        ssEmitPv(wl, best);

    ssEmitBestmove(wl, best);
}

// Fetch in one shot the Worker state the inlined search needs, all stable for the
// whole search: the NNUE accumulator stack, the node counter, the (numa-resolved)
// Network, the accumulator-refresh cache, the optimism[2] array, and the three
// scalar Worker fields the search reads/writes directly — nmpMinPly, selDepth, and
// rootDepth. Cached in QCtx at entry; do_move/undo_move/evaluate and these scalar
// accesses cover the accumulator push/pop, pos.do_move, and the network forward
// pass + eval scaling.
// Snapshot once per search the Worker's live member pointers + shared stop flag,
// and -- on the main thread -- the SearchManager/TimeManagement/LimitsType time inputs.
// Use the worker_layout offset reads + the FT pointer (the network handle is never
// dereferenced -- weights serve from the network's own storage).
// Alias buildCtx below (searchCbWorkerState is private to that leaf); QCtx construction
// (searchCbWorkerState + buildCtx) lives in the search_setup leaf.

// Push/pop the accumulator stack (defined in stockfish_zcu.o). push() bumps
// the stack and hands back pointers to the just-reserved DirtyPiece/DirtyThreats
// scratch that pos.do_move fills in; pop() drops the top entry.

// Run the NNUE forward pass + final eval scaling (defined in stockfish_zcu.o).
// network_evaluate runs the bucketed network and returns the scaled psqt/positional
// halves; eval_compute_value applies the optimism/material/rule50 blend.
const EvalOutput = struct {
    psqt: i32,
    positional: i32,
};
const EvalInput = struct {
    psqt: i32,
    positional: i32,
    optimism: i32,
    material: i32,
    rule50_count: i32,
    value_tb_loss_in_max_ply: i32,
    value_tb_win_in_max_ply: i32,
};

// Fetch the SearchManager check-time inputs once per search tree in worker_state.
// Live (mutable) fields are pointers; fixed-per-search fields are snapshot values.
// calls_cnt is null when this worker is not the main thread (check_time is a
// main-thread-only operation).

// Snapshot the iterative_deepening state once at entry (skill-off path only). Live
// fields are pointers into Worker/SearchManager/ThreadPool; the rest are values
// read once.

const QCtx = search_ctx.QCtx;

// Run the update-seldepth step: selDepth tracks the deepest ply reached, used
// only for UCI reporting. Bump the cached field when this ply is deeper.
// Alias the node-level accumulator / do-move / eval helpers here so the qsearch/search
// recursion call sites are unchanged; they live in the search_acc leaf.
const verifyDoMove = search_acc.verifyDoMove;
const verifyUndoMove = search_acc.verifyUndoMove;
const legalContains = search_acc.legalContains;

// extractPonderFromTt: make the best move, probe the TT for a reply
// stored there, append it to the PV if it is a legal move, unmake. Return
// whether a ponder move was found (pv length > 1). The tt context (table base,
// cluster count, generation) is handed over by the caller.
pub fn extractPonderFromTt(pv: *PVMoves, table: [*]tt.TtCluster, cluster_count: usize, generation: u8, pos_ptr: *Position) u8 {
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
// the (ss-2)/(ss-4) continuation-correction values, then apply the formula.

// pos.key() == adjust_key50(st->key): compute the rule50-adjusted Zobrist key the TT
// is indexed by. Near the 50-move boundary it perturbs the key so positions
// differing only in rule50 hash apart.

// Fetch the stable per-search Worker state once and assemble the QCtx threaded
// through the whole (q)search recursion.
const buildCtx = search_setup.buildCtx;

// Alias root-search bookkeeping + time/stop control (checkTime / rootUpdate /
// rootTtMove / rootInList / searchStopped / inLastIterPv) back under the names the
// search bodies call; they live in the search_control leaf now.
const search_control = @import("search_control.zig");
const checkTime = search_control.checkTime;
const rootUpdate = search_control.rootUpdate;
const rootTtMove = search_control.rootTtMove;
const rootInList = search_control.rootInList;
const searchStopped = search_control.searchStopped;
const inLastIterPv = search_control.inLastIterPv;

// ======================= search() =======================
// Run the main search for Root/PV/NonPV nodes (node type selected by the
// root_node/pv_node/cut_node params). Reuse the qsearch infrastructure
// (mirrors, TT, MovePicker, the worker_state pointers) plus the pos_do_move
// (2-arg) / followPV / root-bookkeeping callbacks. (do_null_move, reduction,
// nmpMinPly, and seldepth are now inlined: null make/unmake is handled directly,
// and the reductions table / rootDelta / nmpMinPly / selDepth are read through the
// stable pointers worker_state hands the search.)

// pos.capture(m): match an occupied target (non-castling) or en passant; exclude pure promotions.

// Alias quiescence search + shared PV/search primitives back so the main search +
// driver call sites are unchanged; they live in the search_qsearch leaf now.
const search_qsearch = @import("search_qsearch.zig");
pub const isShuffling = search_qsearch.isShuffling;
const adjustKey50 = search_qsearch.adjustKey50;

// Find captVal / captEntry in the search_common leaf.

// ==================== iterative_deepening() ====================
// Keep multi-thread correct via the UCI pv() sink and the cross-thread bestMoveChanges collection (sum + reset,
// returned as a double). Handle the skill-off path
// only, so no skill/RNG logic is needed here.

// Alias the ID-loop root-move / skill / mate helpers (they now live in the search_id leaf);
// iterativeDeepening drives them through these aliases.

// Alias the main alpha-beta search back for the iterative-deepening driver + entry
// glue; it lives in the search_main leaf now.
const search_main = @import("search_main.zig");

// Compute the three quiet-history entries for `move` from the table bases and
// apply the shared quiet-history update. mainHistory is [2][65536], lowPlyHistory
// [5][65536], pawn_row is one fixed [16][64] page.
// update_all_stats: credit the best move and debit the searched-but-
// rejected quiets/captures. The caller passes only the Worker, Position, and
// Stack pointers and the two move lists (ptr+len); Zig resolves captureHistory
// from the Worker mirror and the quiet entries via updateQuietHistoriesWorker,
// and owns all bonus/malus scaling, the running malus decay, and the gravity.
