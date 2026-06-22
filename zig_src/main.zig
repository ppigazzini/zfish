const std = @import("std");
const c = @cImport({
    @cInclude("stdlib.h");
    @cInclude("stdio.h");
});

const benchmark_port = @import("benchmark");
const bitboard_port = @import("bitboard");
const engine_port = @import("engine");
const memory_port = @import("memory.zig");
const graph_layout = @import("graph_layout.zig");
const worker_layout = @import("worker_layout.zig");
const accumulator_layout = @import("accumulator_layout.zig");
const worker_construct = @import("worker_construct.zig");
const worker_native_construct = @import("worker_native_construct.zig");
const misc_port = @import("misc");
const movegen_port = @import("movegen");
const movepick_port = @import("movepick");
const nnue_accumulator_port = @import("nnue_accumulator");
const network_port = @import("network");
const nnue_feature_port = @import("nnue_feature");
const option_port = @import("option");
const position_port = @import("position");
const search_port = @import("search");
const score_port = @import("score.zig");
const thread_port = @import("thread");
const evaluate_port = @import("evaluate");
const nnue_misc_port = @import("nnue_misc");
const timeman_port = @import("timeman");
const tt_port = @import("tt");
const uci_port = @import("uci");
const position_snapshot = @import("position_snapshot");
const uci_move_port = @import("uci_move");
const target_flags = @import("target_flags");

comptime {
    _ = graph_layout;
    _ = worker_layout;
    _ = accumulator_layout;
    _ = worker_construct;
    _ = worker_native_construct;
}

extern fn zfish_bitboards_init() void;
extern fn zfish_uci_create_engine(argc: c_int, argv: [*]const [*:0]u8) ?*anyopaque;
extern fn zfish_uci_destroy_engine(engine: ?*anyopaque) void;
const PositionSnapshot = position_snapshot.PositionSnapshot;

pub fn main(init: std.process.Init) !void {
    var argc: usize = 0;
    var count_iter = std.process.Args.Iterator.init(init.minimal.args);
    while (count_iter.next()) |_| {
        argc += 1;
    }

    const argv = try init.gpa.alloc([*:0]u8, argc);
    defer init.gpa.free(argv);

    var fill_iter = std.process.Args.Iterator.init(init.minimal.args);
    var index: usize = 0;
    while (fill_iter.next()) |arg| : (index += 1) {
        argv[index] = @constCast(arg.ptr);
    }

    const info = zfish_misc_engine_info_text() orelse return error.OutOfMemory;
    defer c.free(@ptrCast(info));

    _ = c.puts(@ptrCast(info));

    zfish_bitboards_init();
    position_port.initRuntime();

    const engine = zfish_uci_create_engine(@intCast(argc), argv.ptr) orelse return error.OutOfMemory;
    defer zfish_uci_destroy_engine(engine);

    uci_port.loopRuntime(engine);
}

pub export fn zfish_std_aligned_alloc(alignment: usize, size: usize) ?*anyopaque {
    return memory_port.stdAlignedAlloc(alignment, size);
}

pub export fn _ZN9Stockfish17std_aligned_allocEmm(alignment: usize, size: usize) ?*anyopaque {
    return memory_port.stdAlignedAlloc(alignment, size);
}

pub export fn zfish_std_aligned_free(ptr: ?*anyopaque) void {
    memory_port.stdAlignedFree(ptr);
}

pub export fn _ZN9Stockfish16std_aligned_freeEPv(ptr: ?*anyopaque) void {
    memory_port.stdAlignedFree(ptr);
}

pub export fn zfish_misc_hash_bytes(
    data_ptr: [*]const u8,
    data_len: usize,
) u64 {
    return misc_port.hashBytes(data_ptr[0..data_len]);
}

pub export fn zfish_misc_str_to_size_t(
    input_ptr: [*]const u8,
    input_len: usize,
) usize {
    return misc_port.strToSizeT(input_ptr[0..input_len]);
}

pub export fn zfish_misc_read_file_to_string(
    path_ptr: [*]const u8,
    path_len: usize,
) ?[*:0]u8 {
    return misc_port.readFileToString(path_ptr[0..path_len]);
}

pub export fn zfish_misc_remove_whitespace(
    input_ptr: [*]const u8,
    input_len: usize,
) ?[*:0]u8 {
    return misc_port.removeWhitespace(input_ptr[0..input_len]);
}

pub export fn zfish_misc_is_whitespace(
    input_ptr: [*]const u8,
    input_len: usize,
) bool {
    return misc_port.isWhitespace(input_ptr[0..input_len]);
}

pub export fn zfish_misc_get_binary_directory(
    argv0_ptr: [*]const u8,
    argv0_len: usize,
) ?[*:0]u8 {
    return misc_port.getBinaryDirectory(argv0_ptr[0..argv0_len]);
}

pub export fn zfish_misc_get_working_directory() ?[*:0]u8 {
    return misc_port.getWorkingDirectory();
}

pub export fn zfish_misc_engine_version_info_text() ?[*:0]u8 {
    return misc_port.engineVersionInfoText();
}

pub export fn zfish_misc_engine_info_text() ?[*:0]u8 {
    return misc_port.engineInfoText(0);
}

pub export fn zfish_misc_engine_info_mode(to_uci: u8) ?[*:0]u8 {
    return misc_port.engineInfoText(to_uci);
}

pub export fn zfish_misc_compiler_info_text() ?[*:0]u8 {
    return misc_port.compilerInfoText();
}

pub export fn zfish_misc_dbg_hit_on(cond: u8, slot: c_int) void {
    misc_port.dbgHitOn(cond != 0, slot);
}

pub export fn zfish_misc_dbg_mean_of(value: i64, slot: c_int) void {
    misc_port.dbgMeanOf(value, slot);
}

pub export fn zfish_misc_dbg_stdev_of(value: i64, slot: c_int) void {
    misc_port.dbgStdevOf(value, slot);
}

pub export fn zfish_misc_dbg_extremes_of(value: i64, slot: c_int) void {
    misc_port.dbgExtremesOf(value, slot);
}

pub export fn zfish_misc_dbg_correl_of(value1: i64, value2: i64, slot: c_int) void {
    misc_port.dbgCorrelOf(value1, value2, slot);
}

pub export fn zfish_misc_dbg_print() void {
    misc_port.dbgPrint();
}

pub export fn zfish_misc_dbg_clear() void {
    misc_port.dbgClear();
}

pub export fn zfish_position_build_endgame_fen(
    code_ptr: [*]const u8,
    code_len: usize,
    color: u8,
) ?[*:0]u8 {
    return position_port.buildEndgameFen(code_ptr, code_len, color);
}

pub export fn zfish_position_format_fen(
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
    return position_port.formatFen(
        board_ptr,
        side_to_move,
        chess960,
        castling_rights,
        white_oo_rook_square,
        white_ooo_rook_square,
        black_oo_rook_square,
        black_ooo_rook_square,
        ep_square,
        rule50,
        game_ply,
    );
}

pub export fn zfish_position_compute_material_key(
    piece_counts_ptr: [*]const c_int,
    piece_count_len: usize,
) u64 {
    return position_port.computeMaterialKey(piece_counts_ptr, piece_count_len);
}

pub export fn zfish_position_is_repetition_method(pos_ptr: *const anyopaque, ply: c_int) u8 {
    return @intFromBool(position_port.isRepetition(pos_ptr, ply));
}

pub export fn zfish_position_is_draw_method(pos_ptr: *const anyopaque, ply: c_int) u8 {
    return @intFromBool(position_port.isDraw(pos_ptr, ply));
}

pub export fn zfish_position_do_null_move(pos_ptr: *anyopaque, new_st_ptr: *anyopaque) void {
    position_port.doNullMove(pos_ptr, new_st_ptr);
}

pub export fn zfish_position_undo_null_move(pos_ptr: *anyopaque) void {
    position_port.undoNullMove(pos_ptr);
}

pub export fn zfish_position_undo_move_method(pos_ptr: *anyopaque, move: u16) void {
    position_port.undoMove(pos_ptr, move);
}

// do_move that links a fresh StateInfo and computes givesCheck internally
// (Position::do_move(Move, StateInfo&)); exported from the bridge.
extern fn zfish_position_do_move_state(pos_ptr: *anyopaque, move_raw: u16, state_ptr: *anyopaque) void;

// Recursive perft node counter. Replaces the C++ Benchmark::perft recursion:
// the bridge keeps the root divide loop (for byte-identical per-move output and
// MoveList ordering) and calls this for each root move's subtree. Reuses the
// Zig legal movegen and the do_move/undo_move seam the search already drives.
const perft_max_depth = 64;
const PerftStateBuf = [graph_layout.state_info_size]u8;

fn perftCount(pos_ptr: *anyopaque, depth: c_int, states: *[perft_max_depth]PerftStateBuf, ply: usize) u64 {
    if (depth <= 0) return 1;
    var moves: [256]u16 = undefined;
    const n = movegen_port.generateLegal(pos_ptr, &moves);
    if (depth == 1) return n; // leaf: legal-move count
    var nodes: u64 = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        zfish_position_do_move_state(pos_ptr, moves[i], &states[ply]);
        nodes += perftCount(pos_ptr, depth - 1, states, ply + 1);
        zfish_position_undo_move_method(pos_ptr, moves[i]);
    }
    return nodes;
}

pub export fn zfish_perft_subtree(pos_ptr: *anyopaque, depth: c_int) u64 {
    const capped = if (depth > perft_max_depth) perft_max_depth else depth;
    var states: [perft_max_depth]PerftStateBuf align(64) = undefined;
    return perftCount(pos_ptr, capped, &states, 0);
}

pub export fn zfish_position_do_move(
    pos_ptr: *anyopaque,
    move: u16,
    new_st_ptr: *anyopaque,
    gives_check: u8,
    dp_ptr: *anyopaque,
    dts_ptr: *anyopaque,
) void {
    position_port.doMove(pos_ptr, move, new_st_ptr, gives_check, dp_ptr, dts_ptr);
}

pub export fn zfish_position_upcoming_repetition_method(pos_ptr: *const anyopaque, ply: c_int) u8 {
    return @intFromBool(position_port.upcomingRepetition(pos_ptr, ply));
}

pub export fn zfish_position_init_runtime() void {
    position_port.initRuntime();
}

pub export fn zfish_position_has_repeated_method(pos_ptr: *const anyopaque) u8 {
    return @intFromBool(position_port.hasRepeated(pos_ptr));
}

pub export fn zfish_position_attackers_to_method(pos_ptr: *const anyopaque, s: u8, occupied: u64) u64 {
    return position_port.attackersTo(pos_ptr, s, occupied);
}

pub export fn zfish_position_update_slider_blockers_method(pos_ptr: *const anyopaque, color: u8) void {
    position_port.updateSliderBlockers(pos_ptr, color);
}

pub export fn zfish_position_set_check_info_method(pos_ptr: *const anyopaque) void {
    position_port.setCheckInfo(pos_ptr);
}

pub export fn zfish_position_set_castling_right_method(pos_ptr: *anyopaque, color: u8, rfrom: u8) void {
    position_port.setCastlingRight(pos_ptr, color, rfrom);
}

pub export fn zfish_position_flip_fen(fen_ptr: [*]const u8, fen_len: usize) ?[*:0]u8 {
    return position_port.flipFen(fen_ptr, fen_len);
}

pub export fn zfish_position_set_method(
    pos_ptr: *anyopaque,
    fen_ptr: [*]const u8,
    fen_len: usize,
    is_chess960: u8,
    st_ptr: *anyopaque,
    pos_size: usize,
    st_size: usize,
) ?[*:0]u8 {
    return position_port.setPosition(pos_ptr, fen_ptr, fen_len, is_chess960, st_ptr, pos_size, st_size);
}

pub export fn zfish_position_set_state_method(pos_ptr: *const anyopaque) void {
    position_port.setState(pos_ptr);
}

pub export fn zfish_search_is_shuffling(pos_ptr: *const anyopaque, ss_ptr: *const anyopaque, move: u16) u8 {
    return @intFromBool(position_port.isShuffling(pos_ptr, ss_ptr, move));
}

pub export fn zfish_search_update_continuation_histories(ss_ptr: *anyopaque, pc: u8, to: u8, bonus: c_int) void {
    position_port.updateContinuationHistories(ss_ptr, pc, to, bonus);
}

pub export fn zfish_search_update_quiet_histories(
    worker_ptr: *anyopaque,
    pos_ptr: *const anyopaque,
    ss_ptr: *anyopaque,
    move: u16,
    bonus: c_int,
) void {
    position_port.updateQuietHistoriesWorker(worker_ptr, pos_ptr, ss_ptr, move, bonus);
}

pub export fn zfish_search_update_all_stats(
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
    position_port.updateAllStats(worker_ptr, pos_ptr, ss_ptr, best_move, prev_sq, quiets, n_quiets, captures, n_captures, depth, tt_move);
}

pub export fn zfish_search_update_correction_history(
    worker_ptr: *anyopaque,
    pos_ptr: *const anyopaque,
    ss_ptr: *anyopaque,
    bonus: c_int,
) void {
    position_port.updateCorrectionHistory(worker_ptr, pos_ptr, ss_ptr, bonus);
}

pub export fn zfish_position_legal_method(pos_ptr: *const anyopaque, move: u16) u8 {
    return @intFromBool(position_port.legal(pos_ptr, move));
}

pub export fn zfish_position_gives_check_method(pos_ptr: *const anyopaque, move: u16) u8 {
    return @intFromBool(position_port.givesCheck(pos_ptr, move));
}

pub export fn zfish_position_pseudo_legal_method(pos_ptr: *const anyopaque, move: u16) u8 {
    return @intFromBool(position_port.pseudoLegal(pos_ptr, move));
}

pub export fn zfish_position_see_ge_method(pos_ptr: *const anyopaque, move: u16, threshold: c_int) u8 {
    return @intFromBool(position_port.seeGe(pos_ptr, move, threshold));
}

pub export fn zfish_position_attackers_to_exist_method(
    pos_ptr: *const anyopaque,
    s: u8,
    occupied: u64,
    color: u8,
) u8 {
    return @intFromBool(position_port.attackersToExist(pos_ptr, s, occupied, color));
}

pub export fn zfish_bitboards_init_runtime(
    popcnt16: *[1 << 16]u8,
    square_distance: *[64][64]u8,
    line_bb: *[64][64]u64,
    between_bb: *[64][64]u64,
    ray_pass_bb: *[64][64]u64,
) void {
    return bitboard_port.initRuntimeTables(
        popcnt16,
        square_distance,
        line_bb,
        between_bb,
        ray_pass_bb,
    );
}

pub export fn zfish_bitboards_init_magics_runtime(
    entries: *[64][2]bitboard_port.MagicInitEntry,
    rook_table_ptr: [*]u64,
    bishop_table_ptr: [*]u64,
) void {
    return bitboard_port.initMagicRuntime(entries, rook_table_ptr, bishop_table_ptr);
}

pub export fn zfish_search_to_corrected_static_eval(v: c_int, cv: c_int) c_int {
    return search_port.toCorrectedStaticEval(v, cv);
}

pub export fn zfish_search_value_draw(nodes: usize) c_int {
    return search_port.valueDraw(nodes);
}

pub export fn zfish_search_fill_reductions(reductions_ptr: [*]c_int, count: usize) void {
    return search_port.fillReductions(reductions_ptr, count);
}

pub export fn zfish_search_stat_bonus(depth: c_int, is_tt_move: u8, prev_stat_score: c_int) c_int {
    return search_port.statBonus(depth, is_tt_move != 0, prev_stat_score);
}

pub export fn zfish_search_stat_malus(depth: c_int) c_int {
    return search_port.statMalus(depth);
}

pub export fn zfish_search_razor_margin(depth: c_int) c_int {
    return search_port.razorMargin(depth);
}

pub export fn zfish_search_qsearch_stand_pat_blend(best_value: c_int, beta: c_int) c_int {
    return search_port.qsearchStandPatBlend(best_value, beta);
}

pub export fn zfish_search_qsearch_fail_high_blend(best_value: c_int, beta: c_int) c_int {
    return search_port.qsearchFailHighBlend(best_value, beta);
}

pub export fn zfish_search_eval_diff(prev_static_eval: c_int, static_eval: c_int) c_int {
    return search_port.evalDiff(prev_static_eval, static_eval);
}

pub export fn zfish_search_qsearch_futility_base(static_eval: c_int) c_int {
    return search_port.qsearchFutilityBase(static_eval);
}

pub export fn zfish_search_prior_conthist_scale(scaled_bonus: c_int) c_int {
    return search_port.priorConthistScale(scaled_bonus);
}

pub export fn zfish_search_prior_mainhist_scale(scaled_bonus: c_int) c_int {
    return search_port.priorMainhistScale(scaled_bonus);
}

pub export fn zfish_search_prior_pawnhist_scale(scaled_bonus: c_int) c_int {
    return search_port.priorPawnhistScale(scaled_bonus);
}

pub export fn zfish_search_capture_stat_score(piece_value: c_int, capture_hist: c_int) c_int {
    return search_port.captureStatScore(piece_value, capture_hist);
}

pub export fn zfish_search_quiet_stat_score(main_hist: c_int, cont0: c_int, cont1: c_int) c_int {
    return search_port.quietStatScore(main_hist, cont0, cont1);
}

pub export fn zfish_search_corrhist_bonus(eval_delta: c_int, depth: c_int, has_best_move: u8) c_int {
    return search_port.correctionHistoryBonus(eval_delta, depth, has_best_move != 0);
}

pub export fn zfish_search_aspiration_initial_delta(thread_idx: usize, mean_squared_score: c_int) c_int {
    return search_port.aspirationInitialDelta(thread_idx, mean_squared_score);
}

pub export fn zfish_search_aspiration_delta_grow(delta: c_int) c_int {
    return search_port.aspirationDeltaGrow(delta);
}

pub export fn zfish_search_optimism(avg: c_int) c_int {
    return search_port.optimism(avg);
}

pub export fn zfish_search_age_main_history(worker_ptr: *anyopaque) void {
    position_port.ageMainHistory(worker_ptr);
}

pub export fn zfish_search_fill_low_ply_history(worker_ptr: *anyopaque) void {
    position_port.fillLowPlyHistory(worker_ptr);
}

pub export fn zfish_search_clear_worker_histories(worker_ptr: *anyopaque) void {
    position_port.clearWorkerHistories(worker_ptr);
}

pub export fn zfish_search_set_cont_hist(worker_ptr: *anyopaque, ss_ptr: *anyopaque, in_check: u8, capture: u8, pc: u8, to: u8) void {
    position_port.setContHist(worker_ptr, ss_ptr, in_check, capture, pc, to);
}

pub export fn zfish_search_qsearch(worker: *anyopaque, pos_ptr: *anyopaque, ss_ptr: *anyopaque, alpha: c_int, beta: c_int, pv_node: u8) c_int {
    return position_port.qsearchEntry(worker, pos_ptr, ss_ptr, alpha, beta, pv_node);
}

pub export fn zfish_search_search(worker: *anyopaque, pos_ptr: *anyopaque, ss_ptr: *anyopaque, alpha: c_int, beta: c_int, depth: c_int, cut_node: u8, pv_node: u8, root_node: u8) c_int {
    return position_port.searchEntry(worker, pos_ptr, ss_ptr, alpha, beta, depth, cut_node, pv_node, root_node);
}

pub export fn zfish_search_iterative_deepening(worker: *anyopaque) u8 {
    return position_port.iterativeDeepening(worker);
}

pub export fn zfish_search_extract_ponder_from_tt(pv: *anyopaque, table: ?*anyopaque, cc: usize, gen: u8, pos: *anyopaque) u8 {
    return position_port.extractPonderFromTt(pv, table, cc, gen, pos);
}

pub export fn zfish_position_fill_snapshot(pos_ptr: *const anyopaque, out: *anyopaque) void {
    position_port.fillSnapshot(pos_ptr, out);
}

pub export fn zfish_search_clear_shared_history(shared: *anyopaque, thread_idx: usize, numa_total: usize) void {
    position_port.clearSharedHistory(shared, thread_idx, numa_total);
}

pub export fn zfish_search_clear_refresh_cache(cache: *anyopaque, biases: [*]const i16) void {
    nnue_accumulator_port.clearRefreshCache(cache, biases);
}

pub export fn zfish_search_move_count_limit(depth: c_int, improving: u8) c_int {
    return search_port.moveCountLimit(depth, improving != 0);
}

pub export fn zfish_search_capture_futility_value(
    static_eval: c_int,
    lmr_depth: c_int,
    piece_value: c_int,
    capt_hist: c_int,
) c_int {
    return search_port.captureFutilityValue(static_eval, lmr_depth, piece_value, capt_hist);
}

pub export fn zfish_search_capture_see_margin(depth: c_int, capt_hist: c_int) c_int {
    return search_port.captureSeeMargin(depth, capt_hist);
}

pub export fn zfish_search_ttmh_depth_bonus(depth: c_int) c_int {
    return search_port.ttMoveHistoryDepthBonus(depth);
}

pub export fn zfish_search_ttmh_match_bonus(best_is_tt: u8) c_int {
    return search_port.ttMoveHistoryMatchBonus(best_is_tt != 0);
}

pub export fn zfish_search_prior_bonus_scale(
    prev_stat_score: c_int,
    depth: c_int,
    prev_movecount_gt8: u8,
    cond_a: u8,
    cond_b: u8,
) c_int {
    return search_port.priorBonusScale(prev_stat_score, depth, prev_movecount_gt8 != 0, cond_a != 0, cond_b != 0);
}

pub export fn zfish_search_prior_scaled_bonus_base(depth: c_int) c_int {
    return search_port.priorScaledBonusBase(depth);
}

pub export fn zfish_search_lmr_ttpv_reduction(pv_node: u8, value_gt_alpha: u8, depth_ge: u8, cut_node: u8) c_int {
    return search_port.lmrTtpvReduction(pv_node != 0, value_gt_alpha != 0, depth_ge != 0, cut_node != 0);
}

pub export fn zfish_search_lmr_corr_reduction(correction_value: c_int) c_int {
    return search_port.lmrCorrReduction(correction_value);
}

pub export fn zfish_search_lmr_stat_score_reduction(stat_score: c_int) c_int {
    return search_port.lmrStatScoreReduction(stat_score);
}

pub export fn zfish_search_lmr_all_node_scale(r: c_int, depth: c_int) c_int {
    return search_port.lmrAllNodeScale(r, depth);
}

pub export fn zfish_search_singular_beta(tt_value: c_int, ttpv_and_not_pv: u8, depth: c_int) c_int {
    return search_port.singularBeta(tt_value, ttpv_and_not_pv != 0, depth);
}

pub export fn zfish_search_singular_double_margin(
    pv_node: u8,
    not_tt_capture: u8,
    correction_value: c_int,
    tt_move_history: c_int,
    ply_gt_root: u8,
) c_int {
    return search_port.singularDoubleMargin(pv_node != 0, not_tt_capture != 0, correction_value, tt_move_history, ply_gt_root != 0);
}

pub export fn zfish_search_singular_triple_margin(
    pv_node: u8,
    not_tt_capture: u8,
    ttpv: u8,
    correction_value: c_int,
    ply_gt_root: u8,
) c_int {
    return search_port.singularTripleMargin(pv_node != 0, not_tt_capture != 0, ttpv != 0, correction_value, ply_gt_root != 0);
}

pub export fn zfish_search_history_prune_threshold(depth: c_int) c_int {
    return search_port.historyPruneThreshold(depth);
}

pub export fn zfish_search_quiet_futility_value(
    static_eval: c_int,
    no_best_move: u8,
    lmr_depth: c_int,
    eval_gt_alpha: u8,
) c_int {
    return search_port.quietFutilityValue(static_eval, no_best_move != 0, lmr_depth, eval_gt_alpha != 0);
}

pub export fn zfish_search_quiet_see_margin(lmr_depth: c_int) c_int {
    return search_port.quietSeeMargin(lmr_depth);
}

pub export fn zfish_search_probcut_beta(beta: c_int, improving: u8) c_int {
    return search_port.probCutBeta(beta, improving != 0);
}

pub export fn zfish_search_probcut_beta_deep(beta: c_int) c_int {
    return search_port.probCutBetaDeep(beta);
}

pub export fn zfish_search_null_move_threshold(beta: c_int, depth: c_int, improving: u8) c_int {
    return search_port.nullMoveThreshold(beta, depth, improving != 0);
}

pub export fn zfish_search_null_move_reduction(depth: c_int) c_int {
    return search_port.nullMoveReduction(depth);
}

pub export fn zfish_search_nmp_min_ply(ply: c_int, depth: c_int, r: c_int) c_int {
    return search_port.nmpMinPly(ply, depth, r);
}

pub export fn zfish_search_futility_margin(
    depth: c_int,
    tt_hit: u8,
    improving: u8,
    opponent_worsening: u8,
    correction_value: c_int,
) c_int {
    return search_port.futilityMargin(depth, tt_hit != 0, improving != 0, opponent_worsening != 0, correction_value);
}

pub export fn zfish_search_futility_return(beta: c_int, eval: c_int) c_int {
    return search_port.futilityReturn(beta, eval);
}

pub export fn zfish_search_quiet_low_ply_scale(bonus: c_int) c_int {
    return search_port.quietLowPlyScale(bonus);
}

pub export fn zfish_search_quiet_cont_scale(bonus: c_int) c_int {
    return search_port.quietContScale(bonus);
}

pub export fn zfish_search_quiet_pawn_scale(bonus: c_int) c_int {
    return search_port.quietPawnScale(bonus);
}

pub export fn zfish_search_conthist_delta(
    bonus: c_int,
    weight: c_int,
    positive_count: c_int,
    i: c_int,
) c_int {
    return search_port.conthistDelta(bonus, weight, positive_count, i);
}

pub export fn zfish_search_correction_value(
    pcv: c_int,
    micv: c_int,
    wnpcv: c_int,
    bnpcv: c_int,
    cch2: c_int,
    cch4: c_int,
    m_ok: u8,
) c_int {
    return search_port.correctionValue(pcv, micv, wnpcv, bnpcv, cch2, cch4, m_ok != 0);
}

pub export fn zfish_search_value_to_tt(v: c_int, ply: c_int) c_int {
    return search_port.valueToTt(v, ply);
}

pub export fn zfish_search_value_from_tt(v: c_int, ply: c_int, r50c: c_int) c_int {
    return search_port.valueFromTt(v, ply, r50c);
}

pub export fn zfish_search_reduction(
    reductions_ptr: [*]const c_int,
    depth: c_int,
    move_number: c_int,
    delta: c_int,
    root_delta: c_int,
    improving: u8,
) c_int {
    return search_port.reduction(reductions_ptr, depth, move_number, delta, root_delta, improving != 0);
}

pub export fn zfish_movegen_generate_captures(
    pos: *const anyopaque,
    move_list: [*]u16,
) usize {
    return movegen_port.generateCaptures(pos, move_list);
}

pub export fn zfish_movegen_generate_quiets(
    pos: *const anyopaque,
    move_list: [*]u16,
) usize {
    return movegen_port.generateQuiets(pos, move_list);
}

pub export fn zfish_movegen_generate_evasions(
    pos: *const anyopaque,
    move_list: [*]u16,
) usize {
    return movegen_port.generateEvasions(pos, move_list);
}

pub export fn zfish_movegen_generate_non_evasions(
    pos: *const anyopaque,
    move_list: [*]u16,
) usize {
    return movegen_port.generateNonEvasions(pos, move_list);
}

pub export fn zfish_movegen_generate_legal(
    pos: *const anyopaque,
    move_list: [*]u16,
) usize {
    return movegen_port.generateLegal(pos, move_list);
}

pub export fn zfish_movepick_partial_insertion_sort(
    entries: [*]movepick_port.SortEntry,
    count: usize,
    limit: c_int,
) void {
    return movepick_port.partialInsertionSort(entries, count, limit);
}

pub export fn zfish_movepick_score_list(
    kind: u8,
    context: *const movepick_port.MovePickerContext,
    outputs: [*]movepick_port.SortEntry,
) usize {
    return movepick_port.scoreList(kind, context, outputs);
}

pub export fn zfish_movepick_init_main_stage(
    has_checkers: u8,
    has_tt_move: u8,
    depth: c_int,
) c_int {
    return movepick_port.initMainStage(has_checkers != 0, has_tt_move != 0, depth);
}

pub export fn zfish_movepick_init_probcut_stage(has_tt_move: u8) c_int {
    return movepick_port.initProbcutStage(has_tt_move != 0);
}

pub export fn zfish_movepick_next_move(
    state: *movepick_port.MovePickerState,
    context: *const movepick_port.MovePickerContext,
) u16 {
    return movepick_port.nextMove(state, context);
}

pub export fn zfish_thread_next_power_of_two(count: u64) usize {
    return thread_port.nextPowerOfTwo(count);
}

pub export fn zfish_thread_pick_best_thread(
    summaries: [*]const thread_port.ThreadSummary,
    count: usize,
) usize {
    return thread_port.pickBestThread(summaries, count);
}

pub export fn zfish_thread_start_thinking(
    pool: *anyopaque,
    options: *const anyopaque,
    pos: *anyopaque,
    limits: *const anyopaque,
    states_slot: *anyopaque,
) void {
    return thread_port.startThinking(pool, options, pos, limits, states_slot);
}

pub export fn zfish_engine_pending_states_available(states_slot: *anyopaque) u8 {
    return engine_port.pendingStatesAvailable(states_slot);
}

pub export fn zfish_engine_handoff_pending_states(
    pool: *anyopaque,
    states_slot: *anyopaque,
) u8 {
    return engine_port.handoffPendingStates(pool, states_slot);
}

pub export fn zfish_threadpool_reconfigure(
    pool: *anyopaque,
    numa_config: *const anyopaque,
    shared_state: *const anyopaque,
    update_context: *const anyopaque,
) void {
    return thread_port.reconfigure(pool, numa_config, shared_state, update_context);
}

pub export fn zfish_threadpool_clear(pool: *anyopaque) void {
    return thread_port.clear(pool);
}

pub export fn zfish_threadpool_start_searching(pool: *anyopaque) void {
    return thread_port.startSearching(pool);
}

pub export fn zfish_threadpool_wait_for_search_finished(pool: *anyopaque) void {
    return thread_port.waitForSearchFinished(pool);
}

pub export fn zfish_threadpool_ensure_network_replicated(pool: *anyopaque) void {
    return thread_port.ensureNetworkReplicated(pool);
}

pub export fn zfish_threadpool_nodes_searched(pool: *anyopaque) u64 {
    return thread_port.nodesSearched(pool);
}

pub export fn zfish_threadpool_tb_hits(pool: *anyopaque) u64 {
    return thread_port.tbHits(pool);
}

pub export fn zfish_threadpool_best_thread_index(pool: *anyopaque) usize {
    return thread_port.bestThreadIndex(pool);
}

// Native SearchManager data-field shims. The main manager's data members are
// written through the C++ navigation helper (which returns the manager pointer)
// plus the search_manager_off offset map, so these resets no longer use the C++
// SearchManager type -- they replace the former C++ main_manager()-> field shims.
// Exported only in the default build: the legacy oracle keeps src/thread.cpp's
// definitions, so gating the @export avoids a duplicate-symbol link error.
extern fn zfish_threadpool_main_manager_ptr(pool: *anyopaque) ?*anyopaque;

const sm_off = graph_layout.search_manager_off;

fn smFieldPtr(comptime T: type, pool: *anyopaque, offset: usize) ?*T {
    const mgr = zfish_threadpool_main_manager_ptr(pool) orelse return null;
    const base: [*]u8 = @ptrCast(mgr);
    return @ptrCast(@alignCast(base + offset));
}

fn smResetCallsCount(pool: *anyopaque) callconv(.c) void {
    if (smFieldPtr(i32, pool, sm_off.calls_cnt)) |p| p.* = 0;
}
fn smResetBestPreviousScore(pool: *anyopaque) callconv(.c) void {
    if (smFieldPtr(i32, pool, sm_off.best_previous_score)) |p| p.* = 32001; // VALUE_INFINITE
}
fn smResetBestPreviousAverageScore(pool: *anyopaque) callconv(.c) void {
    if (smFieldPtr(i32, pool, sm_off.best_previous_average_score)) |p| p.* = 32001;
}
fn smResetOriginalTimeAdjust(pool: *anyopaque) callconv(.c) void {
    if (smFieldPtr(f64, pool, sm_off.original_time_adjust)) |p| p.* = -1;
}
fn smResetPreviousTimeReduction(pool: *anyopaque) callconv(.c) void {
    if (smFieldPtr(f64, pool, sm_off.previous_time_reduction)) |p| p.* = 0.85;
}
fn smSetPonder(pool: *anyopaque, ponder_mode: u8) callconv(.c) void {
    if (smFieldPtr(u8, pool, sm_off.ponder)) |p| p.* = if (ponder_mode != 0) 1 else 0;
}
fn smSetStopOnPonderhit(pool: *anyopaque, stop_on_ponderhit: u8) callconv(.c) void {
    if (smFieldPtr(u8, pool, sm_off.stop_on_ponderhit)) |p| p.* = if (stop_on_ponderhit != 0) 1 else 0;
}
fn smClearTimeman(pool: *anyopaque) callconv(.c) void {
    // TimeManagement::clear() sets availableNodes = -1; nothing else.
    if (smFieldPtr(i64, pool, sm_off.tm_available_nodes)) |p| p.* = -1;
}

// Native ThreadPool flag shims: stop and increaseDepth are the leading
// std::atomic_bool pair at pool+0 / pool+1. Written directly (single-threaded
// setup context), gated to the default build alongside the manager shims.
fn tpSetStopFlag(pool: *anyopaque, stop: u8) callconv(.c) void {
    const p: *u8 = @ptrCast(@as([*]u8, @ptrCast(pool)) + graph_layout.thread_pool_off.stop);
    p.* = if (stop != 0) 1 else 0;
}
fn tpSetIncreaseDepth(pool: *anyopaque, increase_depth: u8) callconv(.c) void {
    const p: *u8 = @ptrCast(@as([*]u8, @ptrCast(pool)) + graph_layout.thread_pool_off.increase_depth);
    p.* = if (increase_depth != 0) 1 else 0;
}
// Native Thread->worker field reads. thread+8 holds the Worker pointer; read the
// relaxed-atomic u64 counters at the worker's nodes/tbHits offsets. Match
// Thread::worker_nodes_searched()/worker_tb_hits(). Gated to the default build.
fn threadWorker(thread: *const anyopaque) ?[*]const u8 {
    const wp: *const usize = @ptrCast(@alignCast(@as([*]const u8, @ptrCast(thread)) + graph_layout.thread_off.worker));
    if (wp.* == 0) return null;
    return @ptrFromInt(wp.*);
}
fn thNodesSearched(thread: *const anyopaque) callconv(.c) u64 {
    const w = threadWorker(thread) orelse return 0;
    const p: *const u64 = @ptrCast(@alignCast(w + graph_layout.worker_off.nodes));
    return p.*;
}
fn thTbHits(thread: *const anyopaque) callconv(.c) u64 {
    const w = threadWorker(thread) orelse return 0;
    const p: *const u64 = @ptrCast(@alignCast(w + graph_layout.worker_off.tb_hits));
    return p.*;
}

fn tpThreadCount(pool: *anyopaque) callconv(.c) usize {
    const base: [*]const u8 = @ptrCast(pool);
    const begin: *const usize = @ptrCast(@alignCast(base + graph_layout.thread_pool_off.threads_begin));
    const end: *const usize = @ptrCast(@alignCast(base + graph_layout.thread_pool_off.threads_end));
    return (end.* - begin.*) / @sizeOf(usize);
}

// ThreadPool::thread_at(i) == threads[i].get(): the i-th unique_ptr<Thread> in
// the threads vector is a single pointer, so .get() is the loaded slot value.
// begin() is the vector's begin pointer at threads_begin; element stride is the
// 8-byte unique_ptr.
// Mutable Thread -> Worker resolution (LargePagePtr<Worker> at Thread+8).
fn threadWorkerMut(thread: *anyopaque) ?[*]u8 {
    const wp: *const usize = @ptrCast(@alignCast(@as([*]const u8, @ptrCast(thread)) + graph_layout.thread_off.worker));
    if (wp.* == 0) return null;
    return @ptrFromInt(wp.*);
}

// Worker::reset_root_setup_state zeros the five per-search counters. They are POD
// (the two node counters are atomics, but a relaxed store of 0 is a plain zero
// write), so each is set through the worker offset map.
fn thWorkerResetRootSetupState(thread: *anyopaque) callconv(.c) void {
    const w = threadWorkerMut(thread) orelse return;
    @as(*u64, @ptrCast(@alignCast(w + graph_layout.worker_off.nodes))).* = 0;
    @as(*u64, @ptrCast(@alignCast(w + graph_layout.worker_off.tb_hits))).* = 0;
    @as(*u64, @ptrCast(@alignCast(w + graph_layout.worker_off.best_move_changes))).* = 0;
    @as(*i32, @ptrCast(@alignCast(w + graph_layout.worker_off.nmp_min_ply))).* = 0;
    @as(*i32, @ptrCast(@alignCast(w + graph_layout.worker_off.root_depth))).* = 0;
}

// Matches the bridge ZfishTbConfig / thread.zig TbConfig C-ABI struct passed by
// value: {int cardinality; u8 root_in_tb; u8 use_rule50; int probe_depth}.
const WorkerTbConfig = extern struct {
    cardinality: c_int,
    root_in_tb: u8,
    use_rule50: u8,
    probe_depth: c_int,
};

// Worker::set_tb_config assigns worker.tbConfig = Tablebases::Config{...}. The
// Config is POD {int cardinality; bool rootInTB; bool useRule50; Depth(int)
// probeDepth} laid out as cardinality@0, rootInTB@4, useRule50@5, probeDepth@8.
// The bridge normalized the two flags with `!= 0`, so booleans are written 0/1.
// Padding bytes (+6,+7) are never read by the search, so they are left alone.
fn thWorkerSetTbConfig(thread: *anyopaque, config: WorkerTbConfig) callconv(.c) void {
    const w = threadWorkerMut(thread) orelse return;
    const base = w + graph_layout.worker_off.tb_config;
    @as(*c_int, @ptrCast(@alignCast(base + 0))).* = config.cardinality;
    base[4] = @intFromBool(config.root_in_tb != 0);
    base[5] = @intFromBool(config.use_rule50 != 0);
    @as(*c_int, @ptrCast(@alignCast(base + 8))).* = config.probe_depth;
}

// Worker::set_root_state assigns worker.rootState = value. StateInfo is fully POD
// (scalars plus one raw `previous` pointer), so the C++ member-wise copy is a
// byte copy; the native version memcpy's the 192-byte StateInfo into the Worker
// rootState slot.
fn thWorkerSetRootState(thread: *anyopaque, setup_state: *const anyopaque) callconv(.c) void {
    const w = threadWorkerMut(thread) orelse return;
    const dst = w + graph_layout.worker_off.root_state;
    const src: [*]const u8 = @ptrCast(setup_state);
    @memcpy(dst[0..graph_layout.state_info_size], src[0..graph_layout.state_info_size]);
}

// Worker::set_root_position runs rootPos.set(fen, chess960, &rootState). Position
// set is already native (position_port.setPosition, also exported as
// zfish_position_set_method); the dispatcher resolves the in-Worker rootPos and
// rootState by offset and runs it, discarding the error string exactly as the
// C++ set_root_position discards the returned Position&.
fn thWorkerSetRootPosition(
    thread: *anyopaque,
    fen_ptr: [*]const u8,
    fen_len: usize,
    chess960: u8,
) callconv(.c) void {
    const w = threadWorkerMut(thread) orelse return;
    const pos: *anyopaque = @ptrCast(w + graph_layout.worker_off.root_pos);
    const st: *anyopaque = @ptrCast(w + graph_layout.worker_off.root_state);
    _ = position_port.setPosition(
        pos,
        fen_ptr,
        fen_len,
        chess960,
        st,
        graph_layout.position_size,
        graph_layout.state_info_size,
    );
}

fn tpThreadAt(pool: *anyopaque, index: usize) callconv(.c) *anyopaque {
    const base: [*]const u8 = @ptrCast(pool);
    const begin: *const usize = @ptrCast(@alignCast(base + graph_layout.thread_pool_off.threads_begin));
    const slot: *const usize = @ptrFromInt(begin.* + index * @sizeOf(usize));
    return @ptrFromInt(slot.*);
}

comptime {
    if (!target_flags.legacy_target) {
        @export(&smResetCallsCount, .{ .name = "zfish_threadpool_main_manager_reset_calls_count" });
        @export(&smResetBestPreviousScore, .{ .name = "zfish_threadpool_main_manager_reset_best_previous_score" });
        @export(&smResetBestPreviousAverageScore, .{ .name = "zfish_threadpool_main_manager_reset_best_previous_average_score" });
        @export(&smResetOriginalTimeAdjust, .{ .name = "zfish_threadpool_main_manager_reset_original_time_adjust" });
        @export(&smResetPreviousTimeReduction, .{ .name = "zfish_threadpool_main_manager_reset_previous_time_reduction" });
        @export(&smSetPonder, .{ .name = "zfish_threadpool_main_manager_set_ponder" });
        @export(&smSetStopOnPonderhit, .{ .name = "zfish_threadpool_main_manager_set_stop_on_ponderhit" });
        @export(&smClearTimeman, .{ .name = "zfish_threadpool_main_manager_clear_timeman" });
        @export(&tpSetStopFlag, .{ .name = "zfish_threadpool_set_stop_flag" });
        @export(&tpSetIncreaseDepth, .{ .name = "zfish_threadpool_set_increase_depth" });
        @export(&tpThreadCount, .{ .name = "zfish_threadpool_thread_count" });
        @export(&tpThreadAt, .{ .name = "zfish_threadpool_thread_at" });
        @export(&thWorkerResetRootSetupState, .{ .name = "zfish_thread_worker_reset_root_setup_state" });
        @export(&thWorkerSetTbConfig, .{ .name = "zfish_thread_worker_set_tb_config" });
        @export(&thWorkerSetRootState, .{ .name = "zfish_thread_worker_set_root_state" });
        @export(&thWorkerSetRootPosition, .{ .name = "zfish_thread_worker_set_root_position" });
        @export(&thNodesSearched, .{ .name = "zfish_thread_nodes_searched" });
        @export(&thTbHits, .{ .name = "zfish_thread_tb_hits" });
    }
}

// Native Engine member accessors. These return &engine->member; natively they add
// the probed engine_off offset to the engine pointer. Bridge-only symbols (not in
// src/engine.cpp), so they need no per-build gating. network.operator->() (the
// resolved Network*) stays a C++ shim.
const eng_off = graph_layout.engine_off;

fn engMember(engine: *anyopaque, offset: usize) *anyopaque {
    return @ptrCast(@as([*]u8, @ptrCast(engine)) + offset);
}
fn engMemberConst(engine: *const anyopaque, offset: usize) *const anyopaque {
    return @ptrCast(@as([*]const u8, @ptrCast(engine)) + offset);
}

pub export fn zfish_engine_position_ptr(engine: *anyopaque) *anyopaque {
    return engMember(engine, eng_off.pos);
}
pub export fn zfish_engine_options_ptr(engine: *const anyopaque) *const anyopaque {
    return engMemberConst(engine, eng_off.options);
}
pub export fn zfish_engine_numa_context_ptr(engine: *anyopaque) *anyopaque {
    return engMember(engine, eng_off.numa_context);
}
pub export fn zfish_engine_states_slot_ptr(engine: *anyopaque) *anyopaque {
    return engMember(engine, eng_off.states);
}
pub export fn zfish_engine_threads_ptr(engine: *anyopaque) *anyopaque {
    return engMember(engine, eng_off.threads);
}
pub export fn zfish_engine_tt_ptr(engine: *anyopaque) *anyopaque {
    return engMember(engine, eng_off.tt);
}
pub export fn zfish_engine_shared_hists_ptr(engine: *anyopaque) *anyopaque {
    return engMember(engine, eng_off.shared_hists);
}
pub export fn zfish_engine_network_replicated_ptr(engine: *anyopaque) *anyopaque {
    return engMember(engine, eng_off.network);
}
pub export fn zfish_engine_update_context_ptr(engine: *const anyopaque) *const anyopaque {
    return engMemberConst(engine, eng_off.update_context);
}
// UCIEngine::engine is the first member (offset 0): the accessor is the identity.
pub export fn zfish_uci_engine_ptr(uci: *anyopaque) *anyopaque {
    return uci;
}
// ThreadPool::num_threads() == threads.size() (bridge-only symbol, no gating).
pub export fn zfish_threadpool_num_threads(pool: *const anyopaque) usize {
    const base: [*]const u8 = @ptrCast(pool);
    const begin: *const usize = @ptrCast(@alignCast(base + graph_layout.thread_pool_off.threads_begin));
    const end: *const usize = @ptrCast(@alignCast(base + graph_layout.thread_pool_off.threads_end));
    return (end.* - begin.*) / @sizeOf(usize);
}

// Worker -> threads (ThreadPool&) and Worker -> manager (the worker's own
// SearchManager via the unique_ptr) resolvers. Both slots hold a pointer (the
// reference is stored as a pointer; main_manager() is manager.get()), so the
// resolver loads the slot value.
fn workerThreadsPool(worker: *const anyopaque) usize {
    const p: *const usize = @ptrCast(@alignCast(@as([*]const u8, @ptrCast(worker)) + graph_layout.worker_off.threads));
    return p.*;
}
fn workerManager(worker: *const anyopaque) usize {
    const p: *const usize = @ptrCast(@alignCast(@as([*]const u8, @ptrCast(worker)) + graph_layout.worker_off.manager));
    return p.*;
}

// worker->rootMoves[0]: rootMoves is a std::vector<RootMove> whose begin pointer
// is the first element's address.
fn workerRootMove0(worker: *const anyopaque) usize {
    const begin: *const usize = @ptrCast(@alignCast(@as([*]const u8, @ptrCast(worker)) + graph_layout.worker_off.root_moves));
    return begin.*;
}

fn workerRootMoveAt(worker: *const anyopaque, index: usize) usize {
    const begin: *const usize = @ptrCast(@alignCast(@as([*]const u8, @ptrCast(worker)) + graph_layout.worker_off.root_moves));
    return begin.* + index * graph_layout.root_move_size;
}

// zfish_search_emit_info_full: build one "info ..." line natively and print it.
// Always records the node count (as the C++ onUpdateFull lambda did in both
// modes); prints only in interactive mode. The score classification, cp/mate
// formatting, WDL, and PV rendering are all native; the line assembly reuses
// uci_port.formatInfoFull. Bridge-only symbol, no gating.
pub export fn zfish_search_emit_info_full(
    manager: *const anyopaque,
    worker: *const anyopaque,
    move_index: usize,
    depth: c_int,
    sel_depth: c_int,
    multipv: usize,
    v: c_int,
    show_wdl: u8,
    bound_kind: u8,
    nodes: u64,
    tb_hits: u64,
    hashfull: c_int,
    time_ms: u64,
) void {
    _ = manager;
    zfish_set_last_nodes_searched(nodes);
    if (uci_quiet_mode) return;

    const ca = std.heap.c_allocator;
    const root_pos: *const anyopaque = @ptrFromInt(@intFromPtr(worker) + graph_layout.worker_off.root_pos);
    const material = position_port.wdlMaterial(root_pos);
    const chess960 = position_port.isChess960(root_pos);

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
        wdl_c = uci_port.wdl(v, material);
        if (wdl_c) |wc| wdl_text = std.mem.span(wc);
    }
    defer if (wdl_c) |wc| ca.free(std.mem.span(wc));

    // PV string: space-separated UCI moves over rootMoves[move_index].pv.
    const rm = workerRootMoveAt(worker, move_index);
    const pv_addr = rm + graph_layout.root_move_off.pv;
    const pv_len = @as(*const usize, @ptrFromInt(pv_addr + graph_layout.pvmoves_off.length)).*;
    var pv_buf: [4096]u8 = undefined;
    var pv_n: usize = 0;
    var i: usize = 0;
    while (i < pv_len) : (i += 1) {
        if (i != 0) {
            pv_buf[pv_n] = ' ';
            pv_n += 1;
        }
        const m = @as(*const u16, @ptrFromInt(pv_addr + i * 2)).*;
        var mbuf: [5]u8 = undefined;
        const txt = uci_move_port.renderMoveText(&mbuf, m, chess960);
        @memcpy(pv_buf[pv_n..][0..txt.len], txt);
        pv_n += txt.len;
    }

    const nps: usize = if (time_ms != 0) @intCast(nodes * 1000 / time_ms) else 0;
    const line_c = uci_port.formatInfoFull(
        depth,
        sel_depth,
        multipv,
        score_text,
        bound_text,
        wdl_text,
        show_wdl,
        @intCast(nodes),
        nps,
        hashfull,
        @intCast(tb_hits),
        @intCast(time_ms),
        pv_buf[0..pv_n],
    ) orelse return;
    defer ca.free(std.mem.span(line_c));
    const line = std.mem.span(line_c);
    zfish_uci_print_line(line.ptr, line.len);
}

// zfish_ss_set_prev_scores: w->main_manager()->bestPreviousScore =
// b->rootMoves[0].score, and likewise bestPreviousAverageScore. Reads the two
// Value ints from best's first RootMove and stores them in worker's manager
// (bridge-only symbol, no gating).
pub export fn zfish_ss_set_prev_scores(worker: *anyopaque, best: *const anyopaque) void {
    const rm0 = workerRootMove0(best);
    const score: *const i32 = @ptrFromInt(rm0 + graph_layout.root_move_off.score);
    const avg: *const i32 = @ptrFromInt(rm0 + graph_layout.root_move_off.average_score);
    const mgr = workerManager(worker);
    @as(*i32, @ptrFromInt(mgr + graph_layout.search_manager_off.best_previous_score)).* = score.*;
    @as(*i32, @ptrFromInt(mgr + graph_layout.search_manager_off.best_previous_average_score)).* = avg.*;
}

fn workerTT(worker: *const anyopaque) usize {
    const p: *const usize = @ptrCast(@alignCast(@as([*]const u8, @ptrCast(worker)) + graph_layout.worker_off.tt));
    return p.*;
}

// zfish_ss_pv_one_and_ponder: best->rootMoves[0].pv.size() == 1 &&
// best->rootMoves[0].extract_ponder_from_tt(worker->tt, worker->rootPos). The pv
// and length come from best's first RootMove; the TT (table/clusterCount/
// generation8) and rootPos come from worker. extract_ponder mutates pv exactly as
// the C++ does. Bridge-only symbol, no gating.
pub export fn zfish_ss_pv_one_and_ponder(worker: *anyopaque, best: *anyopaque) u8 {
    const rm0 = workerRootMove0(best);
    const pv_addr = rm0 + graph_layout.root_move_off.pv;
    const length: *const usize = @ptrFromInt(pv_addr + graph_layout.pvmoves_off.length);
    if (length.* != 1) return 0;
    const tt = workerTT(worker);
    const cc: *const usize = @ptrFromInt(tt + graph_layout.tt_off.cluster_count);
    const table: *const usize = @ptrFromInt(tt + graph_layout.tt_off.table);
    const gen: *const u8 = @ptrFromInt(tt + graph_layout.tt_off.generation8);
    const pos: usize = @intFromPtr(worker) + graph_layout.worker_off.root_pos;
    return zfish_search_extract_ponder_from_tt(
        @ptrFromInt(pv_addr),
        @ptrFromInt(table.*),
        cc.*,
        gen.*,
        @ptrFromInt(pos),
    );
}

// Native quiet-mode flag, mirrored from the C++ zfish_uci_set_listener_mode. In
// quiet mode (bench/speedtest) the search-driver emit functions are no-ops; in
// interactive mode they format natively and print through the shared sync_cout
// wrapper.
var uci_quiet_mode: bool = false;
pub export fn zfish_uci_set_quiet_mode(quiet: u8) void {
    uci_quiet_mode = quiet != 0;
}

extern fn zfish_uci_print_line(str: [*]const u8, len: usize) callconv(.c) void;

// Allocate the UCI score text for a raw value: classify (VALUE_TB_WIN_IN_MAX_PLY=
// 31507, VALUE_TB=31753, VALUE_MATE=32000), then map to the cp/tb/mate formatter
// exactly as the C++ Score visit. Caller frees via c_allocator.
fn scoreTextAlloc(v: c_int, material: c_int) ?[*:0]u8 {
    const sc = score_port.classify(v, 31507, 31753, 32000);
    return switch (sc.kind) {
        2 => uci_port.formatScore(0, sc.plies, 0),
        1 => uci_port.formatScore(1, sc.plies, sc.win),
        else => uci_port.formatScore(2, uci_port.toCp(v, material), 0),
    };
}

// zfish_ss_emit_no_moves: at a checkmated/stalemated root, print "info depth 0
// score <fmt>" (mate 0 when in check, else cp 0) followed by "bestmove (none)".
// Quiet mode is a no-op. Bridge-only symbol, no gating.
pub export fn zfish_ss_emit_no_moves(worker: *const anyopaque) void {
    if (uci_quiet_mode) return;
    const ca = std.heap.c_allocator;
    const root_pos: *const anyopaque = @ptrFromInt(@intFromPtr(worker) + graph_layout.worker_off.root_pos);
    const v: c_int = if (position_port.hasCheckers(root_pos)) -32000 else 0;
    const material = position_port.wdlMaterial(root_pos);

    const score_c = scoreTextAlloc(v, material) orelse return;
    defer ca.free(std.mem.span(score_c));
    const line_c = uci_port.formatInfoNoMoves(0, std.mem.span(score_c)) orelse return;
    defer ca.free(std.mem.span(line_c));
    const line = std.mem.span(line_c);
    zfish_uci_print_line(line.ptr, line.len);

    const bm = "bestmove (none)";
    zfish_uci_print_line(bm.ptr, bm.len);
}

// zfish_ss_emit_bestmove: in interactive mode prints "bestmove X[ ponder Y]"
// where X = best->rootMoves[0].pv[0] and Y = pv[1] (when pv length > 1), both
// rendered with worker->rootPos chess960. Quiet mode is a no-op, matching the
// C++ no-op onBestmove listener. Bridge-only symbol, no gating.
pub export fn zfish_ss_emit_bestmove(worker: *const anyopaque, best: *const anyopaque) void {
    if (uci_quiet_mode) return;
    const rm0 = workerRootMove0(best);
    const pv_addr = rm0 + graph_layout.root_move_off.pv;
    const length: *const usize = @ptrFromInt(pv_addr + graph_layout.pvmoves_off.length);
    const pv0: *const u16 = @ptrFromInt(pv_addr);
    const root_pos: *const anyopaque = @ptrFromInt(@intFromPtr(worker) + graph_layout.worker_off.root_pos);
    const chess960 = position_port.isChess960(root_pos);

    var buf0: [5]u8 = undefined;
    const bestmove = uci_move_port.renderMoveText(&buf0, pv0.*, chess960);

    var line: [40]u8 = undefined;
    var n: usize = 0;
    @memcpy(line[n..][0..9], "bestmove ");
    n += 9;
    @memcpy(line[n..][0..bestmove.len], bestmove);
    n += bestmove.len;
    if (length.* > 1) {
        const pv1: *const u16 = @ptrFromInt(pv_addr + 2);
        var buf1: [5]u8 = undefined;
        const ponder = uci_move_port.renderMoveText(&buf1, pv1.*, chess960);
        @memcpy(line[n..][0..8], " ponder ");
        n += 8;
        @memcpy(line[n..][0..ponder.len], ponder);
        n += ponder.len;
    }
    zfish_uci_print_line(line[0..n].ptr, n);
}

// zfish_ss_set_stop: worker->threads.stop = true. Plain byte store, matching the
// gate-verified native tpSetStopFlag (bridge-only symbol, no gating).
pub export fn zfish_ss_set_stop(worker: *anyopaque) void {
    const pool = workerThreadsPool(worker);
    const stop: *u8 = @ptrFromInt(pool + graph_layout.thread_pool_off.stop);
    stop.* = 1;
}

// zfish_ss_should_busywait: !threads.stop && (manager->ponder || limits.infinite).
// Resolves the pool stop byte, the worker's manager ponder flag, and the limits
// infinite int by offset (bridge-only symbol, no gating).
pub export fn zfish_ss_should_busywait(worker: *const anyopaque) u8 {
    const pool = workerThreadsPool(worker);
    const stop: *const u8 = @ptrFromInt(pool + graph_layout.thread_pool_off.stop);
    if (stop.* != 0) return 0;
    const mgr = workerManager(worker);
    const ponder: *const u8 = @ptrFromInt(mgr + graph_layout.search_manager_off.ponder);
    const base: [*]const u8 = @ptrCast(worker);
    const infinite: *const c_int = @ptrCast(@alignCast(base + graph_layout.worker_off.limits + graph_layout.limits_off.infinite));
    return if (ponder.* != 0 or infinite.* != 0) 1 else 0;
}

// UCIEngine::cli accessors (bridge-only). cli is a CommandLine {int argc;
// char** argv} at uci_engine_off.cli_argc; arg_at bounds-checks against argc and
// loads the i-th argv pointer, returning null out of range (as the C++ did).
pub export fn zfish_uci_cli_argc(uci: *const anyopaque) c_int {
    const p: *const c_int = @ptrCast(@alignCast(@as([*]const u8, @ptrCast(uci)) + graph_layout.uci_engine_off.cli_argc));
    return p.*;
}
pub export fn zfish_uci_cli_arg_at(uci: *const anyopaque, index: c_int) ?[*:0]const u8 {
    const argc_p: *const c_int = @ptrCast(@alignCast(@as([*]const u8, @ptrCast(uci)) + graph_layout.uci_engine_off.cli_argc));
    if (index < 0 or index >= argc_p.*) return null;
    const argv_p: *const usize = @ptrCast(@alignCast(@as([*]const u8, @ptrCast(uci)) + graph_layout.uci_engine_off.cli_argv));
    const argv: [*]const usize = @ptrFromInt(argv_p.*);
    return @ptrFromInt(argv[@intCast(index)]);
}

// ThreadPool::boundThreadToNumaNode accessors (bridge-only). The member is a
// std::vector<size_t> at bound_nodes_begin; count is the byte span / 8 and
// at(i) loads the i-th element from the begin pointer.
pub export fn zfish_threadpool_bound_node_count(pool: *const anyopaque) usize {
    const base: [*]const u8 = @ptrCast(pool);
    const begin: *const usize = @ptrCast(@alignCast(base + graph_layout.thread_pool_off.bound_nodes_begin));
    const end: *const usize = @ptrCast(@alignCast(base + graph_layout.thread_pool_off.bound_nodes_end));
    return (end.* - begin.*) / @sizeOf(usize);
}
pub export fn zfish_threadpool_bound_node_at(pool: *const anyopaque, index: usize) usize {
    const base: [*]const u8 = @ptrCast(pool);
    const begin: *const usize = @ptrCast(@alignCast(base + graph_layout.thread_pool_off.bound_nodes_begin));
    const slot: *const usize = @ptrFromInt(begin.* + index * @sizeOf(usize));
    return slot.*;
}

// NumaConfig::num_numa_nodes() == nodes.size() (bridge-only symbol, no gating).
// nodes is a std::vector<std::set<CpuIndex>> at offset 0; size is the byte span
// divided by the 48-byte std::set element.
pub export fn zfish_numa_config_node_count(numa_config: *const anyopaque) usize {
    const base: [*]const u8 = @ptrCast(numa_config);
    const begin: *const usize = @ptrCast(@alignCast(base + graph_layout.numa_config_off.nodes_begin));
    const end: *const usize = @ptrCast(@alignCast(base + graph_layout.numa_config_off.nodes_end));
    return (end.* - begin.*) / graph_layout.numa_config_off.node_set_size;
}

// NumaReplicationContext::get_numa_config().num_numa_nodes(). config is the first
// member of NumaReplicationContext (the class has no virtual functions, so no
// vtable), so the context pointer is the NumaConfig pointer and this delegates to
// the node-count logic above (bridge-only symbol, no gating).
pub export fn zfish_numa_context_node_count(numa_context: *const anyopaque) usize {
    return zfish_numa_config_node_count(numa_context);
}

// NumaReplicationContext::get_numa_config().num_cpus_in_numa_node(node) ==
// nodes[node].size(). config is at context offset 0, so nodes begins at the
// context pointer; the node-th std::set is at begin + node*48, and its element
// count is stored at +40 within the set (bridge-only symbol, no gating).
pub export fn zfish_numa_context_cpus_in_node(numa_context: *const anyopaque, node: usize) usize {
    const base: [*]const u8 = @ptrCast(numa_context);
    const begin: *const usize = @ptrCast(@alignCast(base + graph_layout.numa_config_off.nodes_begin));
    const set_addr = begin.* + node * graph_layout.numa_config_off.node_set_size;
    const count: *const usize = @ptrFromInt(set_addr + graph_layout.numa_config_off.node_set_count_off);
    return count.*;
}

pub export fn zfish_engine_init_body(engine: *anyopaque) void {
    return engine_port.initBody(engine);
}

pub export fn zfish_engine_option_on_change(
    engine: *anyopaque,
    callback_kind: u8,
    value_ptr: [*]const u8,
    value_len: usize,
    int_value: c_int,
) ?[*:0]u8 {
    return engine_port.optionOnChange(engine, callback_kind, value_ptr, value_len, int_value);
}

pub export fn zfish_engine_release_pending_state_slot(states_slot: *anyopaque) void {
    return engine_port.releasePendingStateSlot(states_slot);
}

pub export fn zfish_engine_eval_trace(
    pos: *anyopaque,
    network: *const anyopaque,
) ?[*:0]u8 {
    return engine_port.evalTrace(pos, network);
}

pub export fn zfish_engine_fen(pos: *const anyopaque) ?[*:0]u8 {
    return engine_port.fen(pos);
}

pub export fn zfish_engine_fen_owner(engine_ptr: *const anyopaque) ?[*:0]u8 {
    return engine_port.fenEngine(engine_ptr);
}

pub export fn zfish_engine_hashfull_owner(engine_ptr: *const anyopaque, max_age: c_int) c_int {
    return engine_port.hashfullEngine(engine_ptr, max_age);
}

pub export fn zfish_engine_visualize(pos: *const anyopaque) ?[*:0]u8 {
    return engine_port.visualize(pos);
}

pub export fn zfish_engine_visualize_owner(engine_ptr: *const anyopaque) ?[*:0]u8 {
    return engine_port.visualizeEngine(engine_ptr);
}

pub export fn zfish_engine_verify_network_method(engine_ptr: *const anyopaque) void {
    return engine_port.verifyNetwork(engine_ptr);
}

pub export fn zfish_engine_search_clear_owner(engine_ptr: *anyopaque) void {
    return engine_port.searchClearEngine(engine_ptr);
}

pub export fn zfish_engine_set_position_owner(
    engine_ptr: *anyopaque,
    fen_ptr: [*]const u8,
    fen_len: usize,
    moves_ptr: ?[*]const engine_port.ByteView,
    move_count: usize,
) ?[*:0]u8 {
    return engine_port.setPositionEngine(engine_ptr, fen_ptr, fen_len, moves_ptr, move_count);
}

pub export fn zfish_engine_go_owner(engine_ptr: *anyopaque, limits_ptr: *const anyopaque) void {
    return engine_port.goEngine(engine_ptr, limits_ptr);
}

pub export fn zfish_engine_stop_owner(engine_ptr: *anyopaque) void {
    return engine_port.stopEngine(engine_ptr);
}

pub export fn zfish_engine_wait_for_search_finished_owner(engine_ptr: *anyopaque) void {
    return engine_port.waitForSearchFinishedEngine(engine_ptr);
}

pub export fn zfish_engine_set_numa_config_from_option_owner(
    engine_ptr: *anyopaque,
    value_ptr: [*]const u8,
    value_len: usize,
) void {
    return engine_port.setNumaConfigFromOptionEngine(engine_ptr, value_ptr[0..value_len]);
}

pub export fn zfish_engine_resize_threads_owner(engine_ptr: *anyopaque) void {
    return engine_port.resizeThreadsEngine(engine_ptr);
}

pub export fn zfish_engine_set_tt_size_owner(engine_ptr: *anyopaque, mb: usize) void {
    return engine_port.setTtSizeEngine(engine_ptr, mb);
}

pub export fn zfish_engine_set_ponderhit_owner(engine_ptr: *anyopaque, ponder: u8) void {
    return engine_port.setPonderhitEngine(engine_ptr, ponder);
}

pub export fn zfish_engine_trace_eval_owner(engine_ptr: *anyopaque) ?[*:0]u8 {
    return engine_port.traceEvalEngine(engine_ptr);
}

pub export fn zfish_engine_numa_config_string_owner(engine_ptr: *const anyopaque) ?[*:0]u8 {
    return engine_port.numaConfigStringEngine(engine_ptr);
}

pub export fn zfish_engine_numa_config_information_owner(
    engine_ptr: *const anyopaque,
) ?[*:0]u8 {
    return engine_port.numaConfigInformationEngine(engine_ptr);
}

pub export fn zfish_engine_thread_binding_information_owner(
    engine_ptr: *const anyopaque,
) ?[*:0]u8 {
    return engine_port.threadBindingInformationEngine(engine_ptr);
}

pub export fn zfish_engine_thread_allocation_information_owner(
    engine_ptr: *const anyopaque,
) ?[*:0]u8 {
    return engine_port.threadAllocationInformationEngine(engine_ptr);
}

pub export fn zfish_engine_load_network_owner(
    engine_ptr: *anyopaque,
    file_ptr: [*]const u8,
    file_len: usize,
) void {
    return engine_port.loadNetworkEngine(engine_ptr, file_ptr[0..file_len]);
}

pub export fn zfish_engine_save_network_owner(
    engine_ptr: *anyopaque,
    has_filename: u8,
    filename_ptr: [*]const u8,
    filename_len: usize,
) void {
    return engine_port.saveNetworkEngine(
        engine_ptr,
        if (has_filename != 0) filename_ptr[0..filename_len] else null,
    );
}

pub export fn zfish_accumulator_evaluate(
    stack: *anyopaque,
    pos: *const anyopaque,
    feature_transformer: *const anyopaque,
    cache: *anyopaque,
) void {
    return nnue_accumulator_port.evaluate(stack, pos, feature_transformer, cache);
}

pub export fn zfish_accumulator_stack_latest_psq(stack: *const anyopaque) *const anyopaque {
    return nnue_accumulator_port.stackLatestPsq(stack);
}

pub export fn zfish_accumulator_stack_latest_threat(stack: *const anyopaque) *const anyopaque {
    return nnue_accumulator_port.stackLatestThreat(stack);
}

pub export fn zfish_accumulator_stack_mut_latest_psq(stack: *anyopaque) *anyopaque {
    return nnue_accumulator_port.stackMutLatestPsq(stack);
}

pub export fn zfish_accumulator_stack_mut_latest_threat(stack: *anyopaque) *anyopaque {
    return nnue_accumulator_port.stackMutLatestThreat(stack);
}

pub export fn zfish_accumulator_stack_psq_array(stack: *const anyopaque) *const anyopaque {
    return nnue_accumulator_port.stackPsqArray(stack);
}

pub export fn zfish_accumulator_stack_threat_array(stack: *const anyopaque) *const anyopaque {
    return nnue_accumulator_port.stackThreatArray(stack);
}

pub export fn zfish_accumulator_stack_mut_psq_array(stack: *anyopaque) *anyopaque {
    return nnue_accumulator_port.stackMutPsqArray(stack);
}

pub export fn zfish_accumulator_stack_mut_threat_array(stack: *anyopaque) *anyopaque {
    return nnue_accumulator_port.stackMutThreatArray(stack);
}

pub export fn zfish_accumulator_stack_reset(stack: *anyopaque) void {
    return nnue_accumulator_port.stackReset(stack);
}

pub export fn zfish_accumulator_stack_push(stack: *anyopaque) nnue_accumulator_port.StackPushOutput {
    return nnue_accumulator_port.stackPush(stack);
}

pub export fn zfish_accumulator_stack_pop(stack: *anyopaque) void {
    return nnue_accumulator_port.stackPop(stack);
}

pub export fn zfish_accumulator_position_snapshot(pos: *const anyopaque, pieces_out: [*]u8) void {
    var snapshot = std.mem.zeroes(PositionSnapshot);
    position_port.fillSnapshot(pos, &snapshot);
    @memcpy(pieces_out[0..64], snapshot.board[0..]);
}

const AccumulatorStackPushPair = extern struct {
    first: *anyopaque,
    second: *anyopaque,
};

pub export fn _ZN9Stockfish4Eval4NNUE16AccumulatorStack5resetEv(stack: *anyopaque) void {
    return nnue_accumulator_port.stackReset(stack);
}

pub export fn _ZN9Stockfish4Eval4NNUE16AccumulatorStack4pushEv(
    stack: *anyopaque,
) AccumulatorStackPushPair {
    const pushed = nnue_accumulator_port.stackPush(stack);
    return .{
        .first = pushed.dirty_piece,
        .second = pushed.dirty_threats,
    };
}

pub export fn _ZN9Stockfish4Eval4NNUE16AccumulatorStack3popEv(stack: *anyopaque) void {
    return nnue_accumulator_port.stackPop(stack);
}

pub export fn _ZNK9Stockfish4Eval4NNUE16AccumulatorStack6latestINS1_8Features11HalfKAv2_hmEEERKNS1_16AccumulatorStateIT_EEv(
    stack: *const anyopaque,
) *const anyopaque {
    return nnue_accumulator_port.stackLatestPsq(stack);
}

pub export fn _ZNK9Stockfish4Eval4NNUE16AccumulatorStack6latestINS1_8Features11FullThreatsEEERKNS1_16AccumulatorStateIT_EEv(
    stack: *const anyopaque,
) *const anyopaque {
    return nnue_accumulator_port.stackLatestThreat(stack);
}

pub export fn zfish_network_load(
    network: *anyopaque,
    root_directory_ptr: [*]const u8,
    root_directory_len: usize,
    evalfile_path_ptr: [*]const u8,
    evalfile_path_len: usize,
) void {
    network_port.load(
        network,
        root_directory_ptr,
        root_directory_len,
        evalfile_path_ptr,
        evalfile_path_len,
    );
    // The native parse (network.zig) writes the weights straight into the
    // Zig-owned storage below as it reads the file -- no copy-out step.
}

pub export fn zfish_network_save(
    network: *const anyopaque,
    has_filename: u8,
    filename_ptr: [*]const u8,
    filename_len: usize,
) network_port.SaveResult {
    return network_port.save(network, has_filename, filename_ptr, filename_len);
}

pub export fn zfish_network_verify(
    network: *const anyopaque,
    evalfile_path_ptr: [*]const u8,
    evalfile_path_len: usize,
) network_port.VerifyResult {
    return network_port.verify(network, evalfile_path_ptr, evalfile_path_len);
}

pub export fn zfish_network_evaluate(
    network: *const anyopaque,
    pos: *const anyopaque,
    accumulator_stack: *anyopaque,
    cache: *anyopaque,
) network_port.EvalOutput {
    return network_port.evaluate(network, pos, accumulator_stack, cache);
}

// NNUE feature-transformer forward pass, ported to Zig. Replaces the C++
// FeatureTransformer::transform shim: gets the FeatureTransformer pointer from
// the network (bridge helper) and the side to move from the Position mirror,
// then runs the Zig transform. Same symbol the network.zig forward path calls.
extern fn zfish_network_feature_transformer_ptr(network: *const anyopaque) *const anyopaque;

// Native-owned feature-transformer storage. The native .nnue parse (network.zig)
// writes the SIMD-permuted ~106 MB of weights straight into this Zig-owned buffer
// as it reads the file, and inference reads from here -- the C++ FeatureTransformer
// is no longer the source, only a load-time cross-check. zfish_native_ft_storage
// hands network.zig the (re)allocated destination on demand.
var native_ft_ptr: ?*anyopaque = null;
var native_ft_len: usize = 0;

pub export fn zfish_native_ft_storage(n: usize) ?[*]u8 {
    if (n == 0) return null;
    if (native_ft_ptr != null and native_ft_len != n) {
        memory_port.alignedLargePagesFree(native_ft_ptr);
        native_ft_ptr = null;
    }
    if (native_ft_ptr == null) {
        native_ft_ptr = memory_port.alignedLargePagesAlloc(n) orelse return null;
        native_ft_len = n;
    }
    return @ptrCast(native_ft_ptr.?);
}

pub export fn zfish_native_ft_ptr() ?*const anyopaque {
    return native_ft_ptr;
}

// Native-owned per-bucket affine-layer storage. Same model as the feature
// transformer: the native layer parse writes weights/biases directly here and
// inference serves from it. zfish_native_layer_storage allocates the slot.
const layer_stacks_n = 8;
const layers_per_stack = 3;

var native_layer_w: [layer_stacks_n][layers_per_stack]?*anyopaque =
    .{.{ null, null, null }} ** layer_stacks_n;
var native_layer_b: [layer_stacks_n][layers_per_stack]?*anyopaque =
    .{.{ null, null, null }} ** layer_stacks_n;

pub export fn zfish_native_layer_storage(bucket: usize, idx: c_int, is_weights: c_int, n: usize) ?[*]u8 {
    if (bucket >= layer_stacks_n or idx < 0 or idx >= layers_per_stack or n == 0) return null;
    const ui: usize = @intCast(idx);
    const slot = if (is_weights != 0) &native_layer_w[bucket][ui] else &native_layer_b[bucket][ui];
    if (slot.* == null) slot.* = memory_port.alignedLargePagesAlloc(n) orelse return null;
    return @ptrCast(slot.*.?);
}

pub export fn zfish_native_layer_ptr(bucket: usize, idx: c_int, is_weights: c_int) ?*const anyopaque {
    if (bucket >= layer_stacks_n or idx < 0 or idx >= layers_per_stack) return null;
    const ui: usize = @intCast(idx);
    return if (is_weights != 0) native_layer_w[bucket][ui] else native_layer_b[bucket][ui];
}

pub export fn zfish_network_transform_bucket(
    network: *const anyopaque,
    pos: *const anyopaque,
    accumulator_stack: *anyopaque,
    cache: *anyopaque,
    bucket: usize,
    transformed_ptr: [*]u8,
) c_int {
    const ft = native_ft_ptr orelse zfish_network_feature_transformer_ptr(network);
    const stm = position_port.sideToMove(pos);
    return nnue_accumulator_port.transformBucket(accumulator_stack, pos, ft, cache, bucket, stm, transformed_ptr);
}

pub export fn zfish_network_trace_evaluate(
    network: *const anyopaque,
    pos: *const anyopaque,
    accumulator_stack: *anyopaque,
    cache: *anyopaque,
) network_port.TraceOutput {
    return network_port.traceEvaluate(network, pos, accumulator_stack, cache);
}

pub export fn zfish_network_content_hash(network: *const anyopaque) usize {
    return network_port.contentHash(network);
}

pub export fn zfish_tt_entry_save(
    entry: *tt_port.TtEntry,
    key: u64,
    value: c_int,
    pv: u8,
    bound: u8,
    depth: c_int,
    depth_none: c_int,
    move16: u16,
    eval: c_int,
    curr_generation: u8,
) void {
    tt_port.entrySave(entry, key, value, pv, bound, depth, depth_none, move16, eval, curr_generation);
}

pub export fn zfish_tt_entry_read(
    entry: *const tt_port.TtEntry,
    depth_none: c_int,
) tt_port.TtReadOutput {
    return tt_port.entryRead(entry, depth_none);
}

pub export fn zfish_tt_entry_relative_age(
    entry: *const tt_port.TtEntry,
    curr_generation: u8,
) u8 {
    return tt_port.entryRelativeAge(entry, curr_generation);
}

pub export fn zfish_tt_generation_next(curr_generation: u8) u8 {
    return tt_port.generationNext(curr_generation);
}

pub export fn zfish_tt_hashfull(
    clusters: [*]const tt_port.TtCluster,
    cluster_count: usize,
    generation: u8,
    max_age: c_int,
) c_int {
    return tt_port.hashfull(clusters, cluster_count, generation, max_age);
}

pub export fn zfish_tt_first_entry_index(key: u64, cluster_count: usize) usize {
    return tt_port.firstEntryIndex(key, cluster_count);
}

pub export fn zfish_tt_probe(
    cluster: *const tt_port.TtCluster,
    key: u64,
    generation: u8,
    depth_none: c_int,
) tt_port.TtProbeOutput {
    return tt_port.probe(cluster, key, generation, depth_none);
}

pub export fn zfish_tt_probe_table(
    table: ?*anyopaque,
    cluster_count: usize,
    key: u64,
    generation: u8,
    depth_none: c_int,
) tt_port.TtProbeTableOutput {
    return tt_port.probeTable(table, cluster_count, key, generation, depth_none);
}

pub export fn zfish_tt_resize_state(
    table_ptr: *?*anyopaque,
    cluster_count_ptr: *usize,
    generation_ptr: *u8,
    mb: usize,
    threads: *anyopaque,
) void {
    return tt_port.resizeState(table_ptr, cluster_count_ptr, generation_ptr, mb, threads);
}

pub export fn zfish_tt_clear_state(
    table: ?*anyopaque,
    cluster_count: usize,
    generation_ptr: *u8,
    threads: *anyopaque,
) void {
    return tt_port.clearState(table, cluster_count, generation_ptr, threads);
}

pub export fn zfish_option_case_insensitive_less(
    left_ptr: [*]const u8,
    left_len: usize,
    right_ptr: [*]const u8,
    right_len: usize,
) bool {
    return option_port.caseInsensitiveLess(left_ptr[0..left_len], right_ptr[0..right_len]);
}

pub export fn zfish_option_parse_setoption(
    input_ptr: [*]const u8,
    input_len: usize,
) option_port.ParsedSetOption {
    return option_port.parseSetOption(input_ptr[0..input_len]);
}

pub export fn zfish_option_combo_equals(
    current_ptr: [*]const u8,
    current_len: usize,
    query_ptr: [*]const u8,
    query_len: usize,
) bool {
    return option_port.comboEquals(current_ptr[0..current_len], query_ptr[0..query_len]);
}

pub export fn zfish_option_validate_assignment(
    type_ptr: [*]const u8,
    type_len: usize,
    value_ptr: [*]const u8,
    value_len: usize,
    min_value: c_int,
    max_value: c_int,
    default_ptr: [*]const u8,
    default_len: usize,
) option_port.AssignmentResult {
    return option_port.validateAssignment(
        type_ptr[0..type_len],
        value_ptr[0..value_len],
        min_value,
        max_value,
        default_ptr[0..default_len],
    );
}

pub export fn zfish_tune_next(
    names_ptr: [*]const u8,
    names_len: usize,
    pop: u8,
) option_port.TuneNextResult {
    return option_port.tuneNext(names_ptr[0..names_len], pop);
}

pub export fn zfish_tune_should_make_option(min_value: c_int, max_value: c_int) bool {
    return option_port.tuneShouldMakeOption(min_value, max_value);
}

pub export fn zfish_uci_parse_limits(
    input_ptr: [*]const u8,
    input_len: usize,
) uci_port.ParsedLimits {
    return uci_port.parseLimits(input_ptr[0..input_len]);
}

pub export fn zfish_uci_parse_position(
    input_ptr: [*]const u8,
    input_len: usize,
) uci_port.ParsedPosition {
    return uci_port.parsePosition(input_ptr[0..input_len]);
}

pub export fn zfish_uci_format_info_string(
    input_ptr: [*]const u8,
    input_len: usize,
) ?[*:0]u8 {
    return uci_port.formatInfoString(input_ptr[0..input_len]);
}

pub export fn zfish_uci_format_score(kind: u8, value: c_int, extra: c_int) ?[*:0]u8 {
    return uci_port.formatScore(kind, value, extra);
}

pub export fn zfish_uci_to_cp(value: c_int, material: c_int) c_int {
    return uci_port.toCp(value, material);
}

pub export fn zfish_uci_wdl(value: c_int, material: c_int) ?[*:0]u8 {
    return uci_port.wdl(value, material);
}

pub export fn zfish_uci_format_square(file: u8, rank: u8) ?[*:0]u8 {
    return uci_port.formatSquare(file, rank);
}

pub export fn zfish_uci_format_move(
    from_file: u8,
    from_rank: u8,
    to_file: u8,
    to_rank: u8,
    promotion: u8,
) ?[*:0]u8 {
    return uci_port.formatMove(from_file, from_rank, to_file, to_rank, promotion);
}

pub export fn zfish_uci_to_lower(
    input_ptr: [*]const u8,
    input_len: usize,
) ?[*:0]u8 {
    return uci_port.toLower(input_ptr[0..input_len]);
}

pub export fn zfish_uci_format_info_no_moves(
    depth: c_int,
    score_ptr: [*]const u8,
    score_len: usize,
) ?[*:0]u8 {
    return uci_port.formatInfoNoMoves(depth, score_ptr[0..score_len]);
}

pub export fn zfish_uci_format_info_full(
    depth: c_int,
    sel_depth: c_int,
    multi_pv: usize,
    score_ptr: [*]const u8,
    score_len: usize,
    bound_ptr: [*]const u8,
    bound_len: usize,
    wdl_ptr: [*]const u8,
    wdl_len: usize,
    show_wdl: u8,
    nodes: usize,
    nps: usize,
    hashfull: c_int,
    tb_hits: usize,
    time_ms: usize,
    pv_ptr: [*]const u8,
    pv_len: usize,
) ?[*:0]u8 {
    return uci_port.formatInfoFull(
        depth,
        sel_depth,
        multi_pv,
        score_ptr[0..score_len],
        bound_ptr[0..bound_len],
        wdl_ptr[0..wdl_len],
        show_wdl,
        nodes,
        nps,
        hashfull,
        tb_hits,
        time_ms,
        pv_ptr[0..pv_len],
    );
}

pub export fn zfish_uci_format_info_iter(
    depth: c_int,
    currmove_ptr: [*]const u8,
    currmove_len: usize,
    currmove_number: c_int,
) ?[*:0]u8 {
    return uci_port.formatInfoIter(depth, currmove_ptr[0..currmove_len], currmove_number);
}

pub export fn zfish_uci_format_bestmove(
    bestmove_ptr: [*]const u8,
    bestmove_len: usize,
    ponder_ptr: [*]const u8,
    ponder_len: usize,
) ?[*:0]u8 {
    return uci_port.formatBestmove(
        bestmove_ptr[0..bestmove_len],
        ponder_ptr[0..ponder_len],
    );
}

pub export fn zfish_uci_help_text() ?[*:0]u8 {
    return uci_port.helpText();
}

pub export fn zfish_uci_format_unknown_command(
    command_ptr: [*]const u8,
    command_len: usize,
) ?[*:0]u8 {
    return uci_port.formatUnknownCommand(command_ptr[0..command_len]);
}

pub export fn zfish_uci_format_critical_error(
    command_ptr: [*]const u8,
    command_len: usize,
    message_ptr: [*]const u8,
    message_len: usize,
) ?[*:0]u8 {
    return uci_port.formatCriticalError(command_ptr[0..command_len], message_ptr[0..message_len]);
}

pub export fn zfish_bitboard_init(
    popcnt16: *[1 << 16]u8,
    square_distance: *[64][64]u8,
    line_bb: *[64][64]u64,
    between_bb: *[64][64]u64,
    ray_pass_bb: *[64][64]u64,
    magics: *[64][2]bitboard_port.Magic,
    rook_table: [*]u64,
    bishop_table: [*]u64,
) void {
    return bitboard_port.init(
        popcnt16,
        square_distance,
        line_bb,
        between_bb,
        ray_pass_bb,
        magics,
        rook_table,
        bishop_table,
    );
}

pub export fn zfish_bitboard_pretty(bitboard: u64) ?[*:0]u8 {
    return bitboard_port.pretty(bitboard);
}

pub export fn zfish_half_ka_make_index(
    params: nnue_feature_port.HalfThreatParams,
) u32 {
    return nnue_feature_port.halfMakeIndex(params);
}

pub export fn zfish_half_ka_append_changed(
    perspective: u8,
    king_square: u8,
    diff: nnue_feature_port.HalfDiff,
) nnue_feature_port.HalfAppendResult {
    return nnue_feature_port.halfAppendChanged(perspective, king_square, diff);
}

pub export fn zfish_half_ka_requires_refresh(
    diff: nnue_feature_port.HalfDiff,
    perspective: u8,
) bool {
    return nnue_feature_port.halfRequiresRefresh(diff, perspective);
}

pub export fn zfish_full_threats_make_index(
    params: nnue_feature_port.FullThreatParams,
) u32 {
    return nnue_feature_port.fullMakeIndex(params);
}

pub export fn zfish_full_threats_append_changed(
    perspective: u8,
    king_square: u8,
    list_ptr: [*]const nnue_feature_port.DirtyThreatRaw,
    list_len: usize,
) nnue_feature_port.FullAppendResult {
    return nnue_feature_port.fullAppendChanged(perspective, king_square, list_ptr, list_len);
}

pub export fn zfish_full_threats_append_active(
    perspective: u8,
    king_square: u8,
    piece_array: [*]const u8,
) nnue_feature_port.FullAppendResult {
    return nnue_feature_port.fullAppendActive(perspective, king_square, piece_array);
}

pub export fn zfish_full_threats_requires_refresh(
    diff: nnue_feature_port.FullDiff,
    perspective: u8,
) bool {
    return nnue_feature_port.fullRequiresRefresh(diff, perspective);
}

pub export fn zfish_aligned_large_pages_alloc(alloc_size: usize) ?*anyopaque {
    return memory_port.alignedLargePagesAlloc(alloc_size);
}

pub export fn _ZN9Stockfish25aligned_large_pages_allocEm(alloc_size: usize) ?*anyopaque {
    return memory_port.alignedLargePagesAlloc(alloc_size);
}

pub export fn zfish_aligned_large_pages_free(ptr: ?*anyopaque) void {
    memory_port.alignedLargePagesFree(ptr);
}

pub export fn _ZN9Stockfish24aligned_large_pages_freeEPv(ptr: ?*anyopaque) void {
    memory_port.alignedLargePagesFree(ptr);
}

pub export fn zfish_has_large_pages() bool {
    return memory_port.hasLargePages();
}

// Last-reported "nodes searched" counter for the UCI info path. Owned in Zig;
// the C++ engine update listeners publish into it via zfish_set_last_nodes_searched.
var last_nodes_searched = std.atomic.Value(u64).init(0);

pub export fn zfish_set_last_nodes_searched(nodes: u64) void {
    last_nodes_searched.store(nodes, .monotonic);
}

pub export fn zfish_uci_engine_nodes_searched(_: ?*const anyopaque) u64 {
    return last_nodes_searched.load(.monotonic);
}

pub export fn zfish_uci_engine_reset_nodes_searched() void {
    last_nodes_searched.store(0, .monotonic);
}

pub export fn _ZN9Stockfish15has_large_pagesEv() bool {
    return memory_port.hasLargePages();
}

pub export fn zfish_classify_score(
    value: c_int,
    value_tb_win_in_max_ply: c_int,
    value_tb: c_int,
    value_mate: c_int,
) score_port.ScoreClass {
    return score_port.classify(value, value_tb_win_in_max_ply, value_tb, value_mate);
}

pub export fn zfish_timeman_init(
    input: timeman_port.TimemanInput,
) timeman_port.TimemanOutput {
    return timeman_port.init(input);
}

pub export fn zfish_eval_compute_value(
    input: evaluate_port.EvalInput,
) c_int {
    return evaluate_port.computeValue(input);
}

pub export fn zfish_eval_format_trace(
    input: evaluate_port.EvalTraceInput,
) ?[*:0]u8 {
    return evaluate_port.formatTrace(input);
}

pub export fn zfish_nnue_format_trace(
    input: nnue_misc_port.NnueTraceInput,
) ?[*:0]u8 {
    return nnue_misc_port.formatTrace(input);
}

pub export fn zfish_benchmark_setup_bench(
    current_fen_ptr: [*]const u8,
    current_fen_len: usize,
    args_ptr: [*]const u8,
    args_len: usize,
) ?[*:0]u8 {
    return benchmark_port.setupBench(
        current_fen_ptr[0..current_fen_len],
        args_ptr[0..args_len],
    );
}

pub export fn zfish_benchmark_setup_benchmark(
    args_ptr: [*]const u8,
    args_len: usize,
    hardware_concurrency: c_int,
) benchmark_port.BenchmarkSetupOutput {
    return benchmark_port.setupBenchmark(args_ptr[0..args_len], hardware_concurrency);
}
