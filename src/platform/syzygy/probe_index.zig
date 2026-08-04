//! Turn a POSITION into the unique table index its value lives at -- Stockfish's
//! `do_probe_table`, the half of the probe that is pure geometry.
//!
//! Split from wdl.zig on the 500-line lint, at the seam the file already had: this half maps
//! squares to an index through the tables `encode.zig` builds and never touches a move, a
//! search or a StateInfo; wdl.zig keeps the WDL/DTZ recursion that calls it.
//!
//! EVERY BOUND HERE IS A POINT-OF-USE BOUND, and that is not a style choice. The walk is
//! driven by `group_len[]`, which `setGroups` derived from the FILE's piece nibbles, while
//! `squares` is filled from the POSITION -- so a corrupt table can ask for a group the
//! position never filled. Load-time validation cannot see that: the position is not known
//! there. The probe refuses instead, which is the answer it already gives for a table it
//! cannot read.

const std = @import("std");

const registry = @import("registry.zig");
const probe = @import("probe.zig");
const decode = @import("decode.zig");
const encode = @import("encode.zig");

const position = @import("position");
const board_core = @import("board_core");

const Position = position.Position;
const TBTable = registry.TBTable;
const PairsData = probe.PairsData;

const white = board_core.color_white;
const black = board_core.color_black;
const pawn_pt = board_core.pawn_pt;

// Define SF ProbeState: FAIL=0, OK=1, ZEROING_BEST_MOVE=2, CHANGE_STM=-1.
pub const probe_fail: i32 = 0;
pub const probe_ok: i32 = 1;
pub const probe_zeroing: i32 = 2;
pub const change_stm: i32 = -1;
// Define SF WDLScore.
pub const wdl_win: i32 = 2;
pub const wdl_cursed_win: i32 = 1;
pub const wdl_draw: i32 = 0;
pub const wdl_blessed_loss: i32 = -1;
pub const wdl_loss: i32 = -2;

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
pub fn doProbeTable(pos: *const Position, t: *TBTable, comptime dtz: bool, wdl_score: i32, out_state: *i32) i32 {
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
        // The walk is driven by group_len[], which setGroups derived from the FILE's piece
        // nibbles, while `squares` was filled from the POSITION. A corrupt table can ask for a
        // group the position never filled -- a span past `size`, or a binomial row past the
        // six the table has. Neither is checkable at load, where the position is not known, so
        // refuse here as the probe already does for a table it cannot read.
        if (next >= d.group_len.len) {
            out_state.* = probe_fail;
            return 0;
        }
        const glen: usize = @intCast(d.group_len[next]);
        if (glen == 0) break;
        if (group_off + glen > size or glen >= encode.binomial.len) {
            out_state.* = probe_fail;
            return 0;
        }
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
            // A negative column is the same corruption seen one level down: the group's squares
            // are not the ones its length promised. Upstream indexes Binomial with it unchecked.
            if (col < 0) {
                out_state.* = probe_fail;
                return 0;
            }
            n += @intCast(encode.binomial[gi + 1][@intCast(col)]);
        }
        remaining_pawns = false;
        idx += n * d.group_idx[next];
        group_off += glen;
    }

    const raw = decode.decompressPairs(d, idx);
    if (dtz) return mapScoreDtz(t, d, raw, wdl_score);
    // Bound the score to the five outcomes a WDL file can hold. `raw` is decoded from the
    // PAYLOAD, and setSizes' SingleValue branch returns a raw header byte verbatim, so nothing
    // before this point holds it to 0..4 -- while every caller downstream INDEXES with what it
    // gets: mapScoreDtz reads wdl_map[wdl + 2], five entries wide. A SingleValue byte of 255
    // reached that index as 255 (fuzz_probe.zig, on the nightly lane). Refuse the table here, as
    // the group walk above refuses one whose groups the position cannot fill.
    if (raw < 0 or raw > 4) {
        out_state.* = probe_fail;
        return 0;
    }
    return raw - 2; // map_score<WDL> = value - 2
}

// Port SF map_score<DTZ>: remap the raw DTZ value through the per-WDL-class map, then convert to plies
// (x2 unless the flags already store plies for this class) and +1.

pub fn mapScoreDtz(t: *TBTable, d: *const PairsData, value_in: i32, wdl: i32) i32 {
    const wdl_map = [_]usize{ 1, 3, 0, 2, 0 }; // index by wdl+2
    var value = value_in;
    const flags = d.flags;
    if (flags & decode.flag_mapped != 0) {
        const mi: usize = d.map_idx[wdl_map[@intCast(wdl + 2)]];
        const off = mi + @as(usize, @intCast(value));
        // `value` is decoded from the compressed payload, so `off` is not bounded by anything
        // the header stated -- only the map region itself is (table_load.setDtzMap carves it).
        // Leave the raw value unmapped rather than read past the map on a corrupt table.
        const map = t.dtz_map;
        if (flags & decode.flag_wide != 0) {
            if (off * 2 + 2 <= map.len) value = decode.rdU16(map[off * 2 ..]);
        } else {
            if (off < map.len) value = map[off];
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
