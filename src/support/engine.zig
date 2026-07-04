const std = @import("std");
const c = @import("libc");
const position_snapshot = @import("position_snapshot");
const position_port = @import("position");
const uci_move = @import("uci_move");
const misc_port = @import("misc");
const thread_port = @import("thread");
const nnue_acc = @import("nnue_accumulator");
const evaluate_mod = @import("evaluate");
const graph_layout = @import("graph_layout");
const tablebase = @import("tablebase");
const option_port = @import("option");
const nnue_misc_mod = @import("nnue_misc");

// Force-compile the self-contained native engine-graph leaf nodes so their
// layout asserts (SharedState 40B, RootMove 552B, the search-manager dispatch)
// are build-verified rather than dead source. These are the vtable-free,
// std::function-free post-src/ graph nodes the atomic Engine cut switches to.
comptime {
    _ = @import("engine_graph.zig");
    _ = @import("search_manager.zig");
    _ = @import("shared_state.zig");
    _ = @import("root_move.zig");
}

const PendingStateEntry = struct {
    slot_key: usize,
    storage: *anyopaque,
};

var pending_state_entries = std.ArrayListUnmanaged(PendingStateEntry).empty;

const layer_stacks: usize = 8;
const square_count: usize = 64;
const piece_to_char = " PNBRQK  pnbrqk";
const white: u8 = 0;
const black: u8 = 1;
const white_oo: u8 = 1;
const white_ooo: u8 = 2;
const black_oo: u8 = 4;
const black_ooo: u8 = 8;
const sq_none: u8 = 64;
const max_ply: c_int = 246;
const value_mate: c_int = 32000;
const value_tb: c_int = value_mate - max_ply - 1;
const value_tb_win_in_max_ply: c_int = value_tb - max_ply;
const value_tb_loss_in_max_ply: c_int = -value_tb_win_in_max_ply;

const option_callback_none: u8 = 0;
const option_callback_debug_log_file: u8 = 1;
const option_callback_numa_policy: u8 = 2;
const option_callback_threads: u8 = 3;
const option_callback_hash: u8 = 4;
const option_callback_clear_hash: u8 = 5;
const option_callback_syzygy_path: u8 = 6;
const option_callback_eval_file: u8 = 7;

const option_kind_string: u8 = 0;
const option_kind_check: u8 = 1;
const option_kind_spin: u8 = 2;
const option_kind_button: u8 = 3;

// Single-sourced from network.zig via the "network" module (build.zig wires the
// engine->network edge). Avoids the net-name-drift bug of two copies.
const default_eval_file_name = @import("network").default_eval_file_name;
const default_skill_lowest_elo: c_int = 1320;
const default_skill_highest_elo: c_int = 3190;

pub const CountPair = extern struct {
    current: usize,
    total: usize,
};

const NetworkVerifyResult = extern struct {
    should_exit: u8,
    message: ?[*:0]u8,
};

pub const ByteView = extern struct {
    ptr: ?[*]const u8,
    len: usize,
};

pub const PositionSummary = extern struct {
    side_to_move_white: u8,
    checkers: u64,
    key: u64,
    material: c_int,
    rule50_count: c_int,
};

const PositionSnapshot = position_snapshot.PositionSnapshot;

pub const TablebaseProbe = tablebase.ProbeResult;

pub const EvalInput = extern struct {
    psqt: c_int,
    positional: c_int,
    optimism: c_int,
    material: c_int,
    rule50_count: c_int,
    value_tb_loss_in_max_ply: c_int,
    value_tb_win_in_max_ply: c_int,
};

pub const EvalOutput = extern struct {
    psqt: c_int,
    positional: c_int,
};

pub const TraceOutput = extern struct {
    psqt: [layer_stacks]c_int,
    positional: [layer_stacks]c_int,
    correct_bucket: usize,
};

pub const EvalTraceInput = extern struct {
    inner_trace_ptr: [*]const u8,
    inner_trace_len: usize,
    nnue_internal_value: c_int,
    nnue_white_cp: c_int,
    final_white_cp: c_int,
};

pub const NnueTraceInput = extern struct {
    side_to_move_white: u8,
    bucket_count: usize,
    correct_bucket: usize,
    psqt_cp: [*]const c_int,
    positional_cp: [*]const c_int,
};

extern fn zfish_engine_state_list_storage_create() ?*anyopaque;
extern fn zfish_engine_state_list_storage_destroy(storage: ?*anyopaque) void;
extern fn zfish_engine_state_list_storage_reset(storage: *anyopaque) *anyopaque;
extern fn zfish_engine_state_list_storage_push(storage: *anyopaque) *anyopaque;
extern fn zfish_engine_state_list_storage_has_states(storage: *const anyopaque) u8;
extern fn zfish_threadpool_setup_states_adopt_from_storage(pool: *anyopaque, storage: *anyopaque) void;
extern fn zfish_position_set_state(
    pos: *anyopaque,
    fen_ptr: [*]const u8,
    fen_len: usize,
    chess960_enabled: u8,
    state: *anyopaque,
) ?[*:0]u8;
extern fn zfish_position_do_move_state(pos: *anyopaque, move_raw: u16, state: *anyopaque) void;
extern fn zfish_position_create() ?*anyopaque;
extern fn zfish_position_destroy(pos: ?*anyopaque) void;
extern fn zfish_threadpool_wait_thread(threads: *anyopaque, thread_id: usize) void;
extern fn zfish_numa_context_set_system(numa_context: *anyopaque) void;
extern fn zfish_numa_context_set_hardware(numa_context: *anyopaque) void;
extern fn zfish_numa_context_set_none(numa_context: *anyopaque) void;
extern fn zfish_engine_numa_set_from_string(
    numa_context: *anyopaque,
    text_ptr: [*]const u8,
    text_len: usize,
) void;
extern fn zfish_numa_context_node_count(numa_context: *const anyopaque) usize;
extern fn zfish_numa_context_cpus_in_node(numa_context: *const anyopaque, node: usize) usize;
extern fn zfish_engine_accumulator_stack_create() ?*anyopaque;
extern fn zfish_engine_accumulator_stack_destroy(stack: ?*anyopaque) void;
extern fn zfish_engine_accumulator_caches_create(network: *const anyopaque) ?*anyopaque;
extern fn zfish_engine_accumulator_caches_destroy(caches: ?*anyopaque) void;
extern fn zfish_accumulator_position_snapshot(pos: *const anyopaque, pieces_out: [*]u8) void;
extern fn zfish_position_fill_snapshot(pos: *const anyopaque, out: *PositionSnapshot) void;
extern fn zfish_network_evaluate(
    network: *const anyopaque,
    pos: *const anyopaque,
    accumulator_stack: *anyopaque,
    cache: *anyopaque,
) EvalOutput;
extern fn zfish_network_trace_evaluate(
    network: *const anyopaque,
    pos: *const anyopaque,
    accumulator_stack: *anyopaque,
    cache: *anyopaque,
) TraceOutput;
extern fn zfish_uci_to_cp(value: c_int, material: c_int) c_int;
extern fn zfish_engine_set_start_position(engine_ptr: *anyopaque) void;
extern fn zfish_engine_add_option(
    engine_ptr: *anyopaque,
    name_ptr: [*]const u8,
    name_len: usize,
    option_kind: u8,
    default_ptr: [*]const u8,
    default_len: usize,
    default_value: c_int,
    min_value: c_int,
    max_value: c_int,
    callback_kind: u8,
) void;
extern fn zfish_engine_start_logger(name_ptr: [*]const u8, name_len: usize) void;
extern fn zfish_engine_set_numa_config_from_option_owner(
    engine_ptr: *anyopaque,
    value_ptr: [*]const u8,
    value_len: usize,
) void;
extern fn zfish_engine_numa_config_info_text(engine_ptr: *const anyopaque) ?[*:0]u8;
extern fn zfish_engine_thread_allocation_info_text(engine_ptr: *const anyopaque) ?[*:0]u8;
extern fn zfish_engine_evalfile_text(engine_ptr: *const anyopaque) ?[*:0]u8;
extern fn zfish_engine_numa_config_text(engine_ptr: *const anyopaque) ?[*:0]u8;
extern fn zfish_engine_position_ptr(engine_ptr: *anyopaque) *anyopaque;
extern fn zfish_engine_options_ptr(engine_ptr: *const anyopaque) *const anyopaque;
extern fn zfish_engine_numa_context_ptr(engine_ptr: *anyopaque) *anyopaque;
extern fn zfish_engine_states_slot_ptr(engine_ptr: *anyopaque) *anyopaque;
extern fn zfish_engine_states_slot_reset(states_slot: *anyopaque) void;
extern fn zfish_engine_network_ptr(engine_ptr: *const anyopaque) *const anyopaque;
extern fn zfish_engine_threads_ptr(engine_ptr: *anyopaque) *anyopaque;
extern fn zfish_engine_chess960_enabled(engine_ptr: *const anyopaque) u8;
extern fn zfish_network_verify(
    network: *const anyopaque,
    evalfile_path_ptr: [*]const u8,
    evalfile_path_len: usize,
) NetworkVerifyResult;
extern fn zfish_thread_start_thinking(
    pool: *anyopaque,
    options: *const anyopaque,
    pos: *anyopaque,
    limits: *const anyopaque,
    states_slot: *anyopaque,
) void;
extern fn zfish_engine_emit_verify_message(
    engine_ptr: *const anyopaque,
    message_ptr: [*]const u8,
    message_len: usize,
) void;
extern fn zfish_engine_load_network_owner(engine_ptr: *anyopaque, file_ptr: [*]const u8, file_len: usize) void;
extern fn zfish_engine_save_network_owner(
    engine_ptr: *anyopaque,
    has_filename: u8,
    filename_ptr: [*]const u8,
    filename_len: usize,
) void;
extern fn zfish_threadpool_reconfigure(
    pool: *anyopaque,
    numa_config: *const anyopaque,
    shared_state: *const anyopaque,
    update_context: *const anyopaque,
) void;
extern fn zfish_numa_context_config(numa_context: *const anyopaque) *const anyopaque;
extern fn zfish_search_shared_state_create(
    options: *const anyopaque,
    threads: *anyopaque,
    tt: *anyopaque,
    shared_hists: *anyopaque,
    network: *const anyopaque,
) ?*anyopaque;
extern fn zfish_search_shared_state_destroy(shared_state: ?*anyopaque) void;
extern fn zfish_engine_tt_resize(tt: *anyopaque, mb: usize, threads: *anyopaque) void;
extern fn zfish_engine_tt_ptr(engine_ptr: *anyopaque) *anyopaque;
extern fn zfish_engine_shared_hists_ptr(engine_ptr: *anyopaque) *anyopaque;
extern fn zfish_engine_network_replicated_ptr(engine_ptr: *anyopaque) *anyopaque;
extern fn zfish_engine_update_context_ptr(engine_ptr: *const anyopaque) *const anyopaque;
extern fn zfish_engine_tt_clear(tt: *anyopaque, threads: *anyopaque) void;
extern fn zfish_engine_syzygy_path_text(engine_ptr: *const anyopaque) ?[*:0]u8;
extern fn zfish_engine_tt_hashfull(engine_ptr: *const anyopaque, max_age: c_int) c_int;

pub fn initBody(engine_ptr: *anyopaque) void {
    const max_threads = @max(@as(c_int, 1024), 4 * misc_port.hardwareConcurrency());
    const max_hash_mb: c_int = if (@sizeOf(usize) >= 8) 33554432 else 2048;

    const lowest_elo: c_int = default_skill_lowest_elo;
    const highest_elo: c_int = default_skill_highest_elo;

    addStringOption(engine_ptr, "Debug Log File", "", option_callback_debug_log_file);
    addStringOption(engine_ptr, "NumaPolicy", "auto", option_callback_numa_policy);
    addSpinOption(engine_ptr, "Threads", 1, 1, max_threads, option_callback_threads);
    addSpinOption(engine_ptr, "Hash", 16, 1, max_hash_mb, option_callback_hash);
    addButtonOption(engine_ptr, "Clear Hash", option_callback_clear_hash);
    addCheckOption(engine_ptr, "Ponder", 0);
    addSpinOption(engine_ptr, "MultiPV", 1, 1, 256, option_callback_none);
    addSpinOption(engine_ptr, "Skill Level", 20, 0, 20, option_callback_none);
    addSpinOption(engine_ptr, "Move Overhead", 10, 0, 5000, option_callback_none);
    addSpinOption(engine_ptr, "nodestime", 0, 0, 10000, option_callback_none);
    addCheckOption(engine_ptr, "UCI_Chess960", 0);
    addCheckOption(engine_ptr, "UCI_LimitStrength", 0);
    addSpinOption(engine_ptr, "UCI_Elo", lowest_elo, lowest_elo, highest_elo, option_callback_none);
    addCheckOption(engine_ptr, "UCI_ShowWDL", 0);
    addStringOption(engine_ptr, "SyzygyPath", "", option_callback_syzygy_path);
    addSpinOption(engine_ptr, "SyzygyProbeDepth", 1, 1, 100, option_callback_none);
    addCheckOption(engine_ptr, "Syzygy50MoveRule", 1);
    addSpinOption(engine_ptr, "SyzygyProbeLimit", 7, 0, 7, option_callback_none);
    addStringOption(engine_ptr, "EvalFile", default_eval_file_name, option_callback_eval_file);

    zfish_engine_set_start_position(engine_ptr);
    resizeThreadsEngine(engine_ptr);
}

pub fn optionOnChange(
    engine_ptr: *anyopaque,
    callback_kind: u8,
    value_ptr: [*]const u8,
    value_len: usize,
    int_value: c_int,
) ?[*:0]u8 {
    const value = value_ptr[0..value_len];

    return switch (callback_kind) {
        option_callback_debug_log_file => blk: {
            zfish_engine_start_logger(value.ptr, value.len);
            break :blk null;
        },
        option_callback_numa_policy => blk: {
            zfish_engine_set_numa_config_from_option_owner(engine_ptr, value.ptr, value.len);

            const numa_info_ptr = zfish_engine_numa_config_info_text(engine_ptr) orelse break :blk null;
            defer c.free(@ptrCast(numa_info_ptr));

            const thread_info_ptr = zfish_engine_thread_allocation_info_text(engine_ptr) orelse break :blk null;
            defer c.free(@ptrCast(thread_info_ptr));

            break :blk allocMessage("{s}\n{s}", .{ std.mem.span(numa_info_ptr), std.mem.span(thread_info_ptr) });
        },
        option_callback_threads => blk: {
            resizeThreadsEngine(engine_ptr);
            break :blk zfish_engine_thread_allocation_info_text(engine_ptr);
        },
        option_callback_hash => blk: {
            setTtSizeEngine(engine_ptr, @intCast(@max(int_value, 0)));
            break :blk null;
        },
        option_callback_clear_hash => blk: {
            searchClearEngine(engine_ptr);
            break :blk null;
        },
        option_callback_syzygy_path => blk: {
            tablebase.init(value.ptr, value.len);
            break :blk null;
        },
        option_callback_eval_file => blk: {
            zfish_engine_load_network_owner(engine_ptr, value.ptr, value.len);
            break :blk null;
        },
        else => null,
    };
}

pub fn setPosition(
    pos: *anyopaque,
    states_slot: *anyopaque,
    chess960_enabled: u8,
    fen_ptr: [*]const u8,
    fen_len: usize,
    moves_ptr: ?[*]const ByteView,
    move_count: usize,
) ?[*:0]u8 {
    const state_storage = ensurePendingStateStorage(states_slot);
    const root_state = zfish_engine_state_list_storage_reset(state_storage);

    if (zfish_position_set_state(pos, fen_ptr, fen_len, chess960_enabled, root_state)) |err| {
        return err;
    }

    const move_views = if (moves_ptr) |ptr| ptr[0..move_count] else &[_]ByteView{};
    const none_raw = uci_move.noneRaw();

    for (move_views) |view| {
        const move_text = if (view.ptr) |ptr| ptr[0..view.len] else "";
        const move_raw = if (view.ptr) |ptr| uci_move.toMoveRaw(pos, ptr[0..view.len]) else none_raw;

        if (move_raw == none_raw) {
            return allocMessage("Illegal move: {s}", .{move_text});
        }

        const next_state = zfish_engine_state_list_storage_push(state_storage);
        zfish_position_do_move_state(pos, move_raw, next_state);
    }

    return null;
}

pub fn setPositionEngine(
    engine_ptr: *anyopaque,
    fen_ptr: [*]const u8,
    fen_len: usize,
    moves_ptr: ?[*]const ByteView,
    move_count: usize,
) ?[*:0]u8 {
    const states_slot = zfish_engine_states_slot_ptr(engine_ptr);
    zfish_engine_states_slot_reset(states_slot);

    return setPosition(
        zfish_engine_position_ptr(engine_ptr),
        states_slot,
        zfish_engine_chess960_enabled(engine_ptr),
        fen_ptr,
        fen_len,
        moves_ptr,
        move_count,
    );
}

pub fn pendingStatesAvailable(states_slot: *anyopaque) u8 {
    const state_storage = lookupPendingStateStorage(@intFromPtr(states_slot)) orelse return 0;
    return zfish_engine_state_list_storage_has_states(state_storage);
}

pub fn handoffPendingStates(pool: *anyopaque, states_slot: *anyopaque) u8 {
    const state_storage = lookupPendingStateStorage(@intFromPtr(states_slot)) orelse return 0;
    if (zfish_engine_state_list_storage_has_states(state_storage) == 0)
        return 0;

    zfish_threadpool_setup_states_adopt_from_storage(pool, state_storage);
    return @intFromBool(graph_layout.ThreadPool.fromPtr(@constCast(pool)).hasSetupStates());
}

pub fn releasePendingStateSlot(states_slot: *anyopaque) void {
    if (removePendingStateStorage(@intFromPtr(states_slot))) |state_storage| {
        zfish_engine_state_list_storage_destroy(state_storage);
    }
}

pub fn stop(threads: *anyopaque) void {
    graph_layout.ThreadPool.fromPtr(threads).setStop(true);
}

pub fn stopEngine(engine_ptr: *anyopaque) void {
    stop(zfish_engine_threads_ptr(engine_ptr));
}

pub fn waitForSearchFinishedEngine(engine_ptr: *anyopaque) void {
    zfish_threadpool_wait_thread(zfish_engine_threads_ptr(engine_ptr), 0);
}

pub fn goEngine(engine_ptr: *anyopaque, limits_ptr: *const anyopaque) void {
    std.debug.assert(graph_layout.LimitsType.fromPtr(@constCast(limits_ptr)).perftValue() == 0);
    verifyNetwork(engine_ptr);
    zfish_thread_start_thinking(
        zfish_engine_threads_ptr(engine_ptr),
        zfish_engine_options_ptr(engine_ptr),
        zfish_engine_position_ptr(engine_ptr),
        limits_ptr,
        zfish_engine_states_slot_ptr(engine_ptr),
    );
}

pub fn setNumaConfigFromOptionEngine(engine_ptr: *anyopaque, option_text: []const u8) void {
    const numa_context = zfish_engine_numa_context_ptr(engine_ptr);

    if (std.mem.eql(u8, option_text, "auto") or std.mem.eql(u8, option_text, "system")) {
        zfish_numa_context_set_system(numa_context);
    } else if (std.mem.eql(u8, option_text, "hardware")) {
        zfish_numa_context_set_hardware(numa_context);
    } else if (std.mem.eql(u8, option_text, "none")) {
        zfish_numa_context_set_none(numa_context);
    } else {
        zfish_engine_numa_set_from_string(numa_context, option_text.ptr, option_text.len);
    }

    resizeThreadsEngine(engine_ptr);
}

pub fn resizeThreads(
    numa_context: *const anyopaque,
    options: *const anyopaque,
    threads: *anyopaque,
    tt: *anyopaque,
    shared_hists: *anyopaque,
    network: *const anyopaque,
    update_context: *const anyopaque,
) void {
    thread_port.waitForSearchFinished(threads);

    const shared_state = zfish_search_shared_state_create(
        options,
        threads,
        tt,
        shared_hists,
        network,
    ) orelse @panic("OOM");
    defer zfish_search_shared_state_destroy(shared_state);

    zfish_threadpool_reconfigure(
        threads,
        zfish_numa_context_config(numa_context),
        shared_state,
        update_context,
    );

    setTtSize(threads, tt, option_port.optionHash());
    thread_port.ensureNetworkReplicated(threads);
}

pub fn resizeThreadsEngine(engine_ptr: *anyopaque) void {
    resizeThreads(
        zfish_engine_numa_context_ptr(engine_ptr),
        zfish_engine_options_ptr(engine_ptr),
        zfish_engine_threads_ptr(engine_ptr),
        zfish_engine_tt_ptr(engine_ptr),
        zfish_engine_shared_hists_ptr(engine_ptr),
        zfish_engine_network_replicated_ptr(engine_ptr),
        zfish_engine_update_context_ptr(engine_ptr),
    );
}

pub fn setTtSize(threads: *anyopaque, tt: *anyopaque, mb: usize) void {
    zfish_threadpool_wait_thread(threads, 0);
    zfish_engine_tt_resize(tt, mb, threads);
}

pub fn setTtSizeEngine(engine_ptr: *anyopaque, mb: usize) void {
    setTtSize(zfish_engine_threads_ptr(engine_ptr), zfish_engine_tt_ptr(engine_ptr), mb);
}

pub fn setPonderhit(threads: *anyopaque, ponder: u8) void {
    if (graph_layout.ThreadPool.fromPtr(threads).mainManager()) |m| m.setPonder(ponder != 0);
}

pub fn setPonderhitEngine(engine_ptr: *anyopaque, ponder: u8) void {
    setPonderhit(zfish_engine_threads_ptr(engine_ptr), ponder);
}

pub fn searchClear(threads: *anyopaque, tt: *anyopaque, syzygy_path: []const u8) void {
    thread_port.waitForSearchFinished(threads);
    zfish_engine_tt_clear(tt, threads);
    thread_port.clear(threads);
    tablebase.init(syzygy_path.ptr, syzygy_path.len);
}

pub fn searchClearEngine(engine_ptr: *anyopaque) void {
    const syzygy_ptr = zfish_engine_syzygy_path_text(engine_ptr) orelse return;
    defer c.free(@ptrCast(syzygy_ptr));
    searchClear(
        zfish_engine_threads_ptr(engine_ptr),
        zfish_engine_tt_ptr(engine_ptr),
        std.mem.span(syzygy_ptr),
    );
}

pub fn numaConfigStringEngine(engine_ptr: *const anyopaque) ?[*:0]u8 {
    const config_ptr = zfish_engine_numa_config_text(engine_ptr) orelse return null;
    defer c.free(@ptrCast(config_ptr));
    return allocMessage("{s}", .{std.mem.span(config_ptr)});
}

pub fn numaConfigInformationEngine(engine_ptr: *const anyopaque) ?[*:0]u8 {
    const config_ptr = zfish_engine_numa_config_text(engine_ptr) orelse return null;
    defer c.free(@ptrCast(config_ptr));
    const config = std.mem.span(config_ptr);
    return formatNumaInfo(config.ptr, config.len);
}

pub fn threadBindingInformationEngine(engine_ptr: *const anyopaque) ?[*:0]u8 {
    return threadBindingInformation(
        zfish_engine_numa_context_ptr(@constCast(engine_ptr)),
        zfish_engine_threads_ptr(@constCast(engine_ptr)),
    );
}

pub fn threadAllocationInformationEngine(engine_ptr: *const anyopaque) ?[*:0]u8 {
    return threadAllocationInformation(
        zfish_engine_numa_context_ptr(@constCast(engine_ptr)),
        zfish_engine_threads_ptr(@constCast(engine_ptr)),
    );
}

pub fn verifyNetwork(engine_ptr: *const anyopaque) void {
    const evalfile_ptr = zfish_engine_evalfile_text(engine_ptr) orelse return;
    defer c.free(@ptrCast(evalfile_ptr));
    const evalfile = std.mem.span(evalfile_ptr);

    const network_ptr = zfish_engine_network_ptr(engine_ptr);

    const result = zfish_network_verify(network_ptr, evalfile.ptr, evalfile.len);
    if (result.message) |message_ptr| {
        defer c.free(@ptrCast(message_ptr));
        zfish_engine_emit_verify_message(engine_ptr, message_ptr, std.mem.span(message_ptr).len);
    }

    if (result.should_exit != 0) {
        c.exit(1);
    }
}

pub fn traceEvalEngine(engine_ptr: *anyopaque) ?[*:0]u8 {
    verifyNetwork(engine_ptr);

    const source_pos = zfish_engine_position_ptr(engine_ptr);
    const network = zfish_engine_network_ptr(engine_ptr);
    const fen_ptr = fen(source_pos) orelse return null;
    defer c.free(@ptrCast(fen_ptr));
    const fen_text = std.mem.span(fen_ptr);

    const trace_pos = zfish_position_create() orelse return null;
    defer zfish_position_destroy(trace_pos);

    const state_storage = zfish_engine_state_list_storage_create() orelse return null;
    defer zfish_engine_state_list_storage_destroy(state_storage);
    const state = zfish_engine_state_list_storage_reset(state_storage);

    if (zfish_position_set_state(trace_pos, fen_text.ptr, fen_text.len, zfish_engine_chess960_enabled(engine_ptr), state)) |err| {
        defer c.free(@ptrCast(err));
        return null;
    }

    return evalTrace(trace_pos, network);
}

pub fn loadNetworkEngine(engine_ptr: *anyopaque, evalfile_path: []const u8) void {
    zfish_engine_load_network_owner(engine_ptr, evalfile_path.ptr, evalfile_path.len);
}

pub fn saveNetworkEngine(engine_ptr: *anyopaque, filename_opt: ?[]const u8) void {
    const has_filename: u8 = if (filename_opt != null) 1 else 0;
    const filename = filename_opt orelse "";
    zfish_engine_save_network_owner(engine_ptr, has_filename, filename.ptr, filename.len);
}

fn ensurePendingStateStorage(states_slot: *anyopaque) *anyopaque {
    const slot_key = @intFromPtr(states_slot);

    if (findPendingStateIndex(slot_key)) |index| {
        return pending_state_entries.items[index].storage;
    }

    const state_storage = zfish_engine_state_list_storage_create() orelse @panic("OOM");
    pending_state_entries.append(std.heap.c_allocator, .{
        .slot_key = slot_key,
        .storage = state_storage,
    }) catch {
        zfish_engine_state_list_storage_destroy(state_storage);
        @panic("OOM");
    };

    return state_storage;
}

fn lookupPendingStateStorage(slot_key: usize) ?*anyopaque {
    if (findPendingStateIndex(slot_key)) |index| {
        return pending_state_entries.items[index].storage;
    }

    return null;
}

fn removePendingStateStorage(slot_key: usize) ?*anyopaque {
    if (findPendingStateIndex(slot_key)) |index| {
        const state_storage = pending_state_entries.items[index].storage;
        _ = pending_state_entries.swapRemove(index);
        return state_storage;
    }

    return null;
}

fn findPendingStateIndex(slot_key: usize) ?usize {
    var index: usize = 0;
    while (index < pending_state_entries.items.len) : (index += 1) {
        if (pending_state_entries.items[index].slot_key == slot_key) {
            return index;
        }
    }

    return null;
}

pub fn evalTrace(pos: *anyopaque, network: *const anyopaque) ?[*:0]u8 {
    const summary = positionSummary(pos);
    if (summary.checkers != 0)
        return allocMessage("Final evaluation: none (in check)", .{});

    const caches = zfish_engine_accumulator_caches_create(network) orelse return null;
    defer zfish_engine_accumulator_caches_destroy(caches);

    const inner_trace_ptr = buildNnueTrace(pos, network, summary, caches) orelse return null;
    defer c.free(@ptrCast(inner_trace_ptr));
    const inner_trace = std.mem.span(inner_trace_ptr);

    const accumulators = zfish_engine_accumulator_stack_create() orelse return null;
    defer zfish_engine_accumulator_stack_destroy(accumulators);

    const nnue_output = zfish_network_evaluate(network, pos, accumulators, caches);
    const nnue_value = nnue_output.psqt + nnue_output.positional;
    const nnue_white_side = if (summary.side_to_move_white != 0) nnue_value else -nnue_value;

    const final_value = evaluate_mod.computeValue(.{
        .psqt = nnue_output.psqt,
        .positional = nnue_output.positional,
        .optimism = 0,
        .material = summary.material,
        .rule50_count = summary.rule50_count,
        .value_tb_loss_in_max_ply = value_tb_loss_in_max_ply,
        .value_tb_win_in_max_ply = value_tb_win_in_max_ply,
    });
    const final_white_side = if (summary.side_to_move_white != 0) final_value else -final_value;

    return evaluate_mod.formatTrace(.{
        .inner_trace_ptr = inner_trace.ptr,
        .inner_trace_len = inner_trace.len,
        .nnue_internal_value = nnue_value,
        .nnue_white_cp = zfish_uci_to_cp(nnue_white_side, summary.material),
        .final_white_cp = zfish_uci_to_cp(final_white_side, summary.material),
    });
}

pub fn fen(pos: *const anyopaque) ?[*:0]u8 {
    return positionFen(pos, null);
}

pub fn fenEngine(engine_ptr: *const anyopaque) ?[*:0]u8 {
    return fen(zfish_engine_position_ptr(@constCast(engine_ptr)));
}

pub fn hashfullEngine(engine_ptr: *const anyopaque, max_age: c_int) c_int {
    return zfish_engine_tt_hashfull(engine_ptr, max_age);
}

pub fn visualize(pos: *const anyopaque) ?[*:0]u8 {
    const allocator = std.heap.c_allocator;
    var pieces: [square_count]u8 = [_]u8{0} ** square_count;
    zfish_accumulator_position_snapshot(pos, &pieces);

    const summary = positionSummary(pos);
    const fen_ptr = positionFen(pos, &pieces) orelse return null;
    defer c.free(@ptrCast(fen_ptr));
    const fen_text = std.mem.span(fen_ptr);

    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(allocator);

    buffer.appendSlice(allocator, "\n +---+---+---+---+---+---+---+---+\n") catch return null;

    var rank: usize = 8;
    while (rank > 0) {
        rank -= 1;

        var file: usize = 0;
        while (file < 8) : (file += 1) {
            const square_index = rank * 8 + file;
            buffer.appendSlice(allocator, " | ") catch return null;
            buffer.append(allocator, piece_to_char[pieces[square_index]]) catch return null;
        }

        appendFormat(
            &buffer,
            " | {d}\n +---+---+---+---+---+---+---+---+\n",
            .{rank + 1},
        ) catch return null;
    }

    buffer.appendSlice(allocator, "   a   b   c   d   e   f   g   h\n\nFen: ") catch return null;
    buffer.appendSlice(allocator, fen_text) catch return null;
    buffer.appendSlice(allocator, "\nKey: ") catch return null;
    appendHexKey(&buffer, summary.key) catch return null;
    buffer.appendSlice(allocator, "\nCheckers: ") catch return null;
    appendCheckers(&buffer, summary.checkers) catch return null;

    const tb = probeTablebases(pos, &pieces);
    if (tb.available != 0) {
        buffer.appendSlice(allocator, "\nTablebases WDL: ") catch return null;
        appendPaddedInt(&buffer, tb.wdl) catch return null;
        appendFormat(&buffer, " ({d})\nTablebases DTZ: ", .{tb.wdl_state}) catch return null;
        appendPaddedInt(&buffer, tb.dtz) catch return null;
        appendFormat(&buffer, " ({d})", .{tb.dtz_state}) catch return null;
    }

    const owned = allocator.allocSentinel(u8, buffer.items.len, 0) catch return null;
    @memcpy(owned[0..buffer.items.len], buffer.items);
    return owned.ptr;
}

    pub fn visualizeEngine(engine_ptr: *const anyopaque) ?[*:0]u8 {
        return visualize(zfish_engine_position_ptr(@constCast(engine_ptr)));
    }

pub fn formatNumaInfo(config_ptr: [*]const u8, config_len: usize) ?[*:0]u8 {
    return allocMessage("Available processors: {s}", .{config_ptr[0..config_len]});
}

pub fn formatThreadBinding(pairs_ptr: [*]const CountPair, pair_count: usize) ?[*:0]u8 {
    if (pair_count == 0)
        return allocMessage("", .{});

    const allocator = std.heap.c_allocator;
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(allocator);

    var index: usize = 0;
    while (index < pair_count) : (index += 1) {
        if (index != 0)
            buffer.append(allocator, ':') catch return null;
        const segment = std.fmt.allocPrint(
            allocator,
            "{d}/{d}",
            .{ pairs_ptr[index].current, pairs_ptr[index].total },
        ) catch return null;
        defer allocator.free(segment);
        buffer.appendSlice(allocator, segment) catch return null;
    }

    const owned = allocator.allocSentinel(u8, buffer.items.len, 0) catch return null;
    @memcpy(owned[0..buffer.items.len], buffer.items);
    return owned.ptr;
}

pub fn formatThreadAllocation(
    thread_count: usize,
    binding_ptr: [*]const u8,
    binding_len: usize,
) ?[*:0]u8 {
    const binding = binding_ptr[0..binding_len];
    if (binding.len == 0)
        return allocMessage(
            "Using {d} {s}",
            .{ thread_count, if (thread_count > 1) "threads" else "thread" },
        );

    return allocMessage(
        "Using {d} {s} with NUMA node thread binding: {s}",
        .{ thread_count, if (thread_count > 1) "threads" else "thread", binding },
    );
}

pub fn threadBindingInformation(
    numa_context: *const anyopaque,
    threads: *const anyopaque,
) ?[*:0]u8 {
    const bound_count = graph_layout.ThreadPool.fromPtr(@constCast(threads)).boundCount();
    if (bound_count == 0)
        return allocMessage("", .{});

    const allocator = std.heap.c_allocator;
    const node_count = zfish_numa_context_node_count(numa_context);

    const counts = allocator.alloc(usize, node_count) catch return null;
    defer allocator.free(counts);
    @memset(counts, 0);

    var index: usize = 0;
    while (index < bound_count) : (index += 1) {
        const node = graph_layout.ThreadPool.fromPtr(@constCast(threads)).boundAt(index);
        if (node < node_count)
            counts[node] += 1;
    }

    const pairs = allocator.alloc(CountPair, node_count) catch return null;
    defer allocator.free(pairs);

    index = 0;
    while (index < node_count) : (index += 1) {
        pairs[index] = .{
            .current = counts[index],
            .total = zfish_numa_context_cpus_in_node(numa_context, index),
        };
    }

    return formatThreadBinding(pairs.ptr, pairs.len);
}

pub fn threadAllocationInformation(
    numa_context: *const anyopaque,
    threads: *const anyopaque,
) ?[*:0]u8 {
    const binding_ptr = threadBindingInformation(numa_context, threads) orelse return null;
    defer c.free(@ptrCast(binding_ptr));

    const binding = std.mem.span(binding_ptr);
    return formatThreadAllocation(graph_layout.ThreadPool.fromPtr(@constCast(threads)).numThreads(), binding.ptr, binding.len);
}

fn addStringOption(engine_ptr: *anyopaque, name: []const u8, default_value: []const u8, callback_kind: u8) void {
    zfish_engine_add_option(
        engine_ptr,
        name.ptr,
        name.len,
        option_kind_string,
        default_value.ptr,
        default_value.len,
        0,
        0,
        0,
        callback_kind,
    );
}

fn addCheckOption(engine_ptr: *anyopaque, name: []const u8, default_value: u8) void {
    zfish_engine_add_option(
        engine_ptr,
        name.ptr,
        name.len,
        option_kind_check,
        "".ptr,
        0,
        default_value,
        0,
        0,
        option_callback_none,
    );
}

fn addSpinOption(
    engine_ptr: *anyopaque,
    name: []const u8,
    default_value: c_int,
    min_value: c_int,
    max_value: c_int,
    callback_kind: u8,
) void {
    zfish_engine_add_option(
        engine_ptr,
        name.ptr,
        name.len,
        option_kind_spin,
        "".ptr,
        0,
        default_value,
        min_value,
        max_value,
        callback_kind,
    );
}

fn addButtonOption(engine_ptr: *anyopaque, name: []const u8, callback_kind: u8) void {
    zfish_engine_add_option(
        engine_ptr,
        name.ptr,
        name.len,
        option_kind_button,
        "".ptr,
        0,
        0,
        0,
        0,
        callback_kind,
    );
}

fn allocMessage(comptime fmt: []const u8, args: anytype) ?[*:0]u8 {
    const allocator = std.heap.c_allocator;
    const rendered = std.fmt.allocPrint(allocator, fmt, args) catch return null;
    defer allocator.free(rendered);
    const owned = allocator.allocSentinel(u8, rendered.len, 0) catch return null;
    @memcpy(owned[0..rendered.len], rendered);
    return owned.ptr;
}

fn buildNnueTrace(
    pos: *anyopaque,
    network: *const anyopaque,
    summary: PositionSummary,
    caches: *anyopaque,
) ?[*:0]u8 {
    const accumulators = zfish_engine_accumulator_stack_create() orelse return null;
    defer zfish_engine_accumulator_stack_destroy(accumulators);
    nnue_acc.stackReset(accumulators);

    const trace = zfish_network_trace_evaluate(network, pos, accumulators, caches);
    var psqt_cp: [layer_stacks]c_int = undefined;
    var positional_cp: [layer_stacks]c_int = undefined;

    var bucket: usize = 0;
    while (bucket < layer_stacks) : (bucket += 1) {
        psqt_cp[bucket] = zfish_uci_to_cp(trace.psqt[bucket], summary.material);
        positional_cp[bucket] = zfish_uci_to_cp(trace.positional[bucket], summary.material);
    }

    return nnue_misc_mod.formatTrace(.{
        .side_to_move_white = summary.side_to_move_white,
        .bucket_count = layer_stacks,
        .correct_bucket = trace.correct_bucket,
        .psqt_cp = &psqt_cp,
        .positional_cp = &positional_cp,
    });
}

fn positionSummary(pos: *const anyopaque) PositionSummary {
    const snapshot = loadPositionSnapshot(pos);
    return .{
        .side_to_move_white = if (snapshot.side_to_move == white) 1 else 0,
        .checkers = snapshot.checkers,
        .key = snapshot.key,
        .material = snapshot.material_value,
        .rule50_count = snapshot.rule50_count,
    };
}

fn positionFen(pos: *const anyopaque, pieces_opt: ?*const [square_count]u8) ?[*:0]u8 {
    const snapshot = loadPositionSnapshot(pos);
    var pieces_storage: [square_count]u8 = undefined;
    const pieces: *const [square_count]u8 = if (pieces_opt) |provided|
        provided
    else blk: {
        zfish_accumulator_position_snapshot(pos, &pieces_storage);
        break :blk &pieces_storage;
    };

    return position_port.formatFen(
        @ptrCast(pieces),
        snapshot.side_to_move,
        snapshot.is_chess960,
        snapshot.castling_rights,
        snapshot.castling_rook_square[white_oo],
        snapshot.castling_rook_square[white_ooo],
        snapshot.castling_rook_square[black_oo],
        snapshot.castling_rook_square[black_ooo],
        snapshot.ep_square,
        snapshot.rule50_count,
        snapshot.game_ply,
    );
}

fn probeTablebases(pos: *const anyopaque, pieces_opt: ?*const [square_count]u8) TablebaseProbe {
    const snapshot = loadPositionSnapshot(pos);
    if (snapshot.castling_rights != 0) {
        return emptyTablebaseProbe();
    }

    var pieces_storage: [square_count]u8 = undefined;
    const pieces: *const [square_count]u8 = if (pieces_opt) |provided|
        provided
    else blk: {
        zfish_accumulator_position_snapshot(pos, &pieces_storage);
        break :blk &pieces_storage;
    };

    if (countPieces(pieces) > tablebase.maxCardinality()) {
        return emptyTablebaseProbe();
    }

    const fen_ptr = positionFen(pos, pieces) orelse return emptyTablebaseProbe();
    defer c.free(@ptrCast(fen_ptr));
    const fen_text = std.mem.span(fen_ptr);
    return tablebase.probeFen(fen_text.ptr, fen_text.len, snapshot.is_chess960);
}

fn loadPositionSnapshot(pos: *const anyopaque) PositionSnapshot {
    var snapshot = std.mem.zeroes(PositionSnapshot);
    zfish_position_fill_snapshot(pos, &snapshot);
    return snapshot;
}

fn countPieces(pieces: *const [square_count]u8) usize {
    var count: usize = 0;
    for (pieces.*) |piece| {
        if (piece != 0) {
            count += 1;
        }
    }
    return count;
}

fn emptyTablebaseProbe() TablebaseProbe {
    return .{
        .available = 0,
        .wdl = 0,
        .wdl_state = 0,
        .dtz = 0,
        .dtz_state = 0,
    };
}

fn appendFormat(buffer: *std.ArrayList(u8), comptime fmt: []const u8, args: anytype) !void {
    const allocator = std.heap.c_allocator;
    const rendered = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(rendered);
    try buffer.appendSlice(allocator, rendered);
}

fn appendHexKey(buffer: *std.ArrayList(u8), key: u64) !void {
    var numeric: [32]u8 = undefined;
    const len = c.snprintf(&numeric, numeric.len, "%016llX", @as(c_ulonglong, key));
    try buffer.appendSlice(std.heap.c_allocator, numeric[0..@intCast(len)]);
}

fn appendPaddedInt(buffer: *std.ArrayList(u8), value: c_int) !void {
    var numeric: [32]u8 = undefined;
    const len = c.snprintf(&numeric, numeric.len, "%4d", value);
    try buffer.appendSlice(std.heap.c_allocator, numeric[0..@intCast(len)]);
}

fn appendCheckers(buffer: *std.ArrayList(u8), checkers: u64) !void {
    var remaining = checkers;
    while (remaining != 0) {
        const square: usize = @intCast(@ctz(remaining));
        remaining &= remaining - 1;

        const square_text = [_]u8{
            @as(u8, 'a') + @as(u8, @intCast(square % 8)),
            @as(u8, '1') + @as(u8, @intCast(square / 8)),
        };
        try buffer.appendSlice(std.heap.c_allocator, &square_text);
        try buffer.append(std.heap.c_allocator, ' ');
    }
}
