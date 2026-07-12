const std = @import("std");

// ANNEX B.3: the history-heuristic layer lives in a std-only leaf now; alias back.
const movepick_history = @import("movepick_history.zig");
const HistorySnapshot = movepick_history.HistorySnapshot;
const HistoryEntry = movepick_history.HistoryEntry;
const AtomicHistoryEntry = movepick_history.AtomicHistoryEntry;
const MainHistoryRow = movepick_history.MainHistoryRow;
const LowPlyHistoryRow = movepick_history.LowPlyHistoryRow;
const CaptureHistoryRow = movepick_history.CaptureHistoryRow;
const PieceToHistoryRow = movepick_history.PieceToHistoryRow;
const PawnHistoryRow = movepick_history.PawnHistoryRow;
const ContHistSlot = movepick_history.ContHistSlot;
const fillHistorySnapshot = movepick_history.fillHistorySnapshot;
const mainHistoryScore = movepick_history.mainHistoryScore;
const lowPlyHistoryScore = movepick_history.lowPlyHistoryScore;
const captureHistoryScore = movepick_history.captureHistoryScore;
const continuationHistoryScore = movepick_history.continuationHistoryScore;
const pawnHistoryScore = movepick_history.pawnHistoryScore;

// ANNEX B.3: snapshot-query + SEE layer lives in a std-only leaf now; alias back.
const movepick_snapshot = @import("movepick_snapshot.zig");
const seeGeWithSnapshot = movepick_snapshot.seeGeWithSnapshot;
const attackersTo = movepick_snapshot.attackersTo;
const piecesColorType = movepick_snapshot.piecesColorType;
const piecesByTypes = movepick_snapshot.piecesByTypes;
const pieceAt = movepick_snapshot.pieceAt;
const attacksBy = movepick_snapshot.attacksBy;
const checkSquares = movepick_snapshot.checkSquares;
const pawnAttackersTo = movepick_snapshot.pawnAttackersTo;
const pawnAttacksFromSquare = movepick_snapshot.pawnAttacksFromSquare;
const leastSignificantSquareBb = movepick_snapshot.leastSignificantSquareBb;
const shift = movepick_snapshot.shift;
const bitboard = @import("bitboard");
const position_snapshot = @import("position_snapshot");
const position_types = @import("position_types");
const Position = position_types.Position;
const movegen = @import("movegen");

const captures: u8 = 0;
const quiets: u8 = 1;
const evasions: u8 = 2;
const white: u8 = 0;
const black: u8 = 1;

const file_a_bb: u64 = 0x0101010101010101;
const file_h_bb: u64 = file_a_bb << 7;

const no_piece_type: u8 = 0;
const pawn: u8 = 1;
const knight: u8 = 2;
const bishop: u8 = 3;
const rook: u8 = 4;
const queen: u8 = 5;
const king: u8 = 6;

const main_tt: c_int = 0;
const capture_init: c_int = 1;
const good_capture: c_int = 2;
const quiet_init: c_int = 3;
const good_quiet: c_int = 4;
const bad_capture: c_int = 5;
const bad_quiet: c_int = 6;

const evasion_tt: c_int = 7;
const evasion_init: c_int = 8;
const evasion: c_int = 9;

const probcut_tt: c_int = 10;
const probcut_init: c_int = 11;
const probcut: c_int = 12;

const qsearch_tt: c_int = 13;
const qcapture_init: c_int = 14;
const qcapture: c_int = 15;

const max_moves: usize = 256;
const good_quiet_threshold: c_int = -14000;
const min_sort_limit: c_int = std.math.minInt(c_int);
const low_ply_history_size: c_int = 5;
const low_ply_history_entries: usize = 5;
const piece_nb: usize = 16;
const square_nb: usize = 64;
const piece_type_nb: usize = 8;

const north_east: i8 = 9;
const north_west: i8 = 7;
const south_east: i8 = -7;
const south_west: i8 = -9;

const normal_move: u16 = 0;
const promotion_move: u16 = 1 << 14;
const en_passant_move: u16 = 2 << 14;
const castling_move: u16 = 3 << 14;
const move_type_mask: u16 = 3 << 14;

const piece_values = [_]c_int{
    0, 208, 781, 825, 1276, 2538, 0, 0,
    0, 208, 781, 825, 1276, 2538, 0, 0,
};

// Scoring + the shared types live in the movepick_score leaf now; re-export the
// public types and alias back scoreList / loadPositionSnapshot for the yielder.
const movepick_score = @import("movepick_score.zig");
pub const ScoreInput = movepick_score.ScoreInput;
pub const SortEntry = movepick_score.SortEntry;
pub const MovePickerState = movepick_score.MovePickerState;
pub const MovePickerContext = movepick_score.MovePickerContext;
const scoreList = movepick_score.scoreList;
const loadPositionSnapshot = movepick_score.loadPositionSnapshot;

const PositionSnapshot = position_snapshot.PositionSnapshot;

pub fn initMainStage(has_checkers: bool, has_tt_move: bool, depth: c_int) c_int {
    const base_stage: c_int = if (has_checkers)
        evasion_tt
    else if (depth > 0)
        main_tt
    else
        qsearch_tt;

    return base_stage + @as(c_int, @intFromBool(!has_tt_move));
}

pub fn initProbcutStage(has_tt_move: bool) c_int {
    return probcut_tt + @as(c_int, @intFromBool(!has_tt_move));
}

pub fn partialInsertionSort(entries: [*]SortEntry, count: usize, limit: c_int) void {
    if (count == 0)
        return;

    var sorted_end: usize = 0;
    var scan: usize = 1;

    while (scan < count) : (scan += 1) {
        if (entries[scan].value >= limit) {
            const current = entries[scan];
            sorted_end += 1;
            entries[scan] = entries[sorted_end];

            var insert_at = sorted_end;
            while (insert_at != 0 and entries[insert_at - 1].value < current.value) : (insert_at -= 1) {
                entries[insert_at] = entries[insert_at - 1];
            }
            entries[insert_at] = current;
        }
    }
}

pub fn nextMove(state: *MovePickerState, context: *const MovePickerContext) u16 {
    while (true) {
        switch (state.stage) {
            main_tt, evasion_tt, qsearch_tt, probcut_tt => {
                state.stage += 1;
                return state.tt_move_raw;
            },
            capture_init, probcut_init, qcapture_init => {
                state.cur = 0;
                state.end_bad_captures = 0;

                const count = scoreList(captures, context, state.moves + state.cur);

                state.end_cur = state.cur + count;
                state.end_captures = state.end_cur;
                partialInsertionSort(state.moves + state.cur, count, min_sort_limit);
                state.stage += 1;
                continue;
            },
            good_capture => {
                if (selectGoodCapture(state, context)) |move| {
                    return move;
                }

                state.stage += 1;
                continue;
            },
            quiet_init => {
                if (!skipQuiets(state)) {
                    const count = scoreList(quiets, context, state.moves + state.cur);

                    state.end_cur = state.cur + count;
                    state.end_generated = state.end_cur;
                    partialInsertionSort(
                        state.moves + state.cur,
                        count,
                        -3560 * state.depth,
                    );
                }

                state.stage += 1;
                continue;
            },
            good_quiet => {
                if (!skipQuiets(state)) {
                    if (selectGoodQuiet(state)) |move| {
                        return move;
                    }
                }

                state.cur = 0;
                state.end_cur = state.end_bad_captures;
                state.stage += 1;
                continue;
            },
            bad_capture => {
                if (selectAny(state)) |move| {
                    return move;
                }

                state.cur = state.end_captures;
                state.end_cur = state.end_generated;
                state.stage += 1;
                continue;
            },
            bad_quiet => {
                if (!skipQuiets(state)) {
                    if (selectBadQuiet(state)) |move| {
                        return move;
                    }
                }

                return 0;
            },
            evasion_init => {
                state.cur = 0;

                const count = scoreList(evasions, context, state.moves + state.cur);

                state.end_cur = state.cur + count;
                state.end_generated = state.end_cur;
                partialInsertionSort(state.moves + state.cur, count, min_sort_limit);
                state.stage += 1;
                continue;
            },
            evasion, qcapture => {
                if (selectAny(state)) |move| {
                    return move;
                }

                return 0;
            },
            probcut => {
                if (selectProbcut(state, context)) |move| {
                    return move;
                }

                return 0;
            },
            else => unreachable,
        }
    }
}

fn skipQuiets(state: *const MovePickerState) bool {
    return state.skip_quiets != 0;
}

fn selectAny(state: *MovePickerState) ?u16 {
    while (state.cur < state.end_cur) {
        const index = state.cur;
        const entry = state.moves[index];
        state.cur += 1;

        if (entry.raw_move != state.tt_move_raw) {
            return entry.raw_move;
        }
    }

    return null;
}

fn selectGoodCapture(state: *MovePickerState, context: *const MovePickerContext) ?u16 {
    while (state.cur < state.end_cur) {
        const index = state.cur;
        const entry = state.moves[index];

        if (entry.raw_move != state.tt_move_raw) {
            const threshold = @divTrunc(-entry.value, 18);
            if (seeGe(context.pos, entry.raw_move, threshold)) {
                state.cur += 1;
                return entry.raw_move;
            }

            std.mem.swap(SortEntry, &state.moves[state.end_bad_captures], &state.moves[index]);
            state.end_bad_captures += 1;
        }

        state.cur += 1;
    }

    return null;
}

fn selectGoodQuiet(state: *MovePickerState) ?u16 {
    while (state.cur < state.end_cur) {
        const index = state.cur;
        const entry = state.moves[index];
        state.cur += 1;

        if (entry.raw_move != state.tt_move_raw and entry.value > good_quiet_threshold) {
            return entry.raw_move;
        }
    }

    return null;
}

fn selectBadQuiet(state: *MovePickerState) ?u16 {
    while (state.cur < state.end_cur) {
        const index = state.cur;
        const entry = state.moves[index];
        state.cur += 1;

        if (entry.raw_move != state.tt_move_raw and entry.value <= good_quiet_threshold) {
            return entry.raw_move;
        }
    }

    return null;
}

fn selectProbcut(state: *MovePickerState, context: *const MovePickerContext) ?u16 {
    while (state.cur < state.end_cur) {
        const index = state.cur;
        const entry = state.moves[index];
        state.cur += 1;

        if (entry.raw_move != state.tt_move_raw and
            seeGe(context.pos, entry.raw_move, state.threshold))
        {
            return entry.raw_move;
        }
    }

    return null;
}

fn seeGe(pos: *const Position, raw_move: u16, threshold: c_int) bool {
    const snapshot = loadPositionSnapshot(pos);
    return seeGeWithSnapshot(&snapshot, raw_move, threshold);
}

test {
    @import("std").testing.refAllDecls(@This());
}
