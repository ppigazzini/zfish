// Threat recording for the NNUE threat feature set.
//
// Split out of move_do.zig: the dirty-threat machinery (updatePieceThreats and its slider
// helpers) that do/undo-move calls whenever a piece lands on or leaves a square. A leaf --
// depends only on bitboard/board_core/position_types, never on move_do -- so the mutating
// half imports it one way and no cycle appears.
//
// Mirrors upstream Position::update_piece_threats: the (attacker, attacked) pairs recorded
// here are exactly those the feature indexer encodes, so the filters are not an
// approximation -- rejecting the rest early is what upstream does too.

const bitboard = @import("bitboard");
const board_core = @import("board_core");
const position_types = @import("position_types");

const Position = position_types.Position;
const DirtyThreats = position_types.DirtyThreats;

const pawn_pt = board_core.pawn_pt;
const knight_pt = board_core.knight_pt;
const bishop_pt = board_core.bishop_pt;
const rook_pt = board_core.rook_pt;
const queen_pt = board_core.queen_pt;
const king_pt = board_core.king_pt;
const color_white = board_core.color_white;
const color_black = board_core.color_black;
const sqBb = board_core.sqBb;
const pawnAttacks = board_core.pawnAttacks;

fn addDirtyThreat(dts: *DirtyThreats, put_piece: bool, pc: u8, threatened: u8, s: u8, threatened_sq: u8) void {
    const data: u32 = (@as(u32, @intFromBool(put_piece)) << 31) |
        (@as(u32, pc) << 20) | (@as(u32, threatened) << 16) |
        (@as(u32, threatened_sq) << 8) | @as(u32, s);
    dts.list_values[dts.list_size] = data;
    dts.list_size += 1;
}

fn pawnPushOrAttacks(c: u8, s: u8) u64 {
    const b = sqBb(s);
    const push = if (c == color_white) b << 8 else b >> 8;
    return push | pawnAttacks(c, s);
}

fn processSliders(
    pos: *const Position,
    dts: *DirtyThreats,
    sliders_in: u64,
    s: u8,
    pc: u8,
    put_piece: bool,
    no_rays: u64,
    r_attacks: u64,
    b_attacks: u64,
    occupied_no_k: u64,
    add_direct: bool,
) void {
    var sliders = sliders_in;
    while (sliders != 0) {
        const slider_sq: u8 = @intCast(@ctz(sliders));
        sliders &= sliders - 1;
        const slider = pos.board[slider_sq];
        const ray = bitboard.rayPass(slider_sq, s);
        const discovered = ray & (r_attacks | b_attacks) & occupied_no_k;
        if (discovered != 0 and (ray & no_rays) != no_rays) {
            const tsq: u8 = @intCast(@ctz(discovered));
            const tpc = pos.board[tsq];
            if (canSliderThreat(tpc, slider))
                addDirtyThreat(dts, !put_piece, slider, tpc, slider_sq, tsq);
        }
        if (add_direct and canSliderThreat(pc, slider))
            addDirtyThreat(dts, put_piece, slider, pc, slider_sq, s);
    }
}

// A threatened queen is only a threat-feature when the slider is itself a queen; every
// other threatened type is. Mirrors upstream `can_slider_threat`. Rejecting here is what
// keeps the dirty-threat list to the set the feature indexer accepts -- the combinations
// filtered out are exactly those fullMakeIndex maps out of range and the accumulator then
// discards, so recording them was pure work.
fn canSliderThreat(pc: u8, slider: u8) bool {
    return (pc & 7) != queen_pt or (slider & 7) == queen_pt;
}

pub fn updatePieceThreats(
    comptime compute_ray: bool,
    pos: *const Position,
    pc: u8,
    put_piece: bool,
    s: u8,
    dts: *DirtyThreats,
    no_rays: u64,
) void {
    const occupied = pos.by_type_bb[0];
    const rook_queens = pos.by_type_bb[rook_pt] | pos.by_type_bb[queen_pt];
    const bishop_queens = pos.by_type_bb[bishop_pt] | pos.by_type_bb[queen_pt];
    const r_attacks = bitboard.attacks(rook_pt, s, occupied);
    const b_attacks = bitboard.attacks(bishop_pt, s, occupied);
    const kings = pos.by_type_bb[king_pt];
    const occupied_no_k = occupied ^ kings;
    const sliders = (rook_queens & r_attacks) | (bishop_queens & b_attacks);
    // can_slider_threat in bitboard form: a threatened queen only counts against a queen.
    const direct_sliders = if ((pc & 7) == queen_pt) sliders & pos.by_type_bb[queen_pt] else sliders;

    if ((pc & 7) == king_pt) {
        if (compute_ray)
            processSliders(pos, dts, sliders, s, pc, put_piece, no_rays, r_attacks, b_attacks, occupied_no_k, false);
        return;
    }

    const knights = pos.by_type_bb[knight_pt];
    const white_pawns = pos.by_color_bb[color_white] & pos.by_type_bb[pawn_pt];
    const black_pawns = pos.by_color_bb[color_black] & pos.by_type_bb[pawn_pt];

    var threatened = (if ((pc & 7) == pawn_pt) pawnAttacks(pc >> 3, s) else bitboard.attacks(pc & 7, s, occupied)) & occupied_no_k;
    var incoming = bitboard.attacks(knight_pt, s, 0) & knights;

    var pawn_threats: u64 = 0;
    if ((pc & 7) == pawn_pt) {
        const white_attacks = pawnPushOrAttacks(color_white, s);
        const black_attacks = pawnPushOrAttacks(color_black, s);
        threatened |= (if ((pc >> 3) == color_white) white_attacks else black_attacks) & pos.by_type_bb[pawn_pt];
        pawn_threats = (white_attacks & black_pawns) | (black_attacks & white_pawns);
    } else {
        pawn_threats = (pawnAttacks(color_white, s) & black_pawns) | (pawnAttacks(color_black, s) & white_pawns);
    }

    // Restrict both directions to the (attacker, attacked) pairs the threat feature set
    // actually encodes -- upstream rejects the rest here rather than letting the feature
    // indexer drop them later.
    const pt = pc & 7;
    if (pt == pawn_pt or pt == knight_pt or pt == rook_pt) incoming |= pawn_threats;
    switch (pt) {
        pawn_pt => threatened &= pos.by_type_bb[pawn_pt] | pos.by_type_bb[knight_pt] | pos.by_type_bb[rook_pt],
        bishop_pt, rook_pt => threatened &= pos.by_type_bb[pawn_pt] | pos.by_type_bb[knight_pt] |
            pos.by_type_bb[bishop_pt] | pos.by_type_bb[rook_pt],
        else => {},
    }

    while (threatened != 0) {
        const tsq: u8 = @intCast(@ctz(threatened));
        threatened &= threatened - 1;
        addDirtyThreat(dts, put_piece, pc, pos.board[tsq], s, tsq);
    }

    if (compute_ray) {
        processSliders(pos, dts, sliders, s, pc, put_piece, no_rays, r_attacks, b_attacks, occupied_no_k, true);
    } else {
        incoming |= direct_sliders;
    }

    while (incoming != 0) {
        const src_sq: u8 = @intCast(@ctz(incoming));
        incoming &= incoming - 1;
        addDirtyThreat(dts, put_piece, pos.board[src_sq], pc, src_sq, s);
    }
}

test {
    @import("std").testing.refAllDecls(@This());
}
