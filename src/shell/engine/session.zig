//! Drive the session, split out of engine.zig.
//!
//! Split engine.zig's two roles: a namespace *face* (the `pub const X = leaf.Y`
//! re-export blocks that present the `shell/engine/` leaves as one `engine.` surface)
//! and the *session driver* (the command-handler call graph that runs one UCI session:
//! option registration + on-change dispatch, position setup, the `go`/perft entry, and
//! the thread/NUMA/SharedState reconfigure chain). Keep this file as the driver; engine.zig
//! keeps the face and re-exports the driver's entry points, so external callers still
//! reach `engine.initBody` / `engine.goEngine` / `engine.SharedState` unchanged.
//!
//! Depend only on the engine-graph named modules + the `shell/engine/` leaves; nothing
//! imports the shell facade (the headless invariant keeps every edge one-way), so the
//! SharedState instantiation here -- which must see all five referent types -- cannot be
//! in a cycle. Duplicate `freeCString` (a 3-line sentinel free) so the driver needs
//! no engine.zig import, keeping the face->driver edge one-way.

const std = @import("std");

const position_port = @import("position");
const search_driver = @import("search_driver");
const uci_move = @import("uci_move");
const misc_port = @import("misc");
const thread_port = @import("thread");
const worker_layout = @import("worker_layout");
const tablebase = @import("tablebase");
const option_port = @import("option");
const state_list = @import("state_list");
const tt_port = @import("tt");
const numa = @import("numa");
const uci_output = @import("uci_output");
const engine_object = @import("engine_object");
const network_port = @import("network");
const shared_state_mod = @import("shared_state");

// Import the `shell/engine/` leaves the driver calls into (the face re-exports the same leaves
// for external callers; a module is a singleton, so importing it here too is free).
// Reach shared_histories/pending/info/control as path-leaves of the engine module (same dir);
// util/nnue/options/trace are named modules with their own build.zig dep sets.
const engine_shared_histories = @import("shared_histories.zig");
const engine_pending = @import("pending.zig");
const engine_info = @import("info.zig");
const engine_control = @import("control.zig");
const engine_nnue = @import("engine_nnue");
const engine_util = @import("engine_util");
const engine_options = @import("engine_options");
const engine_trace = @import("engine_trace");

const sharedHistoriesPtr = engine_shared_histories.sharedHistoriesPtr;
const ensurePendingStateStorage = engine_pending.ensurePendingStateStorage;
const numaConfigInformationEngine = engine_info.numaConfigInformationEngine;
const threadAllocationInformationEngine = engine_info.threadAllocationInformationEngine;
const setTtSize = engine_control.setTtSize;
const setTtSizeEngine = engine_control.setTtSizeEngine;
const searchClearEngine = engine_control.searchClearEngine;
const waitForSearchFinishedEngine = engine_control.waitForSearchFinishedEngine;
const printInfoString = engine_nnue.printInfoString;
const verifyNetwork = engine_nnue.verifyNetwork;
const requireNetworkLoaded = engine_nnue.requireNetworkLoaded;
const loadNetworkEngine = engine_nnue.loadNetworkEngine;
const ByteView = engine_util.ByteView;
const allocMessage = engine_util.allocMessage;
const addStringOption = engine_options.addStringOption;
const addCheckOption = engine_options.addCheckOption;
const addSpinOption = engine_options.addSpinOption;
const addButtonOption = engine_options.addButtonOption;
const fen = engine_trace.fen;

// Free a c_allocator-allocated NUL-terminated string through the Allocator
// interface, exact for these tightly-sized sentinel allocations.
fn freeCString(ptr: [*:0]u8) void {
    std.heap.c_allocator.free(std.mem.span(ptr));
}

// Cast an engine handle to the container.
inline fn ne(p: *const anyopaque) *engine_object.EngineObject {
    return engine_object.EngineObject.fromPtr(@constCast(p));
}

// Instantiate the ONE concrete SharedState bundle. The driver is a graph
// root that sees all referent types (nothing imports the shell facade, so this can't
// be in a cycle); shared_state.zig stays a pure std leaf via the injected comptime
// types. Give the bundle's typed pointers a fixed layout the worker-build reinterpret
// relies on (asserted by the @sizeOf check below).
pub const SharedState = shared_state_mod.SharedStateOf(
    worker_layout.ThreadPool,
    tt_port.TranspositionTable,
    search_driver.SharedHistoriesMap,
);

comptime {
    std.debug.assert(@sizeOf(SharedState) == 24);
}

// Run one engine, one search at a time (sequential go commands; workers only READ the
// bundle during a search), so a single static provides its lifetime without an
// allocator. Rebuild it per search, never alias it.
var live_shared_state: SharedState = undefined;

/// Build the live SharedState from the five referent handles and return its address.
/// The handles arrive erased across the reconfigure hook ABI; cast each to its typed
/// pointer once here (the storage boundary) so every downstream read is typed.
fn sharedStateCreate(
    threads: *worker_layout.ThreadPool,
    tt: *worker_layout.TranspositionTable,
    shared_histories: *search_driver.SharedHistoriesMap,
) *anyopaque {
    live_shared_state = SharedState.init(
        threads,
        @ptrCast(@alignCast(tt)),
        shared_histories,
    );
    return @ptrCast(&live_shared_state);
}

fn sharedStateDestroy(ss: *anyopaque) void {
    _ = ss; // static storage — nothing to free (lifetime is the static itself)
}

const option_callback_none: u8 = 0;
const option_callback_debug_log_file: u8 = 1;
const option_callback_numa_policy: u8 = 2;
const option_callback_threads: u8 = 3;
const option_callback_hash: u8 = 4;
const option_callback_clear_hash: u8 = 5;
const option_callback_syzygy_path: u8 = 6;
const option_callback_eval_file: u8 = 7;

// Single-source from network.zig via the "network" module (build.zig wires the
// engine->network edge). Avoid the net-name-drift bug of two copies.
const default_eval_file_name = network_port.default_eval_file_name;
const default_skill_lowest_elo: c_int = 1320;
const default_skill_highest_elo: c_int = 3190;

pub fn initBody(engine_ptr: *anyopaque) void {
    // Sit at the construction boundary: main hands the engine as a raw buffer; keep
    // the *anyopaque ABI and cast once here to drive the typed init entries below.
    const e: *engine_object.EngineObject = ne(engine_ptr);
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

    // Fire the startup net load by adding EvalFile (its callback). Everything
    // below needs the net: resizeThreadsEngine builds the Workers, and worker
    // construction reads the feature-transformer biases. A missed load is silent
    // (network.load returns void), so check it HERE -- between the load and the first
    // code that requires it -- rather than letting it surface as a null unwrap on a
    // worker thread. No-op when the net loaded, so bench/parity are untouched.
    requireNetworkLoaded(e);

    setStartPosition(e);
    resizeThreadsEngine(e);
}

pub fn optionOnChange(
    engine_ptr: *engine_object.EngineObject,
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
            defer freeCString(numa_info_ptr);

            const thread_info_ptr = threadAllocationInformationEngine(engine_ptr) orelse break :blk null;
            defer freeCString(thread_info_ptr);

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
            // Print this whenever a path is set (even when 0 found), matching SF `Tablebases::init`.
            if (value.len != 0) {
                var buf: [96]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "Found {d} WDL and {d} DTZ tablebase files (up to {d}-man).", .{ tablebase.foundWdl(), tablebase.foundDtz(), tablebase.discoveredMax() }) catch break :blk null;
                printInfoString(msg);
            }
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
    const state_storage = ensurePendingStateStorage(states_slot) orelse
        return allocMessage("out of memory", .{});
    const root_state = state_storage.reset() catch return allocMessage("out of memory", .{});

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

        const next_state = state_storage.push() catch return allocMessage("out of memory", .{});
        position_port.doMoveState(pos, move_raw, next_state);
    }

    return null;
}

pub fn setPositionEngine(
    engine_ptr: *engine_object.EngineObject,
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

// Apply setoption: wait for the search, set into the OptionsModel, and run the
// on-change callback (relaying string/spin/check values).
pub fn applySetOptionEngine(engine_ptr: *engine_object.EngineObject, name_ptr: [*]const u8, name_len: usize, value_ptr: [*]const u8, value_len: usize, has_value: u8) void {
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
            printInfoString(std.mem.span(msg));
            freeCString(msg);
        }
    }
}

pub fn goEngine(engine_ptr: *engine_object.EngineObject, limits_ptr: *const worker_layout.LimitsType) void {
    std.debug.assert(limits_ptr.perftValue() == 0);
    verifyNetwork();
    // Handle startThinking's root-move setup OOM here (selected-moves / root-fen / RootMoves /
    // per-thread contexts): it now propagates OOM as `!void`, and this is the single handling
    // boundary for the `go` path. A search that cannot allocate its root setup is
    // unrecoverable, so fail loudly here instead of `catch @panic("OOM")` in each leaf.
    thread_port.startThinking(
        engine_ptr.threadsPtr(),
        engine_ptr.positionPtr(),
        limits_ptr,
        engine_ptr.statesSlotPtr(),
    ) catch @panic("OOM: search setup failed");
}

pub fn setNumaConfigFromOptionEngine(engine_ptr: *engine_object.EngineObject, option_text: []const u8) void {
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
    threads: *worker_layout.ThreadPool,
    tt: *worker_layout.TranspositionTable,
    shared_hists: *search_driver.SharedHistoriesMap,
    update_context: *const anyopaque,
) !void {
    thread_port.waitForSearchFinished(threads);

    const shared_state = sharedStateCreate(
        threads,
        tt,
        shared_hists,
    );
    defer sharedStateDestroy(shared_state);

    try thread_port.reconfigure(
        threads,
        numa.contextConfig(numa_context),
        shared_state,
        update_context,
    );

    setTtSize(threads, tt, option_port.optionHash());
    thread_port.ensureNetworkReplicated(threads);
}

pub fn resizeThreadsEngine(engine_ptr: *engine_object.EngineObject) void {
    // Handle the resize chain's errors here (reconfigure -> thread_pool.set/boundNodesAssign):
    // it now propagates OOM / thread-spawn errors as `!void`, and this is the engine's single
    // handling boundary. A UCI Threads/NumaPolicy change or init that cannot allocate
    // its thread pool is unrecoverable, so fail loudly here instead of scattering
    // `catch @panic("OOM")` across every leaf allocation.
    resizeThreads(
        engine_ptr.numaContextPtr(),
        engine_ptr.threadsPtr(),
        engine_ptr.ttPtr(),
        sharedHistoriesPtr(),
        engine_ptr.updateContextPtr(),
    ) catch @panic("OOM: thread pool resize failed");
}

// Provide TT lifecycle + engine setup helpers, reached through the typed
// TranspositionTable view + the tt/state_list modules this module already imports.
fn statesSlotReset(slot_ptr: *anyopaque) void {
    const slot: *?*state_list.StateList = @ptrCast(@alignCast(slot_ptr));
    if (slot.*) |list| {
        state_list.destroyStateList(std.heap.c_allocator, list);
        slot.* = null;
    }
}

fn setStartPosition(engine_ptr: *engine_object.EngineObject) void {
    const start_fen: []const u8 = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1";
    if (setPositionEngine(engine_ptr, start_fen.ptr, start_fen.len, null, 0)) |_|
        @panic("set start position failed");
}

// Run the flip command: read the live FEN, flip it, re-set the position. Keep it all
// engine-local (engine fen + position flipFen + setPosition).
// Return the position error rather than swallowing it, mirroring upstream's
// `std::optional<PositionSetError> Engine::flip()` (engine.cpp:339). The error was
// obtained from setPositionEngine and then FREED AND DISCARDED, so a flip that produced
// an unusable position reported nothing and left the engine on the old board. The caller
// terminates on it, as upstream's uci.cpp:147 does.
pub fn flipEngine(engine_ptr: *engine_object.EngineObject) ?[*:0]u8 {
    const fen_c = fen(engine_ptr.positionPtr()) orelse return null;
    defer freeCString(fen_c);
    const fen_text = std.mem.span(fen_c);
    const flipped_c = position_port.flipFen(fen_text.ptr, fen_text.len) orelse return null;
    defer freeCString(flipped_c);
    const flipped = std.mem.span(flipped_c);
    return setPositionEngine(engine_ptr, flipped.ptr, flipped.len, null, 0);
}
