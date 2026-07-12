// Node-level accumulator / do-move / eval helpers. The small QCtx-carrying
// primitives the qsearch/search recursion calls per node: the seldepth/LMR-reduction
// reads, the NNUE evaluate, the accumulator-slot do_move/undo_move, the verify
// make/unmake, and the legal-move membership test. None call back into the
// recursion, so this is a std-free leaf over the board/eval leaves + the search_ctx
// QCtx; search_driver imports it one-way.

const network_port = @import("network");
const evaluate_mod = @import("evaluate");
const nnue_acc = @import("nnue_accumulator");
const move_do = @import("move_do");
const legality = @import("legality");
const search_common = @import("search_common");
const history_mod = @import("history");
const board_core = @import("board_core");
const movegen = @import("movegen");
const position_types = @import("position_types");
const search_types = @import("search_types");
const search_ctx = @import("search_ctx");

const Position = position_types.Position;
const StateInfo = position_types.StateInfo;
const DirtyPiece = position_types.DirtyPiece;
const DirtyThreats = position_types.DirtyThreats;
const SearchStack = search_types.SearchStack;
const QCtx = search_ctx.QCtx;
const captureStage = search_common.captureStage;
const setContHist = history_mod.setContHist;
const moveTo = board_core.moveTo;
const doMove = move_do.doMove;
const undoMove = move_do.undoMove;
const givesCheck = legality.givesCheck;

// q_value_mate(32000) - q_max_ply(246) - 1 - q_max_ply(246); the TB win-in-max-ply
// eval clamp bound (VALUE_TB_WIN_IN_MAX_PLY).
const q_value_tb_win: c_int = 31507;

pub inline fn updateSelDepth(ctx: *const QCtx, ply: c_int) void {
    if (ctx.sel_depth.* < ply + 1) ctx.sel_depth.* = ply + 1;
}

// The LMR reduction step: the LMR base reduction from the per-thread reductions
// table, the root delta, and the improving flag. Uses truncating integer division.
pub inline fn reductionAcc(ctx: *const QCtx, i: bool, d: c_int, mn: c_int, delta: c_int) c_int {
    const reduction_scale = ctx.reductions[@intCast(d)] * ctx.reductions[@intCast(mn)];
    return reduction_scale - @divTrunc(delta * 617, ctx.root_delta.*) +
        @divTrunc(@as(c_int, @intFromBool(!i)) * reduction_scale * 194, 512) + 1027;
}

// The evaluate step: run the NNUE forward pass on the current position,
// then apply the eval scaling. Material is 534 * pawn count (both colours) +
// non-pawn material, optimism is indexed by the side to move, and the TB clamp
// bounds are +/-VALUE_TB_WIN_IN_MAX_PLY.
pub inline fn evaluateAcc(ctx: *const QCtx, pos_ptr: *const Position) c_int {
    const pos = pos_ptr;
    const out = network_port.evaluate(pos_ptr, ctx.acc_stack, ctx.cache);
    const pawns = pos.piece_count[1] + pos.piece_count[9];
    const material = 534 * pawns + pos.st.non_pawn_material[0] + pos.st.non_pawn_material[1];
    return evaluate_mod.computeValue(.{
        .psqt = out.psqt,
        .positional = out.positional,
        .optimism = ctx.optimism[pos.side_to_move],
        .material = material,
        .rule50_count = pos.st.rule50,
        .value_tb_loss_in_max_ply = -q_value_tb_win,
        .value_tb_win_in_max_ply = q_value_tb_win,
    });
}

// The do-move step: count the node, push a fresh accumulator slot, make the
// move (the make-move records the dirty piece/threats into that slot), then set
// the Stack's current move and continuation-history pointer. capture_stage is read
// pre-move, dirtyPiece.pc post-move.
pub inline fn doMoveAcc(ctx: *const QCtx, pos_ptr: *Position, move: u16, st_ptr: *StateInfo, gives_check: u8, ss_ptr: *SearchStack) void {
    const pos = pos_ptr;
    const ss = ss_ptr;
    const capture = captureStage(pos, move);
    ctx.nodes.* +%= 1;
    const out = nnue_acc.stackPush(ctx.acc_stack);
    doMove(pos_ptr, move, st_ptr, gives_check, out.dirty_piece, out.dirty_threats);
    const dp: *const DirtyPiece = out.dirty_piece;
    ss.current_move = move;
    setContHist(ctx.worker, ss_ptr, @intFromBool(ss.in_check), @intFromBool(capture), dp.pc, moveTo(move));
}

// The undo-move step: unmake the move, then drop the accumulator slot.
pub inline fn undoMoveAcc(ctx: *const QCtx, pos_ptr: *Position, move: u16) void {
    undoMove(pos_ptr, move);
    nnue_acc.stackPop(ctx.acc_stack);
}

// Position-level verification make/unmake used by the qsearch TT-move cutoff.
// gives_check is computed here, a fresh DirtyThreats list and a throwaway
// DirtyPiece are passed as scratch (no accumulator slot is pushed, so the dirty
// state doMove writes is never consumed). undo is the plain Position-level unmake.
pub inline fn verifyDoMove(pos_ptr: *Position, move: u16, st_ptr: *StateInfo) void {
    var dp: DirtyPiece = undefined;
    var dts: DirtyThreats = undefined;
    dts.list_size = 0;
    doMove(pos_ptr, move, st_ptr, @intFromBool(givesCheck(pos_ptr, move)), &dp, &dts);
}

pub inline fn verifyUndoMove(pos_ptr: *Position, move: u16) void {
    undoMove(pos_ptr, move);
}

// Is `move` in the legal move list of the current position?
pub fn legalContains(pos_ptr: *const Position, move: u16) bool {
    var buf: [256]u16 = undefined;
    const n = movegen.generateLegal(pos_ptr, &buf);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (buf[i] == move) return true;
    }
    return false;
}
