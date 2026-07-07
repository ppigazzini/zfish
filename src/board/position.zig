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

// Board primitives (piece/color/file/move-type consts, move-word decoders, the
// pure square helpers) live in the board_core leaf (M17.3f); re-exported so the
// call sites throughout this file stay unqualified.
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

// Zobrist/cuckoo hashing lives in the zobrist leaf (M17.3i). The index helpers
// are comptime, so re-exported; the runtime tables are read as zobrist.<name>.
const psqIdx = zobrist.psqIdx;
const h1 = zobrist.h1;
const h2 = zobrist.h2;

// Memory mirror of the search Stack (src/search.h). Only the scalar fields used
// by ported search helpers are read; the layout/size must match for ss-N stack
// arithmetic.
// Search POD types (SearchStack/CorrectionBundle/PVMoves/RootMove) live in the
// search_types leaf (M17.3p); re-exported so the search-driver call sites are
// unchanged.
pub const SearchStack = search_types.SearchStack;
pub const PVMoves = search_types.PVMoves;
pub const RootMove = search_types.RootMove;

// History tables + their dimensions live in the worker_histories leaf module so that
// both this module (the history-update code) and graph_layout (which embeds the type
// as WorkerLayout.histories) can name them without an import cycle. Re-export the
// names the ported search code + external callers already use.
const worker_histories = @import("worker_histories");
const position_types = @import("position_types");
const search_types = @import("search_types");
const fen = @import("fen");
const board_core = @import("board_core");
const legality = @import("legality");
const zobrist = @import("zobrist");
const repetition = @import("repetition");
const position_query = @import("position_query");
const state_setup = @import("state_setup");
const move_do = @import("move_do");
const fen_parse = @import("fen_parse");
const search_driver = @import("search_driver");
const position_lifecycle = @import("position_lifecycle");
const hist_color_nb = worker_histories.hist_color_nb;
const hist_uint16 = worker_histories.hist_uint16;
const hist_low_ply = worker_histories.hist_low_ply;
const hist_piece_nb = worker_histories.hist_piece_nb;
const hist_square_nb = worker_histories.hist_square_nb;
const hist_piece_type_nb = worker_histories.hist_piece_type_nb;
const hist_pieceto = worker_histories.hist_pieceto;
pub const WorkerHistories = worker_histories.WorkerHistories;
pub const worker_shared_history_off = worker_histories.worker_shared_history_off;

// The Worker's WorkerHistories sub-block is now the typed WorkerLayout.histories field
// (M17.2p), so this is just its address -- no reinterpret.

const white_oo: u8 = 1;
const white_ooo: u8 = 2;
const black_oo: u8 = 4;
const black_ooo: u8 = 8;
const black: u8 = 1;
const sq_none: u8 = 64;

// StateInfo/Position and their POD scratch members live in the position_types leaf
// module (M17.3b) so graph_layout can embed typed root_pos/root_state without a
// module cycle; re-exported here as the position module's public surface.
pub const StateInfo = position_types.StateInfo;
pub const Position = position_types.Position;

// FEN encoding (format/flip/endgame-code synthesis) lives in the fen leaf module
// (M17.3e); re-exported so position_port.flipFen/formatFen/buildEndgameFen keep
// resolving through the position module's surface.
pub const flipFen = fen.flipFen;
pub const formatFen = fen.formatFen;
pub const buildEndgameFen = fen.buildEndgameFen;

// Move legality / SEE queries live in the legality leaf (M17.3h); re-exported so
// the search + movegen call sites and the move_is_legal_fn hook keep resolving.
pub const attackersTo = legality.attackersTo;
pub const attackersToExist = legality.attackersToExist;
pub const legal = legality.legal;
pub const seeGe = legality.seeGe;
pub const pseudoLegal = legality.pseudoLegal;
pub const givesCheck = legality.givesCheck;

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
pub fn initRuntime() void {
    // Register the cycle-break hooks movegen/movepick/nnue/uci_move call (they can't
    // import position).
    position_snapshot_port.fill_fn = &fillSnapshot;
    position_snapshot_port.move_is_legal_fn = &legal;

    // Build the Zobrist + cuckoo tables (now owned by the zobrist leaf, M17.3i).
    zobrist.init();
}

// Move make/unmake lives in the move_do leaf (M17.3m/n); re-exported so the search
// + FEN-setup callers resolve through the position surface.
pub const doNullMove = move_do.doNullMove;
pub const undoNullMove = move_do.undoNullMove;
pub const doMove = move_do.doMove;
pub const undoMove = move_do.undoMove;
const putPiece = move_do.putPiece;

// Repetition / draw detection lives in the repetition leaf (M17.3j); re-exported
// so the search callers resolve through the position surface.
pub const upcomingRepetition = repetition.upcomingRepetition;
pub const isDraw = repetition.isDraw;
pub const isRepetition = repetition.isRepetition;
pub const hasRepeated = repetition.hasRepeated;

// Read-only Position accessors + snapshot builders live in the position_query
// leaf (M17.3k); re-exported so callers and the fill_snapshot hook resolve here.
pub const sideToMove = position_query.sideToMove;
pub const isChess960 = position_query.isChess960;
pub const gamePly = position_query.gamePly;
pub const hasCheckers = position_query.hasCheckers;
pub const wdlMaterial = position_query.wdlMaterial;
pub const fillSnapshot = position_query.fillSnapshot;
pub const accumulatorSnapshot = position_query.accumulatorSnapshot;

// Position derived-state setup lives in the state_setup leaf (M17.3l); re-exported
// so make/unmake, FEN setup, and null-move resolve through the position surface.
pub const setCastlingRight = state_setup.setCastlingRight;
pub const updateSliderBlockers = state_setup.updateSliderBlockers;
pub const setState = state_setup.setState;
pub const setCheckInfo = state_setup.setCheckInfo;
pub const computeMaterialKey = state_setup.computeMaterialKey;

// FEN parsing (build a Position from a FEN) lives in the fen_parse leaf (M17.3o);
// re-exported so setPositionState and the engine/thread callers resolve here.
pub const setPosition = fen_parse.setPosition;

// Mirrors of the NNUE dirty-state structs (src/types.h) the accumulator consumes.
const DirtyPiece = position_types.DirtyPiece;
const DirtyThreats = position_types.DirtyThreats;

// The per-Worker history subsystem + the alpha-beta/qsearch driver + iterative
// deepening live in the search_driver leaf (M17.3q); re-exported so the engine,
// thread, and main callers resolve the search entry points through the position
// surface (position.zig is now a thin board+search facade over the leaf modules).
pub const SharedHistories = search_driver.SharedHistories;
pub const SharedHistoriesMap = search_driver.SharedHistoriesMap;
pub const clearSharedHistory = search_driver.clearSharedHistory;
pub const constructSharedHistories = search_driver.constructSharedHistories;
pub const deinitSharedHistories = search_driver.deinitSharedHistories;
pub const verifySharedHistories = search_driver.verifySharedHistories;
pub const updateQuietHistoriesWorker = search_driver.updateQuietHistoriesWorker;
pub const setContHist = search_driver.setContHist;
pub const ageMainHistory = search_driver.ageMainHistory;
pub const fillLowPlyHistory = search_driver.fillLowPlyHistory;
pub const clearWorkerHistories = search_driver.clearWorkerHistories;
pub const updateQuietHistories = search_driver.updateQuietHistories;
pub const updateContinuationHistories = search_driver.updateContinuationHistories;
pub const isShuffling = search_driver.isShuffling;
pub const workerStartSearching = search_driver.workerStartSearching;
pub const doMoveState = position_lifecycle.doMoveState;
pub const create = position_lifecycle.create;
pub const destroy = position_lifecycle.destroy;
pub const setPositionState = position_lifecycle.setPositionState;
pub const extractPonderFromTt = search_driver.extractPonderFromTt;
pub const qsearchEntry = search_driver.qsearchEntry;
pub const searchEntry = search_driver.searchEntry;
pub const iterativeDeepening = search_driver.iterativeDeepening;
pub const updateAllStats = search_driver.updateAllStats;
pub const updateCorrectionHistory = search_driver.updateCorrectionHistory;
