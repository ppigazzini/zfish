const std = @import("std");

const captures: u8 = 0;
const quiets: u8 = 1;
const evasions: u8 = 2;
const white: u8 = 0;
const black: u8 = 1;

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

const piece_values = [_]c_int{
    0, 208, 781, 825, 1276, 2538, 0, 0,
    0, 208, 781, 825, 1276, 2538, 0, 0,
};

pub const ScoreInput = extern struct {
    raw_move: u16,
    check_bonus: u8,
    from_threatened: u8,
    to_threatened: u8,
    capture_stage: u8,
    capture_history: c_int,
    captured_piece_value: c_int,
    main_history: c_int,
    pawn_history: c_int,
    continuation_sum: c_int,
    piece_value: c_int,
    low_ply_bonus: c_int,
};

pub const SortEntry = extern struct {
    raw_move: u16,
    reserved: u16,
    value: c_int,
};

pub const MovePickerState = extern struct {
    tt_move_raw: u16,
    stage: c_int,
    threshold: c_int,
    depth: c_int,
    skip_quiets: u8,
    cur: usize,
    end_cur: usize,
    end_bad_captures: usize,
    end_captures: usize,
    end_generated: usize,
    moves: [max_moves]SortEntry,
};

pub const MovePickerContext = extern struct {
    pos: *const anyopaque,
    main_history: ?*const anyopaque,
    low_ply_history: ?*const anyopaque,
    capture_history: ?*const anyopaque,
    continuation_history: ?*const anyopaque,
    shared_history: ?*const anyopaque,
    ply: c_int,
};

extern fn zfish_movegen_generate_captures(pos: *const anyopaque, move_list: [*]u16) usize;
extern fn zfish_movegen_generate_quiets(pos: *const anyopaque, move_list: [*]u16) usize;
extern fn zfish_movegen_generate_evasions(pos: *const anyopaque, move_list: [*]u16) usize;
extern fn zfish_position_side_to_move(pos: *const anyopaque) u8;
extern fn zfish_position_piece_on(pos: *const anyopaque, square: u8) u8;
extern fn zfish_position_attacks_by(pos: *const anyopaque, piece_type: u8, color: u8) u64;
extern fn zfish_position_check_squares(pos: *const anyopaque, piece_type: u8) u64;
extern fn zfish_position_capture_stage(pos: *const anyopaque, raw_move: u16) u8;
extern fn zfish_history_main_score(main_history: *const anyopaque, side_to_move: u8, raw_move: u16) c_int;
extern fn zfish_history_low_ply_score(low_ply_history: *const anyopaque, ply: c_int, raw_move: u16) c_int;
extern fn zfish_history_capture_score(
    capture_history: *const anyopaque,
    piece: u8,
    square: u8,
    captured_piece_type: u8,
) c_int;
extern fn zfish_history_pawn_score(
    shared_history: *const anyopaque,
    pos: *const anyopaque,
    piece: u8,
    square: u8,
) c_int;
extern fn zfish_history_continuation_score(
    continuation_history: *const anyopaque,
    slot: usize,
    piece: u8,
    square: u8,
) c_int;
extern fn zfish_movepick_see_ge(pos: *const anyopaque, raw_move: u16, threshold: c_int) bool;

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

pub fn scoreMoves(
    kind: u8,
    inputs: [*]const ScoreInput,
    count: usize,
    outputs: [*]SortEntry,
) void {
    var index: usize = 0;
    while (index < count) : (index += 1) {
        const input = inputs[index];
        outputs[index] = .{
            .raw_move = input.raw_move,
            .reserved = 0,
            .value = switch (kind) {
                captures => input.capture_history + 7 * input.captured_piece_value,
                quiets => 2 * input.main_history +
                    2 * input.pawn_history +
                    input.continuation_sum +
                    @as(c_int, input.check_bonus) * 16384 +
                    input.piece_value * 20 * (@as(c_int, input.from_threatened) - @as(c_int, input.to_threatened)) +
                    input.low_ply_bonus,
                evasions => if (input.capture_stage != 0)
                    input.captured_piece_value + (1 << 28)
                else
                    input.main_history + input.continuation_sum,
                else => unreachable,
            },
        };
    }
}

pub fn scoreList(kind: u8, context: *const MovePickerContext, outputs: [*]SortEntry) usize {
    var move_list: [max_moves]u16 = undefined;
    const count = switch (kind) {
        captures => zfish_movegen_generate_captures(context.pos, move_list[0..].ptr),
        quiets => zfish_movegen_generate_quiets(context.pos, move_list[0..].ptr),
        evasions => zfish_movegen_generate_evasions(context.pos, move_list[0..].ptr),
        else => unreachable,
    };

    var inputs: [max_moves]ScoreInput = undefined;
    const side_to_move = zfish_position_side_to_move(context.pos);

    var threat_by_lesser: [7]u64 = [_]u64{0} ** 7;
    if (kind == quiets) {
        const them: u8 = if (side_to_move == white) black else white;
        threat_by_lesser[pawn] = 0;
        threat_by_lesser[knight] = zfish_position_attacks_by(context.pos, pawn, them);
        threat_by_lesser[bishop] = threat_by_lesser[knight];
        threat_by_lesser[rook] =
            zfish_position_attacks_by(context.pos, knight, them) |
            zfish_position_attacks_by(context.pos, bishop, them) |
            threat_by_lesser[knight];
        threat_by_lesser[queen] = zfish_position_attacks_by(context.pos, rook, them) |
            threat_by_lesser[rook];
        threat_by_lesser[king] = 0;
    }

    var index: usize = 0;
    while (index < count) : (index += 1) {
        const raw_move = move_list[index];
        const from = moveFrom(raw_move);
        const to = moveTo(raw_move);
        const piece = zfish_position_piece_on(context.pos, from);
        const piece_type = typeOf(piece);
        const captured_piece = zfish_position_piece_on(context.pos, to);

        var input = ScoreInput{
            .raw_move = raw_move,
            .check_bonus = 0,
            .from_threatened = 0,
            .to_threatened = 0,
            .capture_stage = 0,
            .capture_history = 0,
            .captured_piece_value = 0,
            .main_history = 0,
            .pawn_history = 0,
            .continuation_sum = 0,
            .piece_value = 0,
            .low_ply_bonus = 0,
        };

        switch (kind) {
            captures => {
                input.capture_history = zfish_history_capture_score(
                    context.capture_history orelse unreachable,
                    piece,
                    to,
                    typeOf(captured_piece),
                );
                input.captured_piece_value = piece_values[@as(usize, captured_piece)];
            },
            quiets => {
                const continuation_history = context.continuation_history orelse unreachable;

                input.main_history = zfish_history_main_score(
                    context.main_history orelse unreachable,
                    side_to_move,
                    raw_move,
                );
                input.pawn_history = zfish_history_pawn_score(
                    context.shared_history orelse unreachable,
                    context.pos,
                    piece,
                    to,
                );
                input.continuation_sum =
                    zfish_history_continuation_score(continuation_history, 0, piece, to) +
                    zfish_history_continuation_score(continuation_history, 1, piece, to) +
                    zfish_history_continuation_score(continuation_history, 2, piece, to) +
                    zfish_history_continuation_score(continuation_history, 3, piece, to) +
                    zfish_history_continuation_score(continuation_history, 5, piece, to);
                input.check_bonus = @intFromBool(
                    (zfish_position_check_squares(context.pos, piece_type) & squareMask(to)) != 0 and
                        zfish_movepick_see_ge(context.pos, raw_move, -75),
                );
                input.from_threatened = @intFromBool(
                    (threat_by_lesser[piece_type] & squareMask(from)) != 0,
                );
                input.to_threatened = @intFromBool(
                    (threat_by_lesser[piece_type] & squareMask(to)) != 0,
                );
                input.piece_value = piece_values[@as(usize, piece_type)];

                if (context.ply < low_ply_history_size) {
                    input.low_ply_bonus = @divTrunc(
                        8 * zfish_history_low_ply_score(
                            context.low_ply_history orelse unreachable,
                            context.ply,
                            raw_move,
                        ),
                        1 + context.ply,
                    );
                }
            },
            evasions => {
                input.main_history = zfish_history_main_score(
                    context.main_history orelse unreachable,
                    side_to_move,
                    raw_move,
                );
                input.continuation_sum = zfish_history_continuation_score(
                    context.continuation_history orelse unreachable,
                    0,
                    piece,
                    to,
                );
                input.captured_piece_value = piece_values[@as(usize, captured_piece)];
                input.capture_stage = zfish_position_capture_stage(context.pos, raw_move);
            },
            else => unreachable,
        }

        inputs[index] = input;
    }

    scoreMoves(kind, inputs[0..].ptr, count, outputs);
    return count;
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

                const count = scoreList(captures, context, state.moves[state.cur..].ptr);

                state.end_cur = state.cur + count;
                state.end_captures = state.end_cur;
                partialInsertionSort(state.moves[state.cur..].ptr, count, min_sort_limit);
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
                    const count = scoreList(quiets, context, state.moves[state.cur..].ptr);

                    state.end_cur = state.cur + count;
                    state.end_generated = state.end_cur;
                    partialInsertionSort(
                        state.moves[state.cur..].ptr,
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

                const count = scoreList(evasions, context, state.moves[state.cur..].ptr);

                state.end_cur = state.cur + count;
                state.end_generated = state.end_cur;
                partialInsertionSort(state.moves[state.cur..].ptr, count, min_sort_limit);
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
            if (zfish_movepick_see_ge(context.pos, entry.raw_move, threshold)) {
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
            zfish_movepick_see_ge(context.pos, entry.raw_move, state.threshold)) {
            return entry.raw_move;
        }
    }

    return null;
}

fn moveFrom(raw_move: u16) u8 {
    return @intCast((raw_move >> 6) & 0x3F);
}

fn moveTo(raw_move: u16) u8 {
    return @intCast(raw_move & 0x3F);
}

fn typeOf(piece: u8) u8 {
    return piece & 7;
}

fn squareMask(square: u8) u64 {
    return @as(u64, 1) << @intCast(square);
}
