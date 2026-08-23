// Record threats for the NNUE threat feature set.
//
// Provide the dirty-threat machinery split out of move_do.zig (updatePieceThreats and its slider
// helpers) that do/undo-move calls whenever a piece lands on or leaves a square. A leaf --
// depends only on bitboard/board_core/position_types, never on move_do -- so the mutating
// half imports it one way and no cycle appears.
//
// Mirror upstream Position::update_piece_threats: the (attacker, attacked) pairs recorded
// here are exactly those the feature indexer encodes, so the filters are not an
// approximation -- rejecting the rest early is what upstream does too.

const build_options = @import("build_options");
const bitboard = @import("bitboard");
const board_core = @import("board_core");
const position_types = @import("position_types");
const threats_write_avx512 = @import("threats_write_avx512.zig");

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

fn addDirtyThreat(dts: *DirtyThreats, comptime put_piece: bool, pc: u8, threatened: u8, s: u8, threatened_sq: u8) void {
    const data: u32 = (@as(u32, @intFromBool(put_piece)) << 31) |
        (@as(u32, pc) << 20) | (@as(u32, threatened) << 16) |
        (@as(u32, threatened_sq) << 8) | @as(u32, s);
    dts.list_values[dts.list_size] = data;
    dts.list_size += 1;
}

fn processSliders(
    pos: *const Position,
    dts: *DirtyThreats,
    sliders_in: u64,
    s: u8,
    pc: u8,
    comptime put_piece: bool,
    no_rays: u64,
    slider_attacks: u64,
    occupied_no_k: u64,
    add_direct: bool,
) void {
    var sliders = sliders_in;
    while (sliders != 0) {
        const slider_sq: u8 = @intCast(@ctz(sliders));
        sliders &= sliders - 1;
        const slider = pos.board[slider_sq];
        const ray = bitboard.rayPass(slider_sq, s);
        const discovered = ray & slider_attacks & occupied_no_k;
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

// Count a threatened queen as a threat-feature only when the slider is itself a queen; every
// other threatened type always counts. Mirrors upstream `can_slider_threat`. Rejecting here is what
// keeps the dirty-threat list to the set the feature indexer accepts -- the combinations
// filtered out are exactly those fullMakeIndex maps out of range and the accumulator then
// discards, so recording them was pure work.
fn canSliderThreat(pc: u8, slider: u8) bool {
    return (pc & 7) != queen_pt or (slider & 7) == queen_pt;
}

/// Look the ray pair up for `s` -- the one input `updatePieceThreats` cannot derive from
/// the board it is handed, and the only one a caller can share between two calls over the
/// same square. See `move_do.swapPieceDts` for the case that shares it.
pub fn threatRays(pos: *const Position, s: u8) bitboard.DualAttacks {
    return bitboard.bothAttacks(s, pos.by_type_bb[0]);
}

pub fn updatePieceThreats(
    comptime compute_ray: bool,
    pos: *const Position,
    pc: u8,
    comptime put_piece: bool,
    s: u8,
    dts: *DirtyThreats,
    no_rays: u64,
) void {
    updatePieceThreatsRays(compute_ray, pos, pc, put_piece, s, dts, no_rays, threatRays(pos, s));
}

/// `updatePieceThreats` with the ray pair supplied, for the one caller that runs two scans
/// over the same square and can share the lookup between them. Every single-scan caller
/// keeps the plain entry point, so none of them pays to carry a pair it cannot share.
///
/// WHAT A SHARING CALLER MAY DO, and why. Two scans over one square may run against ONE
/// board even where the square's occupant differs between them -- which is what lets
/// `move_do.swapPieceDts` put the new piece down ahead of both. Every set either scan reads
/// is masked by an attack set computed FROM `s`: `attack_set`, `knight_pseudo`, the pawn
/// tables, and `sliders`, which is already masked by this ray pair. No attack set from `s`
/// contains `s`, so "s is empty" and "s holds pc" are the same board to both scans, and
/// `pos.board[s]` is never among the squares either one walks.
///
/// THE LIMIT: that holds only while `compute_ray` is false. `processSliders` is the one
/// reader of occupancy along a ray THROUGH `s`, and a ray extension past `s` does depend on
/// what sits there. A sharing caller passing `compute_ray = true` would be wrong, and
/// nothing here can catch it.
///
/// Adjacency alone does not reach the lookup: neither scan's result is available for
/// common-subexpression elimination across the stores the first one makes into the
/// dirty-threat list, so the shared pair has to be named and passed.
pub fn updatePieceThreatsRays(
    comptime compute_ray: bool,
    pos: *const Position,
    pc: u8,
    comptime put_piece: bool,
    s: u8,
    dts: *DirtyThreats,
    no_rays: u64,
    slider: bitboard.DualAttacks,
) void {
    // Ablation (-Dno-threat-record): drop the recording entirely. Sound ONLY together with
    // -Dacc-refresh-only, which rebuilds from the board and never reads a record; without it
    // the incremental step would apply an empty delta and the evaluation would be wrong.
    if (comptime build_options.no_threat_record) {
        if (comptime !build_options.acc_refresh_only)
            @compileError("-Dno-threat-record needs -Dacc-refresh-only: the incremental path reads the records this drops");
        return;
    }
    const occupied = pos.by_type_bb[0];
    // Both ray sets in one pass, as upstream's update_piece_threats does (position.cpp:1203)
    // -- now taken from the caller, which is what lets a swap share one lookup.
    const r_attacks = slider.rook;
    const b_attacks = slider.bishop;
    const slider_attacks = b_attacks | r_attacks;
    const kings = pos.by_type_bb[king_pt];
    const occupied_no_k = occupied ^ kings;
    const rook_queens = pos.by_type_bb[rook_pt] | pos.by_type_bb[queen_pt];
    const bishop_queens = pos.by_type_bb[bishop_pt] | pos.by_type_bb[queen_pt];
    const sliders = (bishop_queens & b_attacks) | (rook_queens & r_attacks);
    const pt = pc & 7;

    // Kings emit no direct threats.
    if (pt == king_pt) {
        if (compute_ray)
            processSliders(pos, dts, sliders, s, pc, put_piece, no_rays, slider_attacks, occupied_no_k, false);
        return;
    }

    const knights = pos.by_type_bb[knight_pt];
    const white_pawns = pos.by_color_bb[color_white] & pos.by_type_bb[pawn_pt];
    const black_pawns = pos.by_color_bb[color_black] & pos.by_type_bb[pawn_pt];
    // Read the knight table once: it is this piece's own attack set when pc is a knight, and
    // the set of knights attacking s in every case.
    const knight_pseudo = bitboard.attacks(knight_pt, s, 0);

    // Take this piece's attack set from the two ray sets bothAttacks already answered for `s`
    // -- upstream 1b1b5f49. A bishop wants the bishop rays, a rook the rook rays, a queen
    // both; a pawn and a knight want their tables, which read no occupancy at all.
    const attack_set = switch (pt) {
        bishop_pt => b_attacks,
        rook_pt => r_attacks,
        queen_pt => slider_attacks,
        pawn_pt => pawnAttacks(pc >> 3, s),
        else => knight_pseudo,
    };

    // Restrict both directions to the (attacker, attacked) pairs the threat feature set
    // actually encodes -- upstream rejects the rest here rather than letting the feature
    // indexer drop them later. With SFNNv16 pawn-pawn relationships moved to the PP_3Wide
    // feature set, so a pawn is no longer a threat target, and incoming pawn threats are
    // recorded only for knights and rooks (the pusher block is gone entirely). Every target
    // set below already excludes kings, so no separate `& occupied_no_k` pass is needed.
    const threat_targets = switch (pt) {
        pawn_pt => pos.by_type_bb[knight_pt] | pos.by_type_bb[rook_pt],
        bishop_pt, rook_pt => pos.by_type_bb[pawn_pt] | pos.by_type_bb[knight_pt] |
            pos.by_type_bb[bishop_pt] | pos.by_type_bb[rook_pt],
        else => occupied_no_k,
    };
    var threatened = attack_set & threat_targets;

    var incoming = knight_pseudo & knights;
    if (pt == knight_pt or pt == rook_pt) {
        incoming |= (pawnAttacks(color_white, s) & black_pawns) | (pawnAttacks(color_black, s) & white_pawns);
    }

    // Apply can_slider_threat in bitboard form: a threatened queen only counts against a queen.
    const direct_sliders = if (pt == queen_pt) sliders & pos.by_type_bb[queen_pt] else sliders;

    if (comptime threats_write_avx512.use_avx512_threats) {
        // Outgoing: PC on S threatens the piece on each square of `threatened`. The
        // template fixes add/pc/pc_sq; the threatened square and piece vary
        // (upstream position.cpp:1269).
        const outgoing_template: u32 = (@as(u32, @intFromBool(put_piece)) << 31) |
            (@as(u32, pc) << 20) | @as(u32, s);
        threats_write_avx512.writeMultipleDirties(pos, threatened, outgoing_template, 8, 16, dts);

        // Incoming: the piece on each square threatens PC on S. Fold the direct
        // sliders in HERE, unconditionally (not only on the !compute_ray branch the
        // scalar path below takes), and tell processSliders not to emit them again --
        // the control-flow half of this port, matching upstream position.cpp:1273/1293.
        const all_attackers = direct_sliders | incoming;
        const incoming_template: u32 = (@as(u32, @intFromBool(put_piece)) << 31) |
            (@as(u32, pc) << 16) | (@as(u32, s) << 8);
        threats_write_avx512.writeMultipleDirties(pos, all_attackers, incoming_template, 0, 20, dts);

        if (compute_ray) {
            processSliders(pos, dts, sliders, s, pc, put_piece, no_rays, slider_attacks, occupied_no_k, false);
        }
    } else {
        while (threatened != 0) {
            const tsq: u8 = @intCast(@ctz(threatened));
            threatened &= threatened - 1;
            addDirtyThreat(dts, put_piece, pc, pos.board[tsq], s, tsq);
        }

        if (compute_ray) {
            processSliders(pos, dts, sliders, s, pc, put_piece, no_rays, slider_attacks, occupied_no_k, true);
        } else {
            incoming |= direct_sliders;
        }

        while (incoming != 0) {
            const src_sq: u8 = @intCast(@ctz(incoming));
            incoming &= incoming - 1;
            addDirtyThreat(dts, put_piece, pos.board[src_sq], pc, src_sq, s);
        }
    }
}

test {
    @import("std").testing.refAllDecls(@This());
}
