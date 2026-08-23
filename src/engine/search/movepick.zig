const std = @import("std");

const movepick_history = @import("movepick_history.zig");
// Re-export for the search callers that build the contHist array and must keep its length.
pub const contHistSlice = movepick_history.contHistSlice;

const seeGe = @import("legality").seeGe;
const bitboard = @import("bitboard");
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

const main_tt: i32 = 0;
const capture_init: i32 = 1;
const good_capture: i32 = 2;
const quiet_init: i32 = 3;
const good_quiet: i32 = 4;
const bad_capture: i32 = 5;
const bad_quiet: i32 = 6;

const evasion_tt: i32 = 7;
const evasion_init: i32 = 8;
const evasion: i32 = 9;

const probcut_tt: i32 = 10;
const probcut_init: i32 = 11;
const probcut: i32 = 12;

const qsearch_tt: i32 = 13;
const qcapture_init: i32 = 14;
const qcapture: i32 = 15;

const max_moves: usize = 256;
const good_quiet_threshold: i32 = -14000;
const low_ply_history_size: i32 = 5;
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

const piece_values = [_]i32{
    0, 208, 781, 825, 1276, 2538, 0, 0,
    0, 208, 781, 825, 1276, 2538, 0, 0,
};

const movepick_score = @import("movepick_score.zig");
const movepick_sort_avx512 = @import("movepick_sort_avx512.zig");
pub const SortEntry = movepick_score.SortEntry;
pub const MovePickerState = movepick_score.MovePickerState;
pub const MovePickerContext = movepick_score.MovePickerContext;
const scoreList = movepick_score.scoreList;

pub fn initMainStage(has_checkers: bool, has_tt_move: bool, depth: i32) i32 {
    const base_stage: i32 = if (has_checkers)
        evasion_tt
    else if (depth > 0)
        main_tt
    else
        qsearch_tt;

    return base_stage + @as(i32, @intFromBool(!has_tt_move));
}

pub fn initProbcutStage(has_tt_move: bool) i32 {
    return probcut_tt + @as(i32, @intFromBool(!has_tt_move));
}

// Sort a list whose limit admits every move.
//
// Two of the three callers passed `minInt(i32)`, where no score can fail the scan: every
// move qualifies, `sorted_end` advances on every iteration and therefore tracks `scan`
// exactly -- which makes `entries[scan] = entries[sorted_end]` a copy of a slot onto
// itself, and the test above it a constant. Naming that sort separately drops the limit,
// the test, the copy and the second cursor; what is left is `scan` alone.
//
// The order out is the order in. The scalar ladder starts at `scan`, which is the slot
// `sorted_end` named in the general form, and the vector prefix takes the same first
// min(count, max) moves.
//
// `partialInsertionSort` survives for its one remaining caller, the quiet stage, which is
// the only site that passes a real limit.
pub fn sortAll(entries: [*]SortEntry, count: usize) void {
    if (count == 0)
        return;

    var scan: usize = 1;

    if (comptime movepick_sort_avx512.use_avx512_sort) {
        var sorter = movepick_sort_avx512.MoveSorter.init(entries[0]);
        while (scan < count and scan < movepick_sort_avx512.max) : (scan += 1) {
            sorter.insert(entries[scan]);
        }
        sorter.write(entries, scan);
    }

    while (scan < count) : (scan += 1) {
        const current = entries[scan];
        var insert_at = scan;
        while (insert_at != 0 and entries[insert_at - 1].value < current.value) : (insert_at -= 1) {
            entries[insert_at] = entries[insert_at - 1];
        }
        entries[insert_at] = current;
    }
}

pub fn partialInsertionSort(entries: [*]SortEntry, count: usize, limit: i32) void {
    if (count == 0)
        return;

    var sorted_end: usize = 0;
    var scan: usize = 1;

    // Vector pass over the leading run, then the scalar loop below finishes the tail --
    // upstream's shape at movepick.cpp:114. entries[scan] is left untouched by the break
    // below (move_sorter_insert/sorted_end bump run AFTER the fullness check), so the
    // scalar loop picks up exactly where the vector pass left off.
    if (comptime movepick_sort_avx512.use_avx512_sort) {
        var sorter = movepick_sort_avx512.MoveSorter.init(entries[0]);
        while (scan < count) : (scan += 1) {
            if (entries[scan].value >= limit) {
                if (sorted_end + 1 >= movepick_sort_avx512.max) break; // sorter full
                sorter.insert(entries[scan]);
                sorted_end += 1;
                entries[scan] = entries[sorted_end];
            }
        }
        sorter.write(entries, sorted_end + 1);
    }

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
                sortAll(state.moves + state.cur, count);
                state.stage += 1;
                continue;
            },
            // Advance through the five main-search stages WITHOUT re-dispatching. Each of these
            // transitions has exactly one successor, so upstream spells them as `[[fallthrough]]`
            // and re-dispatches only at the shared *_INIT block below, via its `goto top`
            // (movepick.cpp). Spelling them as `stage += 1; continue;` instead sent every one of
            // them back through the jump table.
            //
            // Zig has no `[[fallthrough]]`, so the chain is a cascade of stage tests instead. The
            // stages are contiguous and only ever advance, so entering at any of the five runs
            // the rest in order and re-entry after a returned move resumes at the same stage,
            // exactly as the re-dispatching form did.
            //
            // Take this for the SHAPE, not for speed, and do not re-derive a speed case from the
            // branch counts: they look far better than they are. The dispatch drops from eleven
            // indirect jump sites to three and nextMove's executed indirect branches fall 18.9%,
            // but only 4.7% of the ones removed were ever mispredicted -- LLVM tail-duplicates
            // the jump table, so each single-successor site had its own BTB entry with one
            // target and already predicted near-perfectly. Measured flat end to end; the numbers
            // are in this commit's message.
            good_capture, quiet_init, good_quiet, bad_capture, bad_quiet => {
                if (state.stage == good_capture) {
                    if (selectGoodCapture(state, context)) |move| {
                        return move;
                    }

                    state.stage = quiet_init;
                }
                if (state.stage == quiet_init) {
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

                    state.stage = good_quiet;
                }
                if (state.stage == good_quiet) {
                    if (!skipQuiets(state)) {
                        // The sort limit is what makes the early stop sound, so ask it
                        // rather than a depth: at or below the threshold, the tail cannot
                        // hold a move the prefix has already ruled out.
                        const sort_limit = -3560 * state.depth;
                        const move_opt = if (sort_limit <= good_quiet_threshold)
                            selectGoodQuiet(state, true)
                        else
                            selectGoodQuiet(state, false);
                        if (move_opt) |move| {
                            return move;
                        }
                    }

                    state.cur = 0;
                    state.end_cur = state.end_bad_captures;
                    state.stage = bad_capture;
                }
                if (state.stage == bad_capture) {
                    if (selectAny(state)) |move| {
                        return move;
                    }

                    state.cur = state.end_captures;
                    state.end_cur = state.end_generated;
                    state.stage = bad_quiet;
                }
                if (!skipQuiets(state)) {
                    if (selectBadQuiet(state)) |move| {
                        return move;
                    }
                }

                return 0;
            },
            // The evasion chain is the same shape with one link: EVASION_INIT falls through to
            // EVASION upstream. QCAPTURE shares the selector and is reached from QCAPTURE_INIT's
            // re-dispatch, so it enters here with the init test already false.
            evasion_init, evasion, qcapture => {
                if (state.stage == evasion_init) {
                    state.cur = 0;

                    const count = scoreList(evasions, context, state.moves + state.cur);

                    state.end_cur = state.cur + count;
                    state.end_generated = state.end_cur;
                    sortAll(state.moves + state.cur, count);
                    state.stage = evasion;
                }
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

// Walk the good quiets. `bounded` decides whether the walk may stop at the first move that
// fails the threshold instead of running to the end of the list.
//
// partialInsertionSort leaves the list in TWO pieces: a prefix that descends, and a tail
// every member of which scores below the sort's own limit. So once the walk has seen one
// move at or below the threshold, the rest of the prefix is at or below it by the ordering,
// and the tail is below it by the limit -- there is nothing further to find.
//
// The tail half of that argument holds only while the LIMIT is at or below the THRESHOLD.
// The limit is `-3560 * depth`, so below depth 4 it is above -14000 and a tail move can
// still outscore the threshold; there the walk has to run to the end. The caller picks the
// form on exactly that test rather than on a transcribed depth, so a change to either
// constant moves the boundary with it.
fn selectGoodQuiet(state: *MovePickerState, comptime bounded: bool) ?u16 {
    while (state.cur < state.end_cur) {
        const entry = state.moves[state.cur];
        if (bounded and entry.value <= good_quiet_threshold) return null;
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

test {
    @import("std").testing.refAllDecls(@This());
}
