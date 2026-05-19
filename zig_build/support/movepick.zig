const captures: u8 = 0;
const quiets: u8 = 1;
const evasions: u8 = 2;

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
