//! Probe Syzygy WDL/DTZ. Port Stockfish's `do_probe_table` (position ->
//! unique index -> value), `probe_table`, `probe_wdl` (search<false> capture recursion),
//! `probe_dtz`, and `map_score` faithfully. Tie the position->index geometry (encode.zig), the data model
//! (probe.zig), and the RE-PAIR decoder (decode.zig) together, indexing through the tables that
//! `registry.zig` owns and lazily maps.
//!
//! Keep the registry (material key -> TBTable), file load, and `set`/`set_dtz_map` parsing in
//! `registry.zig`; this file imports it downward and never the reverse (so neither is a god-file).
//! Registry keys are bit-identical to a probed position's `pos.st.material_key`.
//!
//! Cross the platform->engine down-edge (the harness may depend on the engine): the probe reaches the headless
//! engine for a scratch Position (FEN parse), its material key + piece bitboards, and legal-capture
//! movegen for the capture recursion.

const std = @import("std");

const registry = @import("registry.zig");
const probe = @import("probe.zig");
const decode = @import("decode.zig");
const encode = @import("encode.zig");

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

// ---- do_probe_table: position -> index -> WDL (SF do_probe_table<WDL>) -------

const tb_pieces = probe.tb_pieces;

inline fn fileOf(sq: u8) usize {
    return sq & 7;
}
inline fn rankOf(sq: u8) usize {
    return sq >> 3;
}
inline fn mapPawns(sq: u8) i32 {
    return encode.map_pawns[sq];
}

// Port SF do_probe_table, generic over WDL/DTZ. WDL returns the raw score in -2..2 (value - 2); DTZ
// returns map_score<DTZ>(value) given the position's `wdl_score`. For DTZ, if the stored side does
// not match the side to move, sets out_state = CHANGE_STM (the caller does a 1-ply search).
fn doProbeTable(pos: *const Position, t: *TBTable, comptime dtz: bool, wdl_score: i32, out_state: *i32) i32 {
    var squares: [tb_pieces]u8 = undefined;
    var pieces_arr: [tb_pieces]u8 = undefined;
    var size: usize = 0;
    var lead_pawns_cnt: usize = 0;
    var tb_file: usize = 0;

    const material_key = pos.st.material_key;
    const stm_pos: usize = pos.side_to_move;

    const symmetric_btm = (t.key == t.key2) and (stm_pos != 0);
    const black_stronger = material_key != t.key;
    const swap = symmetric_btm or black_stronger;
    const flip_color: u8 = if (swap) 8 else 0;
    const flip_squares: u8 = if (swap) 56 else 0;
    const stm: usize = @intFromBool(swap) ^ stm_pos;

    var lead_pawns: u64 = 0;
    if (t.has_pawns) {
        const pc = t.get(dtz, 0, 0).pieces[0] ^ flip_color;
        const lead_color: usize = pc >> 3;
        lead_pawns = pos.by_color_bb[lead_color] & pos.by_type_bb[pawn_pt];
        var b = lead_pawns;
        while (b != 0) {
            const s: u8 = @intCast(@ctz(b));
            b &= b - 1;
            squares[size] = s ^ flip_squares;
            size += 1;
        }
        lead_pawns_cnt = size;

        // Move the pawn with the maximum MapPawns[] into squares[0] (first max).
        var maxi: usize = 0;
        var mj: usize = 1;
        while (mj < lead_pawns_cnt) : (mj += 1) {
            if (mapPawns(squares[mj]) > mapPawns(squares[maxi])) maxi = mj;
        }
        const tmp = squares[0];
        squares[0] = squares[maxi];
        squares[maxi] = tmp;

        tb_file = encode.edgeDistance(fileOf(squares[0]));
    }

    // Treat DTZ tables as one-sided: if the stored side is not the side to move, bail to a 1-ply
    // search (CHANGE_STM). WDL check_dtz_stm is always true.
    if (dtz) {
        const flags = t.get(true, stm, tb_file).flags;
        const stm_ok = (flags & decode.flag_stm) == stm or (t.key == t.key2 and !t.has_pawns);
        if (!stm_ok) {
            out_state.* = change_stm;
            return 0;
        }
    }

    // Gather the remaining pieces (all except the lead pawns).
    var b = pos.by_type_bb[0] ^ lead_pawns;
    while (b != 0) {
        const s: u8 = @intCast(@ctz(b));
        b &= b - 1;
        squares[size] = s ^ flip_squares;
        pieces_arr[size] = pos.board[s] ^ flip_color;
        size += 1;
    }

    const d = t.get(dtz, stm, tb_file);

    // Reorder pieces to match the file's canonical d.pieces sequence.
    var ri = lead_pawns_cnt;
    while (ri + 1 < size) : (ri += 1) {
        var rj = ri + 1;
        while (rj < size) : (rj += 1) {
            if (d.pieces[ri] == pieces_arr[rj]) {
                const ps = pieces_arr[ri];
                pieces_arr[ri] = pieces_arr[rj];
                pieces_arr[rj] = ps;
                const sq = squares[ri];
                squares[ri] = squares[rj];
                squares[rj] = sq;
                break;
            }
        }
    }

    // Map the lead square into the a1-d1-d4 triangle (file <= D).
    if (fileOf(squares[0]) > 3) {
        for (0..size) |i| squares[i] ^= 7;
    }

    var idx: u64 = 0;
    if (t.has_pawns) {
        idx = @intCast(encode.lead_pawn_idx[lead_pawns_cnt][squares[0]]);
        stableSortByMapPawns(squares[1..lead_pawns_cnt]);
        var i: usize = 1;
        while (i < lead_pawns_cnt) : (i += 1) {
            idx += @intCast(encode.binomial[i][@intCast(mapPawns(squares[i]))]);
        }
    } else {
        // Flip so the leading piece is below RANK_5.
        if (rankOf(squares[0]) > 3) {
            for (0..size) |i| squares[i] ^= 56;
        }
        // Take the first leading-group piece off the a1-h8 diagonal -> map below it.
        var i: usize = 0;
        while (i < @as(usize, @intCast(d.group_len[0]))) : (i += 1) {
            if (encode.offA1H8(squares[i]) == 0) continue;
            if (encode.offA1H8(squares[i]) > 0) {
                var j = i;
                while (j < size) : (j += 1) {
                    const sq: u16 = squares[j];
                    squares[j] = @intCast(((sq >> 3) | (sq << 3)) & 63);
                }
            }
            break;
        }

        if (t.has_unique_pieces) {
            const adjust1: i64 = @intFromBool(squares[1] > squares[0]);
            const adjust2: i64 = @as(i64, @intFromBool(squares[2] > squares[0])) +
                @intFromBool(squares[2] > squares[1]);
            const s1: i64 = squares[1];
            const s2: i64 = squares[2];
            if (encode.offA1H8(squares[0]) != 0) {
                idx = @intCast((@as(i64, encode.map_a1d1d4[squares[0]]) * 63 + (s1 - adjust1)) * 62 + s2 - adjust2);
            } else if (encode.offA1H8(squares[1]) != 0) {
                idx = @intCast((6 * 63 + @as(i64, @intCast(rankOf(squares[0]))) * 28 + encode.map_b1h1h7[squares[1]]) * 62 + s2 - adjust2);
            } else if (encode.offA1H8(squares[2]) != 0) {
                idx = @intCast(6 * 63 * 62 + 4 * 28 * 62 + @as(i64, @intCast(rankOf(squares[0]))) * 7 * 28 +
                    (@as(i64, @intCast(rankOf(squares[1]))) - adjust1) * 28 + encode.map_b1h1h7[squares[2]]);
            } else {
                idx = @intCast(6 * 63 * 62 + 4 * 28 * 62 + 4 * 7 * 28 + @as(i64, @intCast(rankOf(squares[0]))) * 7 * 6 +
                    (@as(i64, @intCast(rankOf(squares[1]))) - adjust1) * 6 + (@as(i64, @intCast(rankOf(squares[2]))) - adjust2));
            }
        } else {
            idx = @intCast(encode.map_kk[@intCast(encode.map_a1d1d4[squares[0]])][squares[1]]);
        }
    }

    idx *= d.group_idx[0];

    // Encode remaining groups.
    var group_off: usize = @intCast(d.group_len[0]);
    var remaining_pawns = t.has_pawns and t.pawn_count[1] != 0;
    var next: usize = 0;
    while (true) {
        next += 1;
        const glen: usize = @intCast(d.group_len[next]);
        if (glen == 0) break;
        stableSortSquares(squares[group_off .. group_off + glen]);
        var n: u64 = 0;
        var gi: usize = 0;
        while (gi < glen) : (gi += 1) {
            var adjust: i64 = 0;
            var si: usize = 0;
            while (si < group_off) : (si += 1) {
                adjust += @intFromBool(squares[group_off + gi] > squares[si]);
            }
            const col: i64 = @as(i64, squares[group_off + gi]) - adjust - (if (remaining_pawns) @as(i64, 8) else 0);
            n += @intCast(encode.binomial[gi + 1][@intCast(col)]);
        }
        remaining_pawns = false;
        idx += n * d.group_idx[next];
        group_off += glen;
    }

    const raw = decode.decompressPairs(d, idx);
    if (dtz) return mapScoreDtz(t, d, raw, wdl_score);
    return raw - 2; // map_score<WDL> = value - 2
}

// Port SF map_score<DTZ>: remap the raw DTZ value through the per-WDL-class map, then convert to plies
// (x2 unless the flags already store plies for this class) and +1.
fn mapScoreDtz(t: *TBTable, d: *const PairsData, value_in: i32, wdl: i32) i32 {
    const wdl_map = [_]usize{ 1, 3, 0, 2, 0 }; // index by wdl+2
    var value = value_in;
    const flags = d.flags;
    if (flags & decode.flag_mapped != 0) {
        const mi: usize = d.map_idx[wdl_map[@intCast(wdl + 2)]];
        const off = mi + @as(usize, @intCast(value));
        if (flags & decode.flag_wide != 0) {
            value = registry.rdU16(t.dtz_map.? + off * 2);
        } else {
            value = t.dtz_map.?[off];
        }
    }
    if ((wdl == wdl_win and flags & decode.flag_win_plies == 0) or
        (wdl == wdl_loss and flags & decode.flag_loss_plies == 0) or
        wdl == wdl_cursed_win or wdl == wdl_blessed_loss)
    {
        value *= 2;
    }
    return value + 1;
}

inline fn stableSortByMapPawns(sq: []u8) void {
    // Sort by insertion (stable), ascending MapPawns[].
    var i: usize = 1;
    while (i < sq.len) : (i += 1) {
        const v = sq[i];
        var j = i;
        while (j > 0 and mapPawns(sq[j - 1]) > mapPawns(v)) : (j -= 1) sq[j] = sq[j - 1];
        sq[j] = v;
    }
}

inline fn stableSortSquares(sq: []u8) void {
    var i: usize = 1;
    while (i < sq.len) : (i += 1) {
        const v = sq[i];
        var j = i;
        while (j > 0 and sq[j - 1] > v) : (j -= 1) sq[j] = sq[j - 1];
        sq[j] = v;
    }
}

// ---- probe_table + probe_wdl (search) + probe_dtz ---------------------------

// Define SF ProbeState: FAIL=0, OK=1, ZEROING_BEST_MOVE=2, CHANGE_STM=-1.
const probe_fail: i32 = 0;
const probe_ok: i32 = 1;
const probe_zeroing: i32 = 2;
const change_stm: i32 = -1;
// Define SF WDLScore.
const wdl_win: i32 = 2;
const wdl_cursed_win: i32 = 1;
const wdl_draw: i32 = 0;
const wdl_blessed_loss: i32 = -1;
const wdl_loss: i32 = -2;

const Probe = struct { value: i32, state: i32 };

// Port SF probe_table, generic over WDL/DTZ: KvK short-circuit, registry lookup, lazy map, do_probe.
fn probeTable(pos: *const Position, comptime dtz: bool, wdl_score: i32, out_state: *i32) i32 {
    if (@popCount(pos.by_type_bb[0]) == 2) return 0; // KvK draw
    const t = registry.hashGet(pos.st.material_key) orelse {
        out_state.* = probe_fail;
        return 0;
    };
    const ok = if (dtz) registry.mappedDtz(t) else registry.mapped(t);
    if (!ok) {
        out_state.* = probe_fail;
        return 0;
    }
    return doProbeTable(pos, t, dtz, wdl_score, out_state);
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
        std.heap.c_allocator.free(std.mem.span(err));
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
var probe_pos_storage: ?*state_list.PendingStateStorage = null;

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
