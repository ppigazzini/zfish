// Score moves: the ScoreInput/SortEntry/MovePickerState/MovePickerContext types
// plus scoreValue/scoreList and the low-level move-bit / history-load helpers
// they use.

const std = @import("std");
const board_core = @import("board_core");
// Single-source the move-word decoders; legality.zig aliases the same set.
const moveFrom = board_core.moveFrom;
const moveTo = board_core.moveTo;
const moveType = board_core.moveTypeOf;
const shared_history_types = @import("shared_history_types");
const SharedHistories = shared_history_types.SharedHistories;

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

const movepick_snapshot = @import("movepick_snapshot.zig");
const seeGe = @import("legality").seeGe;
const pieceAt = movepick_snapshot.pieceAt;
const attacksBy = movepick_snapshot.attacksBy;
const checkSquares = movepick_snapshot.checkSquares;
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
const min_sort_limit: i32 = std.math.minInt(i32);
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

const piece_values = [_]i32{
    0, 208, 781, 825, 1276, 2538, 0, 0,
    0, 208, 781, 825, 1276, 2538, 0, 0,
};

pub const ScoreInput = struct {
    raw_move: u16,
    check_bonus: u8,
    from_threatened: u8,
    to_threatened: u8,
    capture_stage: u8,
    capture_history: i32,
    captured_piece_value: i32,
    main_history: i32,
    pawn_history: i32,
    continuation_sum: i32,
    piece_value: i32,
    low_ply_bonus: i32,
};

pub const SortEntry = struct {
    raw_move: u16,
    reserved: u16,
    value: i32,
};

pub const MovePickerState = struct {
    tt_move_raw: u16,
    stage: i32,
    threshold: i32,
    depth: i32,
    skip_quiets: u8,
    cur: usize,
    end_cur: usize,
    end_bad_captures: usize,
    end_captures: usize,
    end_generated: usize,
    moves: [*]SortEntry,
};

pub const MovePickerContext = struct {
    pos: *const Position,
    main_history: ?[*]const MainHistoryRow,
    low_ply_history: ?[*]const LowPlyHistoryRow,
    capture_history: ?[*]const CaptureHistoryRow,
    continuation_history: ?[]const ContHistSlot,
    shared_history: ?*const SharedHistories,
    ply: i32,
};

// Compute the per-move score. Upstream's MovePicker::score() computes this straight into the
// move's value in a single pass; keeping it a leaf over ScoreInput lets scoreList do
// the same without materialising the inputs.
fn scoreValue(comptime kind: u8, input: ScoreInput) i32 {
    return switch (kind) {
        captures => input.capture_history + 7 * input.captured_piece_value,
        quiets => 2 * input.main_history +
            2 * input.pawn_history +
            input.continuation_sum +
            @as(i32, input.check_bonus) * 16384 +
            input.piece_value * 20 * (@as(i32, input.from_threatened) - @as(i32, input.to_threatened)) +
            input.low_ply_bonus,
        evasions => if (input.capture_stage != 0)
            input.captured_piece_value + (1 << 28)
        else
            input.main_history + input.continuation_sum,
        else => unreachable,
    };
}

pub fn scoreList(comptime kind: u8, context: *const MovePickerContext, outputs: [*]SortEntry) usize {
    var move_list: [max_moves]u16 = undefined;
    const count = switch (kind) {
        captures => movegen.generateCaptures(context.pos, move_list[0..]),
        quiets => movegen.generateQuiets(context.pos, move_list[0..]),
        evasions => movegen.generateEvasions(context.pos, move_list[0..]),
        else => unreachable,
    };

    const pos = context.pos;
    const history = loadHistorySnapshot(context);
    const side_to_move = pos.side_to_move;

    var threat_by_lesser: [7]u64 = @splat(0);
    if (kind == quiets) {
        const them = otherColor(side_to_move);
        threat_by_lesser[pawn] = 0;
        threat_by_lesser[knight] = attacksBy(pos, them, pawn);
        threat_by_lesser[bishop] = threat_by_lesser[knight];
        threat_by_lesser[rook] = attacksBy(pos, them, knight) |
            attacksBy(pos, them, bishop) |
            threat_by_lesser[knight];
        threat_by_lesser[queen] = attacksBy(pos, them, rook) |
            threat_by_lesser[rook];
        threat_by_lesser[king] = 0;
    }

    var index: usize = 0;
    while (index < count) : (index += 1) {
        const raw_move = move_list[index];
        const from = moveFrom(raw_move);
        const to = moveTo(raw_move);
        const piece = pieceAt(pos, from);
        const piece_type = typeOf(piece);
        const captured_piece = pieceAt(pos, to);

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
                input.capture_history = captureHistoryScore(
                    &history,
                    piece,
                    to,
                    typeOf(captured_piece),
                );
                input.captured_piece_value = piece_values[@as(usize, captured_piece)];
            },
            quiets => {
                input.main_history = mainHistoryScore(
                    &history,
                    side_to_move,
                    raw_move,
                );
                input.pawn_history = pawnHistoryScore(
                    &history,
                    pos.st.pawn_key,
                    piece,
                    to,
                );
                input.continuation_sum =
                    continuationHistoryScore(&history, 0, piece, to) +
                    continuationHistoryScore(&history, 1, piece, to) +
                    continuationHistoryScore(&history, 2, piece, to) +
                    continuationHistoryScore(&history, 3, piece, to) +
                    continuationHistoryScore(&history, 5, piece, to);
                input.check_bonus = @intFromBool(
                    (checkSquares(pos, piece_type) & squareMask(to)) != 0 and
                        seeGe(pos, raw_move, -75),
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
                        8 * lowPlyHistoryScore(
                            &history,
                            context.ply,
                            raw_move,
                        ),
                        1 + context.ply,
                    );
                }
            },
            evasions => {
                input.main_history = mainHistoryScore(
                    &history,
                    side_to_move,
                    raw_move,
                );
                input.continuation_sum = continuationHistoryScore(
                    &history,
                    0,
                    piece,
                    to,
                );
                input.captured_piece_value = piece_values[@as(usize, captured_piece)];
                input.capture_stage = @intFromBool(captureStage(pos, raw_move));
            },
            else => unreachable,
        }

        outputs[index] = .{ .raw_move = raw_move, .reserved = 0, .value = scoreValue(kind, input) };
    }

    return count;
}

fn typeOf(piece: u8) u8 {
    return piece & 7;
}

fn squareMask(square: u8) u64 {
    return @as(u64, 1) << @intCast(square);
}

fn loadHistorySnapshot(context: *const MovePickerContext) HistorySnapshot {
    var snapshot = std.mem.zeroes(HistorySnapshot);
    fillHistorySnapshot(
        context.main_history,
        context.low_ply_history,
        context.capture_history,
        context.continuation_history,
        context.shared_history,
        &snapshot,
    );
    return snapshot;
}

fn captureStage(pos: *const Position, raw_move: u16) bool {
    return isCapture(pos, raw_move) or promotionType(raw_move) == queen;
}

fn isCapture(pos: *const Position, raw_move: u16) bool {
    return (pieceAt(pos, moveTo(raw_move)) != 0 and moveType(raw_move) != castling_move) or
        moveType(raw_move) == en_passant_move;
}

fn otherColor(color: u8) u8 {
    return if (color == white) black else white;
}

fn promotionType(raw_move: u16) u8 {
    return @intCast(((raw_move >> 12) & 0x3) + knight);
}

test {
    @import("std").testing.refAllDecls(@This());
}
