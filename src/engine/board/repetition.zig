// Detect repetitions and draws.
//
// Provide the read-only "has this position repeated / is it a draw" queries lifted out of
// position.zig: upcomingRepetition (the cuckoo no-progress-cycle test), isDraw,
// isRepetition, hasRepeated. Each walks the StateInfo chain (and the cuckoo table)
// through a *const Position and never mutates, so it is a leaf over zobrist +
// board_core + bitboard + movegen + position_types -- no import of position, no
// cycle. position.zig re-exports all four so the search callers keep resolving.

const std = @import("std");
const bitboard = @import("bitboard");
const movegen = @import("movegen");
const board_core = @import("board_core");
const zobrist = @import("zobrist");
const position_types = @import("position_types");

const Position = position_types.Position;
const StateInfo = position_types.StateInfo;

const sqBb = board_core.sqBb;
const moveFrom = board_core.moveFrom;
const moveTo = board_core.moveTo;
const h1 = zobrist.h1;
const h2 = zobrist.h2;

pub fn upcomingRepetition(pos: *const Position, ply: i32) bool {
    const cuckoo: [*]const u64 = &zobrist.cuckoo_tbl;
    const cuckoo_move: [*]const u16 = &zobrist.cuckoo_move_tbl;
    const end = @min(pos.st.rule50, pos.st.plies_from_null);
    if (end < 3) return false;

    const original_key = pos.st.key;
    var stp: *const StateInfo = pos.st.previous.?;
    var other = original_key ^ stp.key ^ zobrist.zob_side_val;

    var i: i32 = 3;
    while (i <= end) : (i += 2) {
        stp = stp.previous.?;
        other ^= stp.key ^ stp.previous.?.key ^ zobrist.zob_side_val;
        stp = stp.previous.?;
        if (other != 0) continue;

        const move_key = original_key ^ stp.key;
        var j = h1(move_key);
        if (cuckoo[j] != move_key) {
            j = h2(move_key);
            if (cuckoo[j] != move_key) continue;
        }

        const mv = cuckoo_move[j];
        const s1 = moveFrom(mv);
        const s2 = moveTo(mv);
        if (((bitboard.between(s1, s2) ^ sqBb(s2)) & pos.by_type_bb[0]) == 0) {
            if (ply > i) return true;
            if (stp.repetition != 0) return true;
        }
    }
    return false;
}

pub fn isDraw(pos: *const Position, ply: i32) bool {
    if (pos.st.rule50 > 99) {
        if (pos.st.checkers_bb == 0) return true;
        var buf: [256]u16 = undefined;
        if (movegen.generateLegal(pos, &buf) != 0) return true;
    }
    return isRepetition(pos, ply);
}

pub fn isRepetition(pos: *const Position, ply: i32) bool {
    const rep = pos.st.repetition;
    return rep != 0 and rep < ply;
}

pub fn hasRepeated(pos: *const Position) bool {
    var stc: *const StateInfo = pos.st;
    var end = @min(pos.st.rule50, pos.st.plies_from_null);
    while (end >= 4) : (end -= 1) {
        if (stc.repetition != 0) return true;
        stc = stc.previous.?;
    }
    return false;
}

test {
    @import("std").testing.refAllDecls(@This());
}
