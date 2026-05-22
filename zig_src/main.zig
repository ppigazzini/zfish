const std = @import("std");
const c = @cImport({
    @cInclude("stdlib.h");
    @cInclude("stdio.h");
});

const benchmark_port = @import("benchmark");
const bitboard_port = @import("bitboard");
const engine_port = @import("engine");
const memory_port = @import("memory.zig");
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
const tbprobe_port = @import("tbprobe");
const thread_port = @import("thread");
const evaluate_port = @import("evaluate");
const nnue_misc_port = @import("nnue_misc");
const timeman_port = @import("timeman");
const tt_port = @import("tt");
const uci_port = @import("uci");

extern fn zfish_bitboards_init() void;
extern fn zfish_position_init_runtime() void;
extern fn zfish_uci_create_engine(argc: c_int, argv: [*]const [*:0]u8) ?*anyopaque;
extern fn zfish_uci_loop_engine(engine: *anyopaque) void;
extern fn zfish_uci_destroy_engine(engine: ?*anyopaque) void;
const PositionSnapshot = extern struct {
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
extern fn zfish_position_fill_snapshot(pos_ptr: *const anyopaque, out: *PositionSnapshot) void;

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
    zfish_position_init_runtime();

    const engine = zfish_uci_create_engine(@intCast(argc), argv.ptr) orelse return error.OutOfMemory;
    defer zfish_uci_destroy_engine(engine);

    zfish_uci_loop_engine(engine);
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

pub export fn zfish_tbprobe_build_code(
    piece_types_ptr: [*]const u8,
    piece_count: usize,
) ?[*:0]u8 {
    return tbprobe_port.buildCode(piece_types_ptr, piece_count);
}

pub export fn zfish_tbprobe_add_tables(
    tables: *anyopaque,
    piece_types_ptr: [*]const u8,
    piece_count: usize,
) void {
    return tbprobe_port.addTables(tables, piece_types_ptr, piece_count);
}

pub export fn zfish_tbprobe_dtz_before_zeroing(wdl: c_int) c_int {
    return tbprobe_port.dtzBeforeZeroing(wdl);
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

pub export fn zfish_engine_format_numa_info(
    config_ptr: [*]const u8,
    config_len: usize,
) ?[*:0]u8 {
    return engine_port.formatNumaInfo(config_ptr, config_len);
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

pub export fn zfish_engine_set_position(
    pos: *anyopaque,
    states: *anyopaque,
    chess960_enabled: u8,
    fen_ptr: [*]const u8,
    fen_len: usize,
    moves_ptr: ?[*]const engine_port.ByteView,
    move_count: usize,
) ?[*:0]u8 {
    return engine_port.setPosition(pos, states, chess960_enabled, fen_ptr, fen_len, moves_ptr, move_count);
}

pub export fn zfish_engine_release_pending_state_slot(states_slot: *anyopaque) void {
    return engine_port.releasePendingStateSlot(states_slot);
}

pub export fn zfish_engine_stop(threads: *anyopaque) void {
    return engine_port.stop(threads);
}

pub export fn zfish_engine_set_numa_config_from_option(
    numa_context: *anyopaque,
    options: *const anyopaque,
    threads: *anyopaque,
    tt: *anyopaque,
    shared_hists: *anyopaque,
    network: *anyopaque,
    update_context: *const anyopaque,
    option_ptr: [*]const u8,
    option_len: usize,
) void {
    return engine_port.setNumaConfigFromOption(
        numa_context,
        options,
        threads,
        tt,
        shared_hists,
        network,
        update_context,
        option_ptr[0..option_len],
    );
}

pub export fn zfish_engine_resize_threads(
    numa_context: *const anyopaque,
    options: *const anyopaque,
    threads: *anyopaque,
    tt: *anyopaque,
    shared_hists: *anyopaque,
    network: *anyopaque,
    update_context: *const anyopaque,
) void {
    return engine_port.resizeThreads(numa_context, options, threads, tt, shared_hists, network, update_context);
}

pub export fn zfish_engine_set_tt_size(
    threads: *anyopaque,
    tt: *anyopaque,
    mb: usize,
) void {
    return engine_port.setTtSize(threads, tt, mb);
}

pub export fn zfish_engine_set_ponderhit(threads: *anyopaque, ponder: u8) void {
    return engine_port.setPonderhit(threads, ponder);
}

pub export fn zfish_engine_search_clear(
    threads: *anyopaque,
    tt: *anyopaque,
    syzygy_path_ptr: [*]const u8,
    syzygy_path_len: usize,
) void {
    return engine_port.searchClear(threads, tt, syzygy_path_ptr[0..syzygy_path_len]);
}

pub export fn zfish_engine_load_network(
    threads: *anyopaque,
    network: *anyopaque,
    root_directory_ptr: [*]const u8,
    root_directory_len: usize,
    evalfile_path_ptr: [*]const u8,
    evalfile_path_len: usize,
) void {
    return engine_port.loadNetwork(
        threads,
        network,
        root_directory_ptr[0..root_directory_len],
        evalfile_path_ptr[0..evalfile_path_len],
    );
}

pub export fn zfish_engine_save_network(
    network: *anyopaque,
    has_filename: u8,
    filename_ptr: [*]const u8,
    filename_len: usize,
) void {
    return engine_port.saveNetwork(
        network,
        if (has_filename != 0) filename_ptr[0..filename_len] else null,
    );
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

pub export fn zfish_engine_visualize(pos: *const anyopaque) ?[*:0]u8 {
    return engine_port.visualize(pos);
}

pub export fn zfish_engine_format_thread_binding(
    pairs_ptr: [*]const engine_port.CountPair,
    pair_count: usize,
) ?[*:0]u8 {
    return engine_port.formatThreadBinding(pairs_ptr, pair_count);
}

pub export fn zfish_engine_format_thread_allocation(
    thread_count: usize,
    binding_ptr: [*]const u8,
    binding_len: usize,
) ?[*:0]u8 {
    return engine_port.formatThreadAllocation(thread_count, binding_ptr, binding_len);
}

pub export fn zfish_engine_thread_binding_information(
    numa_context: *const anyopaque,
    threads: *const anyopaque,
) ?[*:0]u8 {
    return engine_port.threadBindingInformation(numa_context, threads);
}

pub export fn zfish_engine_thread_allocation_information(
    numa_context: *const anyopaque,
    threads: *const anyopaque,
) ?[*:0]u8 {
    return engine_port.threadAllocationInformation(numa_context, threads);
}

pub export fn zfish_engine_format_network_status(
    replica_index: usize,
    status: u8,
    error_ptr: [*]const u8,
    error_len: usize,
) ?[*:0]u8 {
    return engine_port.formatNetworkStatus(replica_index, status, error_ptr, error_len);
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
    zfish_position_fill_snapshot(pos, &snapshot);
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
    return network_port.load(
        network,
        root_directory_ptr,
        root_directory_len,
        evalfile_path_ptr,
        evalfile_path_len,
    );
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

pub export fn zfish_uci_dispatch_command(
    engine: *anyopaque,
    input_ptr: [*]const u8,
    input_len: usize,
) uci_port.DispatchResult {
    return uci_port.dispatchCommand(engine, input_ptr[0..input_len]);
}

pub export fn zfish_uci_loop_runtime(uci_ptr: *anyopaque) void {
    return uci_port.loopRuntime(uci_ptr);
}

pub export fn zfish_uci_bench_runtime(
    uci_ptr: *anyopaque,
    args_ptr: [*]const u8,
    args_len: usize,
) void {
    return uci_port.benchRuntime(uci_ptr, args_ptr[0..args_len]);
}

pub export fn zfish_uci_benchmark_runtime(
    uci_ptr: *anyopaque,
    args_ptr: [*]const u8,
    args_len: usize,
) void {
    return uci_port.benchmarkRuntime(uci_ptr, args_ptr[0..args_len]);
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
