//! Probe Syzygy WDL/DTZ. Port Stockfish's `do_probe_table` (position ->
//! unique index -> value), `probe_table`, `probe_wdl` (search<false> capture recursion),
//! `probe_dtz`, and `map_score` faithfully. Tie the position->index geometry (encode.zig), the data model
//! (probe.zig), and the RE-PAIR decoder (decode.zig) together, indexing through the tables that
//! `registry.zig` owns and lazily maps.
//!
//! Keep the position->index encoder (`do_probe_table` and the geometry it walks) in
//! `probe_index.zig`, the registry (material key -> TBTable) in `registry.zig` and the file
//! load in `table_load.zig`; this file imports all three downward and never the reverse.
//! Registry keys are bit-identical to a probed position's `pos.st.material_key`.
//!
//! Cross the platform->engine down-edge (the harness may depend on the engine): the probe reaches the headless
//! engine for a scratch Position (FEN parse), its material key + piece bitboards, and legal-capture
//! movegen for the capture recursion.

const std = @import("std");

const registry = @import("registry.zig");
const table_load = @import("table_load.zig");
const probe = @import("probe.zig");
const decode = @import("decode.zig");
const encode = @import("encode.zig");
const probe_index = @import("probe_index.zig");

const position = @import("position");
const board_core = @import("board_core");
const state_list = @import("state_list");
const movegen = @import("movegen");

const Position = position.Position;
const TBTable = registry.TBTable;
const PairsData = probe.PairsData;

const ProbeResult = @import("tb_source").ProbeResult;

// SF PieceType encodings (via board_core): W pawn=1..king=6.
const pawn_pt = board_core.pawn_pt;

// ---- probe_table + probe_wdl (search) + probe_dtz ---------------------------

// Alias the ProbeState and WDLScore constants from the index encoder, which owns them: it is
// the lower file, so a definition here would make the two import each other.
const probe_fail = probe_index.probe_fail;
const probe_ok = probe_index.probe_ok;
const probe_zeroing = probe_index.probe_zeroing;
const change_stm = probe_index.change_stm;
const wdl_win = probe_index.wdl_win;
const wdl_cursed_win = probe_index.wdl_cursed_win;
const wdl_draw = probe_index.wdl_draw;
const wdl_blessed_loss = probe_index.wdl_blessed_loss;
const wdl_loss = probe_index.wdl_loss;

const Probe = struct { value: i32, state: i32 };

// Port SF probe_table, generic over WDL/DTZ: KvK short-circuit, registry lookup, lazy map, do_probe.
fn probeTable(pos: *const Position, comptime dtz: bool, wdl_score: i32, out_state: *i32) i32 {
    if (@popCount(pos.by_type_bb[0]) == 2) return 0; // KvK draw
    const t = registry.hashGet(pos.st.material_key) orelse {
        out_state.* = probe_fail;
        return 0;
    };
    const ok = if (dtz) table_load.mappedDtz(t) else table_load.mapped(t);
    if (!ok) {
        out_state.* = probe_fail;
        return 0;
    }
    return probe_index.doProbeTable(pos, t, dtz, wdl_score, out_state);
}

fn isCapture(pos: *const Position, m: u16) bool {
    const to = board_core.moveTo(m);
    const mt = board_core.moveTypeOf(m);
    return (pos.board[to] != 0 and mt != board_core.mt_castling) or mt == board_core.mt_en_passant;
}

inline fn movedPieceType(pos: *const Position, m: u16) u8 {
    return pos.board[board_core.moveFrom(m)] & 7;
}

fn signOf(x: i32) i32 {
    return @as(i32, @intFromBool(x > 0)) - @intFromBool(x < 0);
}

// Port SF dtz_before_zeroing: recover the DTZ of the move before a zeroing (capture/pawn) move.
fn dtzBeforeZeroing(wdl: i32) i32 {
    return switch (wdl) {
        wdl_win => 1,
        wdl_cursed_win => 101,
        wdl_blessed_loss => -101,
        wdl_loss => -1,
        else => 0,
    };
}

// Port SF search<CheckZeroingMoves>: the "best of the position and its winning/drawing zeroing moves"
// recursion. A capture (and, when check_zeroing, a pawn move) zeroes the rule50 counter, so its
// result must be probed and compared to the position's own stored value. Children recurse with
// check_zeroing=false. `storage` supplies one StateInfo per recursion frame (reused across sibs).
fn searchWdl(pos: *Position, storage: *state_list.PendingStateStorage, comptime check_zeroing: bool) Probe {
    var best: i32 = wdl_loss;
    var move_count: usize = 0;
    var buf: [256]u16 = undefined;
    const total = movegen.generateLegal(pos, buf[0..]);

    const st = state_list.storagePush(storage) catch return .{ .value = 0, .state = probe_fail };

    var i: usize = 0;
    while (i < total) : (i += 1) {
        const m = buf[i];
        if (!isCapture(pos, m) and (!check_zeroing or movedPieceType(pos, m) != pawn_pt)) continue;
        move_count += 1;
        position.doMoveState(pos, m, st);
        const child = searchWdl(pos, storage, false);
        position.undoMove(pos, m);
        if (child.state == probe_fail) return .{ .value = 0, .state = probe_fail };
        const v = -child.value;
        if (v > best) {
            best = v;
            if (v >= wdl_win) return .{ .value = v, .state = probe_zeroing }; // winning zeroing move
        }
    }

    // Use bestValue instead of probing when every legal move is a zeroing move and all were
    // searched: the stored value could be wrong (ep rights, all-captures).
    const no_more_moves = move_count != 0 and move_count == total;
    var value: i32 = undefined;
    if (no_more_moves) {
        value = best;
    } else {
        var st_probe: i32 = probe_ok;
        value = probeTable(pos, false, 0, &st_probe);
        if (st_probe == probe_fail) return .{ .value = 0, .state = probe_fail };
    }

    // Prefer bestValue when it dominates: DTZ stores a "don't care" when bestValue is a win.
    if (best >= value) {
        const state: i32 = if (best > 0 or no_more_moves) probe_zeroing else probe_ok;
        return .{ .value = best, .state = state };
    }
    return .{ .value = value, .state = probe_ok };
}

// Port SF probe_dtz: DTZ from the side-to-move's view. Use search<true> to fold in zeroing pawn moves,
// then probe_table<DTZ>; the CHANGE_STM branch does a 1-ply search that minimizes DTZ (the DTZ
// table stored the other side, so we step one move and read the resulting DTZ).
fn probeDtz(pos: *Position, storage: *state_list.PendingStateStorage, out_state: *i32) i32 {
    out_state.* = probe_ok;
    const w = searchWdl(pos, storage, true);
    if (w.state == probe_fail) {
        out_state.* = probe_fail;
        return 0;
    }
    const wdl = w.value;
    if (wdl == wdl_draw) return 0; // Return 0 -- DTZ tables don't store draws
    if (w.state == probe_zeroing) return dtzBeforeZeroing(wdl); // best move is a winning zeroing move

    var st: i32 = probe_ok;
    const dtz = probeTable(pos, true, wdl, &st);
    if (st == probe_fail) {
        out_state.* = probe_fail;
        return 0;
    }
    if (st != change_stm) {
        const cursed: i32 = @intFromBool(wdl == wdl_blessed_loss or wdl == wdl_cursed_win);
        return (dtz + 100 * cursed) * signOf(wdl);
    }

    // Resolve CHANGE_STM: the DTZ is stored for the other side; do a 1-ply search minimizing DTZ.
    var min_dtz: i32 = 0xFFFF;
    var buf: [256]u16 = undefined;
    const total = movegen.generateLegal(pos, buf[0..]);
    const node = state_list.storagePush(storage) catch {
        out_state.* = probe_fail;
        return 0;
    };
    var i: usize = 0;
    while (i < total) : (i += 1) {
        const m = buf[i];
        const zeroing = isCapture(pos, m) or movedPieceType(pos, m) == pawn_pt;
        position.doMoveState(pos, m, node);
        var cst: i32 = probe_ok;
        var d: i32 = undefined;
        if (zeroing) {
            const s = searchWdl(pos, storage, false);
            cst = s.state;
            d = -dtzBeforeZeroing(s.value);
        } else {
            d = -probeDtz(pos, storage, &cst);
        }
        // Give a mating move DTZ 1 (child is in check with no legal reply).
        var mbuf: [256]u16 = undefined;
        if (d == 1 and pos.st.checkers_bb != 0 and movegen.generateLegal(pos, mbuf[0..]) == 0)
            min_dtz = 1;
        if (!zeroing) d += signOf(d); // correct for the 1-ply search
        if (d < min_dtz and signOf(d) == signOf(wdl)) min_dtz = d;
        position.undoMove(pos, m);
        if (cst == probe_fail) {
            out_state.* = probe_fail;
            return 0;
        }
    }
    return if (min_dtz == 0xFFFF) -1 else min_dtz; // no legal moves -> mate -> -1
}

// ---- probeFen: the platform probe surface -----------------------------------

/// Probe a FEN for its WDL and DTZ. Build a scratch Position (engine down-edge), then run SF's
/// probe_wdl (search<false>) and probe_dtz. `available == 0` means no WDL result (no table, load
/// failure, or castling rights present -- TB positions have none); a DTZ failure is reported via
/// `dtz_state` while WDL still reports.
pub fn probeFen(fen_ptr: [*]const u8, fen_len: usize, chess960: u8) ProbeResult {
    const empty = ProbeResult{ .available = 0, .wdl = 0, .wdl_state = 0, .dtz = 0, .dtz_state = 0 };
    if (!registry.ready()) return empty;

    const pos = position.create() orelse return empty;
    defer position.destroy(pos);
    const storage = state_list.storageCreate() orelse return empty;
    defer state_list.storageDestroy(storage);
    const root_state = state_list.storageReset(storage) catch return empty;
    if (position.setPositionState(pos, fen_ptr, fen_len, chess960, root_state)) |err| {
        std.heap.c_allocator.free(err);
        return empty;
    }

    const w = searchWdl(pos, storage, false); // probe_wdl
    if (w.state == probe_fail) return empty;

    var dtz_state: i32 = probe_ok;
    const dtz = probeDtz(pos, storage, &dtz_state);

    return .{
        .available = 1,
        .wdl = w.value,
        .wdl_state = w.state,
        .dtz = dtz,
        .dtz_state = dtz_state,
    };
}

// Probe WDL in-search: the search's Step 6 calls this on the LIVE search Position rather
// than round-tripping a FEN. searchWdl does do/undo on `pos` for its capture recursion and restores
// it exactly (undoMove), and doMoveState touches only the board + StateInfo (never the NNUE
// accumulator stack), so the search's position/eval state is intact on return. A persistent probe
// storage (reset per call) supplies the recursion's StateInfo nodes. Same WDL as the FEN path.
// Keep the recursion's StateInfo storage per thread. Upstream's `search()` holds `StateInfo st`
// as a stack local (tbprobe.cpp:1333), so every probing thread owns its nodes. One shared storage
// lets a reset on one thread destroy blocks another is writing through in doMoveState, and lets
// two threads mutate the block list at once.
threadlocal var probe_pos_storage: ?*state_list.PendingStateStorage = null;

pub fn probeWdlPos(pos: *Position) ProbeResult {
    const empty = ProbeResult{ .available = 0, .wdl = 0, .wdl_state = 0, .dtz = 0, .dtz_state = 0 };
    if (!registry.ready()) return empty;
    if (probe_pos_storage == null) probe_pos_storage = state_list.storageCreate();
    const storage = probe_pos_storage orelse return empty;
    _ = state_list.storageReset(storage) catch return empty;

    const w = searchWdl(pos, storage, false);
    if (w.state == probe_fail) return empty;
    return .{ .available = 1, .wdl = w.value, .wdl_state = w.state, .dtz = 0, .dtz_state = 0 };
}

test {
    std.testing.refAllDecls(@This());
}
