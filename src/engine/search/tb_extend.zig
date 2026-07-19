// Extend a tablebase-scored PV toward mate.
//
// Own upstream's syzygy_extend_pv (search.cpp:2096): hold the search PV while each move keeps the
// best available rank, truncate at the first move that does not, then walk toward mate on the
// top-ranked (minimal-DTZ) move. Borrow the scratch position and the DTZ ranking from
// root_move_build rather than restating them, and stay off the worker graph -- the reporter
// reaches this through the tb_extend_source seam, never by import.

const std = @import("std");
const position_port = @import("position");
const movegen_port = @import("movegen");
const option_port = @import("option_source");
const time_source = @import("time_source");
const tb_extend_port = @import("tb_extend_source");
const root_move_build = @import("root_move_build");

const ScratchPosition = root_move_build.ScratchPosition;
const RankedRootMove = root_move_build.RankedRootMove;
const buildRootFen = root_move_build.buildRootFen;
const rankMovesAt = root_move_build.rankMovesAt;
const stableSortRankedMovesByTbRank = root_move_build.stableSortRankedMovesByTbRank;
const loadPositionSnapshot = root_move_build.loadPositionSnapshot;

const value_draw: i32 = 0;
const castling_move_type: u16 = 3 << 14;
const en_passant_move_type: u16 = 2 << 14;

// Correct and extend the PV of a root move holding a tablebase score -- upstream
// syzygy_extend_pv (search.cpp:2096). Hold the search PV while each move keeps the best available
// rank, truncate at the first move that does not, then walk toward mate on the top-ranked
// (minimal-DTZ) move. The mate is optimal only for simple endgames such as KRvK.
//
// Walk one live position forward from the root. `isDraw`/`isRepetition` read the state history,
// so a position rebuilt from a FEN answers both wrongly.
pub const ExtendPvResult = tb_extend_port.ExtendPvResult;

// Bound the walk to half the Move Overhead while a clock runs, so extending cannot spend the
// move's time. Upstream: `2 * elapsed > moveOverhead`.
const ExtendDeadline = struct {
    start_ms: i64,
    move_overhead: i32,
    use_time_management: bool,

    fn expired(self: ExtendDeadline) bool {
        if (!self.use_time_management) return false;
        const elapsed = time_source.now() - self.start_ms;
        return 2 * elapsed > @as(i64, self.move_overhead);
    }
};

// Score a move by how much it restricts the opponent, breaking DTZ ties: charge 1 per reply and
// 100 per reply that captures. Upstream folds this into tbRank before ranking.
fn opponentMobilityPenalty(scratch: *ScratchPosition, raw_move: u16) !i32 {
    try scratch.doMove(raw_move);
    defer position_port.undoMove(scratch.pos, raw_move);

    var replies: [256]u16 = undefined;
    const count = movegen_port.generateLegal(scratch.pos, replies[0..]);
    var penalty: i32 = 0;
    for (replies[0..count]) |reply| {
        penalty -= if (isCaptureMove(scratch.pos, reply)) 100 else 1;
    }
    return penalty;
}

fn isCaptureMove(pos: *const position_port.Position, raw_move: u16) bool {
    const snapshot = loadPositionSnapshot(pos);
    const to: usize = (raw_move >> 6) & 0x3f;
    const move_type = raw_move & (3 << 14);
    return (snapshot.board[to] != 0 and move_type != castling_move_type) or
        move_type == en_passant_move_type;
}

pub fn syzygyExtendPv(
    pos: *const position_port.Position,
    chess960: u8,
    pv_moves: []u16,
    pv_len_in: usize,
    value_in: i32,
    use_time_management: bool,
) ExtendPvResult {
    var result = ExtendPvResult{ .pv_len = pv_len_in, .value = value_in, .timed_out = false };
    if (pv_len_in == 0) return result;

    const root_fen_c = buildRootFen(pos) orelse return result;
    const root_fen = std.mem.span(root_fen_c);
    defer std.heap.c_allocator.free(root_fen);

    const deadline = ExtendDeadline{
        .start_ms = time_source.now(),
        .move_overhead = option_port.intByName("Move Overhead"),
        .use_time_management = use_time_management,
    };
    const rule50 = option_port.syzygy50MoveRule();

    var scratch = ScratchPosition.init(root_fen, chess960) catch return result;
    defer scratch.deinit();

    // Step 0: play the root move uncorrected; MultiPV in TB requires it kept.
    scratch.doMove(pv_moves[0]) catch return result;
    var ply: usize = 1;

    var ranked: [256]RankedRootMove = undefined;

    // Step 1: walk the PV while each move still holds the best available rank.
    while (ply < result.pv_len) {
        const pv_move = pv_moves[ply];

        const fen_c = buildRootFen(scratch.pos) orelse break;
        const fen_text = std.mem.span(fen_c);
        var legal: [256]u16 = undefined;
        const legal_count = movegen_port.generateLegal(scratch.pos, legal[0..]);
        if (legal_count == 0) {
            std.heap.c_allocator.free(fen_text);
            break;
        }
        for (legal[0..legal_count], 0..) |m, i| {
            ranked[i] = .{ .raw_move = m, .reserved = 0, .tb_rank = 0, .tb_score = 0 };
        }
        const config = rankMovesAt(scratch.pos, fen_text, chess960, false, ranked[0..legal_count]) catch {
            std.heap.c_allocator.free(fen_text);
            break;
        };
        std.heap.c_allocator.free(fen_text);

        // rankMovesAt sorted the moves, so ranked[0] carries the best rank.
        var pv_rank: ?i32 = null;
        for (ranked[0..legal_count]) |m| {
            if (m.raw_move == pv_move) pv_rank = m.tb_rank;
        }
        if (pv_rank == null or ranked[0].tb_rank != pv_rank.?) break;

        ply += 1;
        scratch.doMove(pv_move) catch break;

        // Reject a repetition or drawing move inside the TB regime.
        if (config.root_in_tb != 0 and
            ((rule50 and position_port.isDraw(scratch.pos, @intCast(ply))) or
                position_port.isRepetition(scratch.pos, @intCast(ply))))
        {
            position_port.undoMove(scratch.pos, pv_move);
            ply -= 1;
            break;
        }

        // Report a full PV only when all of it validated within the deadline.
        if (config.root_in_tb != 0 and deadline.expired()) {
            result.timed_out = true;
            break;
        }
    }

    result.pv_len = ply;

    // Step 2: extend toward mate by always taking the top-ranked move.
    while (!(rule50 and position_port.isDraw(scratch.pos, 0))) {
        if (deadline.expired()) {
            result.timed_out = true;
            break;
        }
        if (result.pv_len >= pv_moves.len) break;

        var legal: [256]u16 = undefined;
        const legal_count = movegen_port.generateLegal(scratch.pos, legal[0..]);
        if (legal_count == 0) break; // mate found

        for (legal[0..legal_count], 0..) |m, i| {
            const penalty = opponentMobilityPenalty(&scratch, m) catch 0;
            ranked[i] = .{ .raw_move = m, .reserved = 0, .tb_rank = penalty, .tb_score = 0 };
        }

        // Pre-sort on the mobility tie-break; rankMovesAt's stable sort then keeps it as the
        // secondary key among moves of equal DTZ.
        stableSortRankedMovesByTbRank(ranked[0..legal_count]);

        const fen_c = buildRootFen(scratch.pos) orelse break;
        const fen_text = std.mem.span(fen_c);
        const config = rankMovesAt(scratch.pos, fen_text, chess960, true, ranked[0..legal_count]) catch {
            std.heap.c_allocator.free(fen_text);
            break;
        };
        std.heap.c_allocator.free(fen_text);

        // Without DTZ there may be no mate to reach.
        if (config.root_in_tb == 0 or config.cardinality > 0) break;

        const pv_move = ranked[0].raw_move;
        pv_moves[result.pv_len] = pv_move;
        result.pv_len += 1;
        scratch.doMove(pv_move) catch break;
    }

    // A draw here is exceptional: it requires rule50 on and a position reached with a non-optimal
    // 50-move counter, which DTZ rounding cannot rank correctly (Stockfish issue 5175). Report the
    // score of the PV actually found.
    if (position_port.isDraw(scratch.pos, 0)) result.value = value_draw;

    return result;
}
