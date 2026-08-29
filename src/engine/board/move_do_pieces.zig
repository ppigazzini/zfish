// Place, lift and move a piece on the board -- the primitives every board mutation is
// built from, split out of move_do.zig.
//
// Two families, and the difference is what they RECORD. The `*Dts` forms drive
// move_do_threats.updatePieceThreats on either side of the board edit, so the per-ply
// dirty-threat list the NNUE accumulator reads comes out of the same walk that moves the
// piece; the plain forms edit the board alone and are for the paths that keep no diff
// (undoMove, which replays a diff already recorded, and FEN setup).
//
// Every one of them keeps the four board representations in step: the occupancy plane, the
// per-type plane, the per-colour plane and the mailbox, plus the two piece counts.

const board_core = @import("board_core");
const position_types = @import("position_types");
const move_do_threats = @import("move_do_threats.zig");

const Position = position_types.Position;
const DirtyThreats = position_types.DirtyThreats;

const sqBb = board_core.sqBb;
const max_u64: u64 = 0xFFFFFFFFFFFFFFFF;

pub fn removePieceDts(pos: *Position, s: u8, dts: *DirtyThreats) void {
    const pc = pos.board[s];
    move_do_threats.updatePieceThreats(true, pos, pc, false, s, dts, max_u64);
    const bb = sqBb(s);
    pos.by_type_bb[0] ^= bb;
    pos.by_type_bb[pc & 7] ^= bb;
    pos.by_color_bb[pc >> 3] ^= bb;
    pos.board[s] = 0;
    pos.piece_count[pc] -= 1;
    pos.piece_count[(pc >> 3) << 3] -= 1;
}

pub fn putPieceDts(pos: *Position, pc: u8, s: u8, dts: *DirtyThreats) void {
    const bb = sqBb(s);
    pos.board[s] = pc;
    pos.by_type_bb[pc & 7] |= bb;
    pos.by_type_bb[0] |= pos.by_type_bb[pc & 7];
    pos.by_color_bb[pc >> 3] |= bb;
    pos.piece_count[pc] += 1;
    pos.piece_count[(pc >> 3) << 3] += 1;
    move_do_threats.updatePieceThreats(true, pos, pc, true, s, dts, max_u64);
}

pub fn movePieceDts(pos: *Position, from: u8, to: u8, dts: *DirtyThreats) void {
    const pc = pos.board[from];
    const from_to = sqBb(from) | sqBb(to);
    move_do_threats.updatePieceThreats(true, pos, pc, false, from, dts, from_to);
    pos.by_type_bb[0] ^= from_to;
    pos.by_type_bb[pc & 7] ^= from_to;
    pos.by_color_bb[pc >> 3] ^= from_to;
    pos.board[from] = 0;
    pos.board[to] = pc;
    move_do_threats.updatePieceThreats(true, pos, pc, true, to, dts, from_to);
}

pub fn swapPieceDts(pos: *Position, s: u8, pc: u8, dts: *DirtyThreats) void {
    const old = pos.board[s];
    removePiece(pos, s); // dts=nullptr in swap_piece
    // Put the piece down BEFORE both scans, so one ray lookup serves them both. Why the two
    // scans cannot tell the boards apart is stated on `updatePieceThreatsRays`, which is the
    // contract that permits it.
    putPiece(pos, pc, s);
    const rays = move_do_threats.threatRays(pos, s);
    move_do_threats.updatePieceThreatsRays(false, pos, old, false, s, dts, max_u64, rays);
    move_do_threats.updatePieceThreatsRays(false, pos, pc, true, s, dts, max_u64, rays);
}

pub fn removePiece(pos: *Position, s: u8) void {
    const pc = pos.board[s];
    const bb = sqBb(s);
    pos.by_type_bb[0] ^= bb;
    pos.by_type_bb[pc & 7] ^= bb;
    pos.by_color_bb[pc >> 3] ^= bb;
    pos.board[s] = 0;
    pos.piece_count[pc] -= 1;
    pos.piece_count[(pc >> 3) << 3] -= 1;
}

pub fn movePieceQuiet(pos: *Position, from: u8, to: u8) void {
    const pc = pos.board[from];
    const from_to = sqBb(from) | sqBb(to);
    pos.by_type_bb[0] ^= from_to;
    pos.by_type_bb[pc & 7] ^= from_to;
    pos.by_color_bb[pc >> 3] ^= from_to;
    pos.board[from] = 0;
    pos.board[to] = pc;
}

pub fn swapPiece(pos: *Position, s: u8, pc: u8) void {
    removePiece(pos, s);
    putPiece(pos, pc, s);
}

pub fn putPiece(pos: *Position, pc: u8, s: u8) void {
    const bb = sqBb(s);
    pos.board[s] = pc;
    pos.by_type_bb[pc & 7] |= bb;
    pos.by_type_bb[0] |= pos.by_type_bb[pc & 7];
    pos.by_color_bb[pc >> 3] |= bb;
    pos.piece_count[pc] += 1;
    pos.piece_count[(pc >> 3) << 3] += 1; // make_piece(color, ALL_PIECES)
}
