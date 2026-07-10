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
const native_hooks = @import("native_hooks");
const tablebase = @import("tablebase");
const option_port = @import("option");
const state_list = @import("state_list");
const nnue_misc_mod = @import("nnue_misc");
const tt_port = @import("tt");
const numa = @import("numa");
const uci_wdl = @import("uci_wdl");
const uci_output = @import("uci_output");
const movegen_port = @import("movegen");
const native_engine = @import("native_engine");

// Cast an engine handle to the native container (M16.7).
inline fn ne(p: *const anyopaque) *native_engine.NativeEngine {
    return native_engine.NativeEngine.fromPtr(@constCast(p));
}

// Force-compile the self-contained native engine-graph leaf nodes so their
// layout asserts (SharedState 40B, RootMove 552B, the search-manager dispatch)
// are build-verified rather than dead source. These are the vtable-free,
// std::function-free post-src/ graph nodes the atomic Engine cut switches to.
const shared_state_mod = @import("shared_state");

comptime {
    _ = @import("engine_graph.zig");
    _ = @import("search_manager.zig");
    _ = shared_state_mod;
    _ = @import("root_move");
}

// M18.5 — the ONE concrete instantiation of the SharedState bundle. engine.zig is the
// root that sees all five referent types (nothing imports engine, so this can't be in a
// cycle); shared_state.zig stays a pure std leaf via the injected comptime types. The
// bundle's five typed pointers are 40 bytes, byte-identical to the former 5×*anyopaque,
// so the worker-build reinterpret is unchanged (asserted). See REPORT-17 Annex A.
pub const SharedState = shared_state_mod.SharedStateOf(
    option_port.OptionsModel,
    graph_layout.ThreadPool,
    tt_port.TranspositionTable,
    position_port.SharedHistoriesMap,
    network_port.Network,
);

comptime {
    std.debug.assert(@sizeOf(SharedState) == 40);
}

// One engine, one search at a time (sequential go commands; workers only READ the
// bundle during a search), so a single static reproduces the C++ new/delete lifetime
// without an allocator. Rebuilt per search, never aliased.
var live_shared_state: SharedState = undefined;

/// Build the live SharedState from the five referent handles and return its address.
/// The handles arrive erased across the reconfigure hook ABI; cast each to its typed
/// pointer once here (the storage boundary) so every downstream read is typed.
fn sharedStateCreate(
    options: *anyopaque,
    threads: *anyopaque,
    tt: *anyopaque,
    shared_histories: *anyopaque,
    network: *anyopaque,
) *anyopaque {
    live_shared_state = SharedState.init(
        @ptrCast(@alignCast(options)),
        @ptrCast(@alignCast(threads)),
        @ptrCast(@alignCast(tt)),
        @ptrCast(@alignCast(shared_histories)),
        @ptrCast(@alignCast(network)),
    );
    return @ptrCast(&live_shared_state);
}

fn sharedStateDestroy(ss: *anyopaque) void {
    _ = ss; // static storage — nothing to free (lifetime is the static itself)
}

const PendingStateStorage = state_list.PendingStateStorage;

const PendingStateEntry = struct {
    slot_key: usize,
    storage: *PendingStateStorage,
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
const network_port = @import("network");
const default_eval_file_name = network_port.default_eval_file_name;
const default_skill_lowest_elo: c_int = 1320;
const default_skill_highest_elo: c_int = 3190;

// String/format helpers + ByteView/CountPair live in the engine_util base leaf
// (M17.3x); ByteView re-exported (external port surface), the rest aliased.
const engine_util = @import("engine_util");
pub const ByteView = engine_util.ByteView;
pub const CountPair = engine_util.CountPair;
const allocMessage = engine_util.allocMessage;
const appendFormat = engine_util.appendFormat;
const appendHexKey = engine_util.appendHexKey;
const appendPaddedInt = engine_util.appendPaddedInt;
const appendCheckers = engine_util.appendCheckers;

const NetworkVerifyResult = struct {
    should_exit: u8,
    message: ?[*:0]u8,
};

const PositionSnapshot = position_snapshot.PositionSnapshot;

pub fn initBody(engine_ptr: *anyopaque) void {
    // Construction boundary: main hands the engine as a raw buffer; this hook keeps
    // the *anyopaque ABI and casts once to drive the typed init entries below.
    const e: *native_engine.NativeEngine = ne(engine_ptr);
    const max_threads = @max(@as(c_int, 1024), 4 * misc_port.hardwareConcurrency());
    const max_hash_mb: c_int = if (@sizeOf(usize) >= 8) 33554432 else 2048;

    const lowest_elo: c_int = default_skill_lowest_elo;
    const highest_elo: c_int = default_skill_highest_elo;

    addStringOption("Debug Log File", "", option_callback_debug_log_file);
    addStringOption("NumaPolicy", "auto", option_callback_numa_policy);
    addSpinOption("Threads", 1, 1, max_threads, option_callback_threads);
    addSpinOption("Hash", 16, 1, max_hash_mb, option_callback_hash);
    addButtonOption("Clear Hash", option_callback_clear_hash);
    addCheckOption("Ponder", 0);
    addSpinOption("MultiPV", 1, 1, 256, option_callback_none);
    addSpinOption("Skill Level", 20, 0, 20, option_callback_none);
    addSpinOption("Move Overhead", 10, 0, 5000, option_callback_none);
    addSpinOption("nodestime", 0, 0, 10000, option_callback_none);
    addCheckOption("UCI_Chess960", 0);
    addCheckOption("UCI_LimitStrength", 0);
    addSpinOption("UCI_Elo", lowest_elo, lowest_elo, highest_elo, option_callback_none);
    addCheckOption("UCI_ShowWDL", 0);
    addStringOption("SyzygyPath", "", option_callback_syzygy_path);
    addSpinOption("SyzygyProbeDepth", 1, 1, 100, option_callback_none);
    addCheckOption("Syzygy50MoveRule", 1);
    addSpinOption("SyzygyProbeLimit", 7, 0, 7, option_callback_none);
    addStringOption("EvalFile", default_eval_file_name, option_callback_eval_file);

    setStartPosition(e);
    resizeThreadsEngine(e);
}

pub fn optionOnChange(
    engine_ptr: *native_engine.NativeEngine,
    callback_kind: u8,
    value_ptr: [*]const u8,
    value_len: usize,
    int_value: c_int,
) ?[*:0]u8 {
    const value = value_ptr[0..value_len];

    return switch (callback_kind) {
        option_callback_debug_log_file => blk: {
            uci_output.startLogger(value.ptr, value.len);
            break :blk null;
        },
        option_callback_numa_policy => blk: {
            setNumaConfigFromOptionEngine(engine_ptr, value);

            const numa_info_ptr = numaConfigInformationEngine(engine_ptr) orelse break :blk null;
            defer c.free(@ptrCast(numa_info_ptr));

            const thread_info_ptr = threadAllocationInformationEngine(engine_ptr) orelse break :blk null;
            defer c.free(@ptrCast(thread_info_ptr));

            break :blk allocMessage("{s}\n{s}", .{ std.mem.span(numa_info_ptr), std.mem.span(thread_info_ptr) });
        },
        option_callback_threads => blk: {
            resizeThreadsEngine(engine_ptr);
            break :blk threadAllocationInformationEngine(engine_ptr);
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
            loadNetworkEngine(engine_ptr, value.ptr[0..value.len]);
            break :blk null;
        },
        else => null,
    };
}

pub fn setPosition(
    pos: *position_port.Position,
    states_slot: *anyopaque,
    chess960_enabled: u8,
    fen_ptr: [*]const u8,
    fen_len: usize,
    moves_ptr: ?[*]const ByteView,
    move_count: usize,
) ?[*:0]u8 {
    const state_storage = ensurePendingStateStorage(states_slot);
    const root_state = state_list.storageReset(state_storage);

    if (position_port.setPositionState(pos, fen_ptr, fen_len, chess960_enabled, root_state)) |err| {
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

        const next_state = state_list.storagePush(state_storage);
        position_port.doMoveState(pos, move_raw, next_state);
    }

    return null;
}

pub fn setPositionEngine(
    engine_ptr: *native_engine.NativeEngine,
    fen_ptr: [*]const u8,
    fen_len: usize,
    moves_ptr: ?[*]const ByteView,
    move_count: usize,
) ?[*:0]u8 {
    const states_slot = engine_ptr.statesSlotPtr();
    statesSlotReset(states_slot);

    return setPosition(
        engine_ptr.positionPtr(),
        states_slot,
        @intFromBool(option_port.uciChess960()),
        fen_ptr,
        fen_len,
        moves_ptr,
        move_count,
    );
}

pub fn pendingStatesAvailable(states_slot: *anyopaque) u8 {
    const state_storage = lookupPendingStateStorage(@intFromPtr(states_slot)) orelse return 0;
    return @intFromBool(state_list.storageHasStates(state_storage));
}

pub fn handoffPendingStates(pool: *anyopaque, states_slot: *anyopaque) u8 {
    const state_storage = lookupPendingStateStorage(@intFromPtr(states_slot)) orelse return 0;
    if (!state_list.storageHasStates(state_storage))
        return 0;

    native_hooks.setup_states_adopt_from_storage(pool, state_storage);
    return @intFromBool(graph_layout.ThreadPool.fromPtr(@constCast(pool)).hasSetupStates());
}

pub fn releasePendingStateSlot(states_slot: *anyopaque) void {
    if (removePendingStateStorage(@intFromPtr(states_slot))) |state_storage| {
        state_list.storageDestroy(state_storage);
    }
}

pub fn stop(threads: *graph_layout.ThreadPool) void {
    threads.setStop(true);
}

pub fn stopEngine(engine_ptr: *native_engine.NativeEngine) void {
    stop(engine_ptr.threadsPtr());
}

pub fn waitForSearchFinishedEngine(engine_ptr: *native_engine.NativeEngine) void {
    thread_port.waitThread(engine_ptr.threadsPtr(), 0);
}

// Print each non-blank line as "info string ...". Relocated from main.zig (M16.7).
// NNUE network lifecycle (verifyNetwork/loadNetworkEngine/saveNetworkEngine) +
// printInfoStringNative live in the engine_nnue leaf (M17.3z); saveNetworkEngine is
// re-exported (external), the rest aliased for the go/perft/option-apply callers.
const engine_nnue = @import("engine_nnue");
const printInfoStringNative = engine_nnue.printInfoStringNative;
pub const verifyNetwork = engine_nnue.verifyNetwork;
pub const loadNetworkEngine = engine_nnue.loadNetworkEngine;
pub const saveNetworkEngine = engine_nnue.saveNetworkEngine;

// NUMA/thread info formatters live in the engine_infofmt leaf (M17.3y); aliased
// for the threadBindingInformation/threadAllocationInformation gatherers.
const engine_infofmt = @import("engine_infofmt");
const formatNumaInfo = engine_infofmt.formatNumaInfo;
const formatThreadBinding = engine_infofmt.formatThreadBinding;
const formatThreadAllocation = engine_infofmt.formatThreadAllocation;

// Eval-trace / visualize / snapshot cluster lives in the engine_trace leaf
// (M17.4a); the external entry points + pub trace types are re-exported, and `fen`
// is aliased for the perft/flip callers.
const engine_trace = @import("engine_trace");
pub const PositionSummary = engine_trace.PositionSummary;
pub const TablebaseProbe = engine_trace.TablebaseProbe;
pub const EvalInput = engine_trace.EvalInput;
pub const EvalOutput = engine_trace.EvalOutput;
pub const TraceOutput = engine_trace.TraceOutput;
pub const EvalTraceInput = engine_trace.EvalTraceInput;
pub const NnueTraceInput = engine_trace.NnueTraceInput;
pub const traceEvalEngine = engine_trace.traceEvalEngine;
pub const visualizeEngine = engine_trace.visualizeEngine;
pub const fenEngine = engine_trace.fenEngine;
pub const accumulatorCachesCreate = engine_trace.accumulatorCachesCreate;
const fen = engine_trace.fen;

// Perft driver lives in the engine_perft leaf (M17.4b); re-exported for uci `go perft`.
const engine_perft = @import("engine_perft");
pub const perftEngine = engine_perft.perftEngine;

// Option-registration helpers live in the engine_options leaf (M17.4c); aliased
// for initBody.
const engine_options = @import("engine_options");
const addStringOption = engine_options.addStringOption;
const addCheckOption = engine_options.addCheckOption;
const addSpinOption = engine_options.addSpinOption;
const addButtonOption = engine_options.addButtonOption;

// setoption apply: wait for the search, set into the native OptionsModel, and run the
// on-change callback (relaying string/spin/check values). Relocated from main.zig (M16.7).
pub fn applySetOptionEngine(engine_ptr: *native_engine.NativeEngine, name_ptr: [*]const u8, name_len: usize, value_ptr: [*]const u8, value_len: usize, has_value: u8) void {
    waitForSearchFinishedEngine(engine_ptr);
    const vlen: usize = if (has_value != 0) value_len else 0;
    const vptr: [*]const u8 = if (has_value != 0) value_ptr else name_ptr;
    var res: option_port.ModelSetResult = undefined;
    option_port.setByName(name_ptr[0..name_len], vptr[0..vlen], &res);
    if (res.found == 0) {
        var buf: [256]u8 = undefined;
        const out = std.fmt.bufPrint(&buf, "No such option: {s}", .{name_ptr[0..name_len]}) catch return;
        uci_output.printLine(out.ptr, out.len);
        return;
    }
    if (res.accepted != 0 and res.callback_kind != 0) {
        var relay_buf: [32]u8 = undefined;
        var relay_value: []const u8 = "";
        var relay_int: c_int = 0;
        if (res.kind == 1 or res.kind == 2) {
            relay_int = option_port.intByIndex(res.idx);
            relay_value = std.fmt.bufPrint(&relay_buf, "{d}", .{relay_int}) catch "";
        } else if (res.kind == 0) {
            const len = option_port.currentLen(res.idx);
            if (len != 0) {
                if (option_port.currentPtr(res.idx)) |p| relay_value = p[0..len];
            }
        }
        const ret = optionOnChange(engine_ptr, res.callback_kind, relay_value.ptr, relay_value.len, relay_int);
        if (ret) |msg| {
            printInfoStringNative(std.mem.span(msg));
            std.c.free(@ptrCast(msg));
        }
    }
}

pub fn goEngine(engine_ptr: *native_engine.NativeEngine, limits_ptr: *const graph_layout.LimitsType) void {
    std.debug.assert(limits_ptr.perftValue() == 0);
    verifyNetwork();
    thread_port.startThinking(
        engine_ptr.threadsPtr(),
        engine_ptr.positionPtr(),
        limits_ptr,
        engine_ptr.statesSlotPtr(),
    );
}

pub fn setNumaConfigFromOptionEngine(engine_ptr: *native_engine.NativeEngine, option_text: []const u8) void {
    const numa_context = engine_ptr.numaContextPtr();

    if (std.mem.eql(u8, option_text, "auto") or std.mem.eql(u8, option_text, "system")) {
        numa.contextSetSystem(numa_context);
    } else if (std.mem.eql(u8, option_text, "hardware")) {
        numa.contextSetHardware(numa_context);
    } else if (std.mem.eql(u8, option_text, "none")) {
        numa.contextSetNone(numa_context);
    } else {
        numa.setFromString(numa_context, option_text.ptr, option_text.len);
    }

    resizeThreadsEngine(engine_ptr);
}

pub fn resizeThreads(
    numa_context: *const anyopaque,
    options: *const anyopaque,
    threads: *graph_layout.ThreadPool,
    tt: *graph_layout.TranspositionTable,
    shared_hists: *anyopaque,
    network: *const anyopaque,
    update_context: *const anyopaque,
) void {
    thread_port.waitForSearchFinished(threads);

    const shared_state = sharedStateCreate(
        @constCast(options),
        threads,
        tt,
        shared_hists,
        @constCast(network),
    );
    defer sharedStateDestroy(shared_state);

    thread_port.reconfigure(
        threads,
        numa.contextConfig(numa_context),
        shared_state,
        update_context,
    );

    setTtSize(threads, tt, option_port.optionHash());
    thread_port.ensureNetworkReplicated(threads);
}

pub fn resizeThreadsEngine(engine_ptr: *native_engine.NativeEngine) void {
    resizeThreads(
        engine_ptr.numaContextPtr(),
        engine_ptr.optionsPtr(),
        engine_ptr.threadsPtr(),
        engine_ptr.ttPtr(),
        sharedHistoriesPtr(),
        engine_ptr.networkPtr(),
        engine_ptr.updateContextPtr(),
    );
}

// Native SharedHistoriesMap (the post-src/ replacement for std::map<NumaIndex,
// SharedHistories>), engine-owned side storage.
// The engine is a gate singleton, so a lazily-built module global suffices; the
// map pointer flows into SharedState.sharedHistories, and the clear/insert/at
// bridge sites operate on that same pointer. Each element (SharedHistories: two
// large-page DynStats arrays) is built by constructSharedHistories / freed by
// deinitSharedHistories; the bucket storage uses the c allocator.
var side_shared_histories: ?position_port.SharedHistoriesMap = null;

fn sideSharedHistories() *position_port.SharedHistoriesMap {
    if (side_shared_histories == null) {
        side_shared_histories = position_port.SharedHistoriesMap.init(
            std.heap.c_allocator,
            position_port.constructSharedHistories,
            position_port.deinitSharedHistories,
        );
    }
    return &side_shared_histories.?;
}

pub fn sharedHistoriesPtr() *anyopaque {
    return @ptrCast(sideSharedHistories());
}

pub fn sharedHistoriesClear(map: *position_port.SharedHistoriesMap) void {
    map.clear();
}

pub fn sharedHistoriesInsert(map: *position_port.SharedHistoriesMap, numa_index: usize, size: usize) void {
    map.tryEmplace(numa_index, size) catch @panic("OOM: native sharedHistories insert");
}

pub fn sharedHistoriesAt(map: *position_port.SharedHistoriesMap, numa_index: usize) *position_port.SharedHistories {
    return map.at(numa_index);
}

// Free the side map (each element's large-page DynStats arrays + the bucket
// storage) at engine teardown + reset for any re-construct (H5/valgrind).
pub fn freeSharedHistories() void {
    if (side_shared_histories) |*m| {
        m.deinit();
        side_shared_histories = null;
    }
}

// TT lifecycle + engine setup helpers, reached through the typed
// TranspositionTable view + the tt/state_list modules this module already imports.
fn ttResize(tt_ptr: *graph_layout.TranspositionTable, mb: usize, threads: *graph_layout.ThreadPool) void {
    const tp = tt_ptr;
    tt_port.resizeState(&tp.table, &tp.cluster_count, &tp.generation8, mb, threads);
}
fn ttClear(tt_ptr: *graph_layout.TranspositionTable, threads: *graph_layout.ThreadPool) void {
    const tp = tt_ptr;
    tt_port.clearState(tp.table, tp.cluster_count, &tp.generation8, threads);
}
fn statesSlotReset(slot_ptr: *anyopaque) void {
    const slot: *?*state_list.StateList = @ptrCast(@alignCast(slot_ptr));
    if (slot.*) |list| {
        state_list.destroyStateList(std.heap.c_allocator, list);
        slot.* = null;
    }
}
fn setStartPosition(engine_ptr: *native_engine.NativeEngine) void {
    const start_fen: []const u8 = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1";
    if (setPositionEngine(engine_ptr, start_fen.ptr, start_fen.len, null, 0)) |_|
        @panic("set start position failed");
}

// Accumulator stack/caches lifecycle (M16.7 -- malloc'd engine-graph buffers). The refresh-cache
// biases come from the native FT storage (network.zig), so the create path is fully engine-local.

pub fn setTtSize(threads: *graph_layout.ThreadPool, tt: *graph_layout.TranspositionTable, mb: usize) void {
    thread_port.waitThread(threads, 0);
    ttResize(tt, mb, threads);
}

pub fn setTtSizeEngine(engine_ptr: *native_engine.NativeEngine, mb: usize) void {
    setTtSize(engine_ptr.threadsPtr(), engine_ptr.ttPtr(), mb);
}

pub fn setPonderhit(threads: *graph_layout.ThreadPool, ponder: u8) void {
    if (threads.mainManager()) |m| m.setPonder(ponder != 0);
}

pub fn setPonderhitEngine(engine_ptr: *native_engine.NativeEngine, ponder: u8) void {
    setPonderhit(engine_ptr.threadsPtr(), ponder);
}

pub fn searchClear(threads: *graph_layout.ThreadPool, tt: *graph_layout.TranspositionTable, syzygy_path: []const u8) void {
    thread_port.waitForSearchFinished(threads);
    ttClear(tt, threads);
    thread_port.clear(threads);
    tablebase.init(syzygy_path.ptr, syzygy_path.len);
}

pub fn searchClearEngine(engine_ptr: *native_engine.NativeEngine) void {
    const syzygy_ptr = option_port.dupSyzygyPath() orelse return;
    defer c.free(@ptrCast(syzygy_ptr));
    searchClear(
        engine_ptr.threadsPtr(),
        engine_ptr.ttPtr(),
        std.mem.span(syzygy_ptr),
    );
}

pub fn numaConfigStringEngine(engine_ptr: *native_engine.NativeEngine) ?[*:0]u8 {
    _ = engine_ptr;
    const config_ptr = numa.configString() orelse return null;
    defer c.free(@ptrCast(config_ptr));
    return allocMessage("{s}", .{std.mem.span(config_ptr)});
}

pub fn numaConfigInformationEngine(engine_ptr: *native_engine.NativeEngine) ?[*:0]u8 {
    _ = engine_ptr;
    const config_ptr = numa.configString() orelse return null;
    defer c.free(@ptrCast(config_ptr));
    const config = std.mem.span(config_ptr);
    return formatNumaInfo(config.ptr, config.len);
}

pub fn threadBindingInformationEngine(engine_ptr: *native_engine.NativeEngine) ?[*:0]u8 {
    return threadBindingInformation(
        engine_ptr.numaContextPtr(),
        engine_ptr.threadsPtr(),
    );
}

pub fn threadAllocationInformationEngine(engine_ptr: *native_engine.NativeEngine) ?[*:0]u8 {
    return threadAllocationInformation(
        engine_ptr.numaContextPtr(),
        engine_ptr.threadsPtr(),
    );
}

fn ensurePendingStateStorage(states_slot: *anyopaque) *PendingStateStorage {
    const slot_key = @intFromPtr(states_slot);

    if (findPendingStateIndex(slot_key)) |index| {
        return pending_state_entries.items[index].storage;
    }

    const state_storage = state_list.storageCreate() orelse @panic("OOM");
    pending_state_entries.append(std.heap.c_allocator, .{
        .slot_key = slot_key,
        .storage = state_storage,
    }) catch {
        state_list.storageDestroy(state_storage);
        @panic("OOM");
    };

    return state_storage;
}

fn lookupPendingStateStorage(slot_key: usize) ?*PendingStateStorage {
    if (findPendingStateIndex(slot_key)) |index| {
        return pending_state_entries.items[index].storage;
    }

    return null;
}

fn removePendingStateStorage(slot_key: usize) ?*PendingStateStorage {
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

// `go perft N` root divide: build a scratch Position +
// StateInfo, set the engine FEN, generate the legal root moves, run the native perft subtree
// per move, print "<move>: <count>" then the "Nodes searched: N" total (byte-exact vs the C++
// divide -- the `perft` gate diffs it). engine + movegen + position + uci_move + uci_output.

// Engine::flip -> read the live FEN, flip it, re-set the position. Relocated from
// main.zig (M16.7); all native (engine fen + position flipFen + setPosition).
pub fn flipEngine(engine_ptr: *native_engine.NativeEngine) void {
    const fen_c = fen(engine_ptr.positionPtr()) orelse return;
    defer c.free(@ptrCast(fen_c));
    const fen_text = std.mem.span(fen_c);
    const flipped_c = position_port.flipFen(fen_text.ptr, fen_text.len) orelse return;
    defer c.free(@ptrCast(flipped_c));
    const flipped = std.mem.span(flipped_c);
    if (setPositionEngine(engine_ptr, flipped.ptr, flipped.len, null, 0)) |err|
        c.free(@ptrCast(err));
}

pub fn hashfullEngine(engine_ptr: *native_engine.NativeEngine, max_age: c_int) c_int {
    const tp = engine_ptr.ttPtr();
    const table = tp.table orelse return 0;
    return tt_port.hashfull(@ptrCast(@alignCast(table)), tp.cluster_count, tp.generation8, max_age);
}

pub fn threadBindingInformation(
    numa_context: *const anyopaque,
    threads: *graph_layout.ThreadPool,
) ?[*:0]u8 {
    const bound_count = threads.boundCount();
    if (bound_count == 0)
        return allocMessage("", .{});

    const allocator = std.heap.c_allocator;
    const node_count = numa.contextNodeCount(numa_context);

    const counts = allocator.alloc(usize, node_count) catch return null;
    defer allocator.free(counts);
    @memset(counts, 0);

    var index: usize = 0;
    while (index < bound_count) : (index += 1) {
        const node = threads.boundAt(index);
        if (node < node_count)
            counts[node] += 1;
    }

    const pairs = allocator.alloc(CountPair, node_count) catch return null;
    defer allocator.free(pairs);

    index = 0;
    while (index < node_count) : (index += 1) {
        pairs[index] = .{
            .current = counts[index],
            .total = numa.contextCpusInNode(numa_context, index),
        };
    }

    return formatThreadBinding(pairs.ptr, pairs.len);
}

pub fn threadAllocationInformation(
    numa_context: *const anyopaque,
    threads: *graph_layout.ThreadPool,
) ?[*:0]u8 {
    const binding_ptr = threadBindingInformation(numa_context, threads) orelse return null;
    defer c.free(@ptrCast(binding_ptr));

    const binding = std.mem.span(binding_ptr);
    return formatThreadAllocation(threads.numThreads(), binding.ptr, binding.len);
}

// Register one option into the native OptionsModel.
// The engine handle + callback kind are unused (the model holds no per-option callback);
// spin/check defaults are rendered to the model's string form.
