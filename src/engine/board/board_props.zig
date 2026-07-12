// Board property tests.
//
// Real asserted invariants over the decomposed board leaves, not golden diffs:
// perft to KNOWN node counts. A perft count is an end-to-end property test of
// movegen + make/unmake together -- if legal-move generation OR do/undo were
// wrong, the counts diverge from these published Stockfish reference values. This
// runs in `zig build test` (no engine binary, no golden file), exercising the
// pure board path: zobrist tables + setPosition + generateLegal + doMoveState/
// undoMove. Enabled by the position.zig decomposition -- the whole board path is
// now reachable without pulling the search/engine graph at runtime.

const std = @import("std");
const position = @import("position");
const movegen = @import("movegen");
const graph_layout = @import("graph_layout");

const position_size = graph_layout.position_size;
const state_info_size = graph_layout.state_info_size;
const perft_max_depth = 8;

const StateBuf = position.StateInfo;

fn perft(pos: *position.Position, depth: c_int, states: *[perft_max_depth]StateBuf, ply: usize) u64 {
    if (depth <= 0) return 1;
    var moves: [256]u16 = undefined;
    const n = movegen.generateLegal(pos, &moves);
    if (depth == 1) return n;
    var nodes: u64 = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        position.doMoveState(pos, moves[i], &states[ply]);
        nodes += perft(pos, depth - 1, states, ply + 1);
        position.undoMove(pos, moves[i]);
    }
    return nodes;
}

fn perftFen(fen: []const u8, chess960: u8, depth: c_int) u64 {
    var p: position.Position align(64) = undefined;
    var st: position.StateInfo align(16) = undefined;
    if (position.setPosition(&p, fen.ptr, fen.len, chess960, &st, position_size, state_info_size)) |err| {
        std.heap.c_allocator.free(std.mem.span(err));
        @panic("perftFen: setPosition failed on a known-legal FEN");
    }
    var states: [perft_max_depth]StateBuf align(64) = undefined;
    return perft(&p, depth, &states, 0);
}

const start_fen = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1";
// Peter Ellis Jones' "Kiwipete" -- dense tactical node, catches castling / ep /
// promotion / pin bugs the start position misses.
const kiwipete_fen = "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1";

test "perft: start position matches reference node counts" {
    position.initRuntime();
    try std.testing.expectEqual(@as(u64, 20), perftFen(start_fen, 0, 1));
    try std.testing.expectEqual(@as(u64, 400), perftFen(start_fen, 0, 2));
    try std.testing.expectEqual(@as(u64, 8902), perftFen(start_fen, 0, 3));
    try std.testing.expectEqual(@as(u64, 197281), perftFen(start_fen, 0, 4));
}

test "perft: Kiwipete matches reference node counts" {
    position.initRuntime();
    try std.testing.expectEqual(@as(u64, 48), perftFen(kiwipete_fen, 0, 1));
    try std.testing.expectEqual(@as(u64, 2039), perftFen(kiwipete_fen, 0, 2));
    try std.testing.expectEqual(@as(u64, 97862), perftFen(kiwipete_fen, 0, 3));
}

// The remaining Chess Programming Wiki perft reference positions. Position 3 is an
// endgame rich in en-passant + rook checks; positions 4/5 are promotion-heavy
// (P/p on the 7th/2nd rank) and 5 is asymmetric; these hit make/unmake edge cases
// (ep capture-square, promotion material-key, castling-rights masking) that the
// start position and Kiwipete under-cover.
const cpw3_fen = "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1";
const cpw4_fen = "r3k2r/Pppp1ppp/1b3nbN/nP6/BBP1P3/q4N2/Pp1P2PP/R2Q1RK1 w kq - 0 1";
const cpw5_fen = "rnbq1k1r/pp1Pbppp/2p5/8/2B5/8/PPP1NnPP/RNBQK2R w KQ - 1 8";

test "perft: CPW reference positions 3-5 match reference node counts" {
    position.initRuntime();
    try std.testing.expectEqual(@as(u64, 14), perftFen(cpw3_fen, 0, 1));
    try std.testing.expectEqual(@as(u64, 191), perftFen(cpw3_fen, 0, 2));
    try std.testing.expectEqual(@as(u64, 2812), perftFen(cpw3_fen, 0, 3));
    try std.testing.expectEqual(@as(u64, 43238), perftFen(cpw3_fen, 0, 4));

    try std.testing.expectEqual(@as(u64, 6), perftFen(cpw4_fen, 0, 1));
    try std.testing.expectEqual(@as(u64, 264), perftFen(cpw4_fen, 0, 2));
    try std.testing.expectEqual(@as(u64, 9467), perftFen(cpw4_fen, 0, 3));

    try std.testing.expectEqual(@as(u64, 44), perftFen(cpw5_fen, 0, 1));
    try std.testing.expectEqual(@as(u64, 1486), perftFen(cpw5_fen, 0, 2));
    try std.testing.expectEqual(@as(u64, 62379), perftFen(cpw5_fen, 0, 3));
}

// For every legal move, do then immediately undo, and assert the Position is
// byte-for-byte the pre-move state -- key, bitboards, board, and piece counts.
// Perft only checks node COUNTS; this catches state corruption that leaves the
// count right but the derived state (e.g. an un-restored zobrist key, a stale
// bitboard, a leaked castling right) subtly wrong.
fn checkRoundTrip(fen: []const u8) !void {
    var p: position.Position align(64) = undefined;
    var st: position.StateInfo align(16) = undefined;
    if (position.setPosition(&p, fen.ptr, fen.len, 0, &st, position_size, state_info_size)) |err| {
        std.heap.c_allocator.free(std.mem.span(err));
        @panic("checkRoundTrip: setPosition failed on a known-legal FEN");
    }
    const pos = &p;

    var moves: [256]u16 = undefined;
    const n = movegen.generateLegal(&p, &moves);
    try std.testing.expect(n > 0);

    var i: usize = 0;
    while (i < n) : (i += 1) {
        const key0 = pos.st.key;
        const by_type0 = pos.by_type_bb;
        const by_color0 = pos.by_color_bb;
        const board0 = pos.board;
        const piece_count0 = pos.piece_count;

        var new_st: position.StateInfo align(16) = undefined;
        position.doMoveState(&p, moves[i], &new_st);
        position.undoMove(&p, moves[i]);

        try std.testing.expectEqual(key0, pos.st.key);
        try std.testing.expectEqual(by_type0, pos.by_type_bb);
        try std.testing.expectEqual(by_color0, pos.by_color_bb);
        try std.testing.expect(std.mem.eql(u8, &board0, &pos.board));
        try std.testing.expectEqual(piece_count0, pos.piece_count);
    }
}

test "make/unmake restores the position byte-exact" {
    position.initRuntime();
    try checkRoundTrip(start_fen);
    try checkRoundTrip(kiwipete_fen); // castling / en passant / promotion / pins
}

// Parse a FEN into a Position, then format the Position back out, and assert the
// result equals the input FEN. Exercises the setPosition (fen_parse) -> Position
// -> formatFen (fen) round-trip on a real parsed position (fen.zig's own test uses
// a synthetic board), catching any drift between the parse and format sides.
fn checkFenRoundTrip(fen: []const u8) !void {
    var p: position.Position align(64) = undefined;
    var st: position.StateInfo align(16) = undefined;
    if (position.setPosition(&p, fen.ptr, fen.len, 0, &st, position_size, state_info_size)) |err| {
        std.heap.c_allocator.free(std.mem.span(err));
        @panic("checkFenRoundTrip: setPosition failed on a known-legal FEN");
    }
    const pos = &p;
    const out = position.formatFen(
        &pos.board,
        pos.side_to_move,
        @intFromBool(pos.chess960),
        @intCast(pos.st.castling_rights),
        pos.castling_rook_square[1], // white_oo
        pos.castling_rook_square[2], // white_ooo
        pos.castling_rook_square[4], // black_oo
        pos.castling_rook_square[8], // black_ooo
        pos.st.ep_square,
        pos.st.rule50,
        pos.game_ply,
    ) orelse @panic("checkFenRoundTrip: formatFen returned null");
    defer std.heap.c_allocator.free(std.mem.span(out));
    try std.testing.expectEqualStrings(fen, std.mem.span(out));
}

test "FEN parse -> format round-trips" {
    position.initRuntime();
    try checkFenRoundTrip(start_fen);
    try checkFenRoundTrip(kiwipete_fen);
}

// Cross-check the movegen and legality leaves against each other: every move the
// generator emits as legal must also be accepted by the standalone legal() and
// pseudoLegal() predicates. A disagreement means the extracted legality leaf
// drifted from the generator's own legality filter (or vice versa) -- a class of
// bug perft can hide when two errors cancel in the count.
fn checkMoveGenLegalityAgree(fen: []const u8) !void {
    var p: position.Position align(64) = undefined;
    var st: position.StateInfo align(16) = undefined;
    if (position.setPosition(&p, fen.ptr, fen.len, 0, &st, position_size, state_info_size)) |err| {
        std.heap.c_allocator.free(std.mem.span(err));
        @panic("checkMoveGenLegalityAgree: setPosition failed on a known-legal FEN");
    }
    const pp = &p;
    var moves: [256]u16 = undefined;
    const n = movegen.generateLegal(&p, &moves);
    try std.testing.expect(n > 0);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        try std.testing.expect(position.legal(pp, moves[i]));
        try std.testing.expect(position.pseudoLegal(pp, moves[i]));
    }
}

test "generated legal moves satisfy legal() and pseudoLegal()" {
    position.initRuntime();
    try checkMoveGenLegalityAgree(start_fen);
    try checkMoveGenLegalityAgree(kiwipete_fen);
    try checkMoveGenLegalityAgree(cpw3_fen);
    try checkMoveGenLegalityAgree(cpw4_fen);
    try checkMoveGenLegalityAgree(cpw5_fen);
}

// givesCheck(m) predicts, without playing the move, whether m delivers check.
// Validate it against ground truth: play m, ask hasCheckers (is the now-to-move
// side in check), undo. They must agree for every legal move -- this cross-checks
// the givesCheck fast path (direct + discovered + castling/ep/promotion check
// detection) in the legality leaf against the actual post-move state.
fn checkGivesCheck(fen: []const u8) !void {
    var p: position.Position align(64) = undefined;
    var st: position.StateInfo align(16) = undefined;
    if (position.setPosition(&p, fen.ptr, fen.len, 0, &st, position_size, state_info_size)) |err| {
        std.heap.c_allocator.free(std.mem.span(err));
        @panic("checkGivesCheck: setPosition failed on a known-legal FEN");
    }
    const pp = &p;
    var moves: [256]u16 = undefined;
    const n = movegen.generateLegal(&p, &moves);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const predicted = position.givesCheck(&p, moves[i]);
        var new_st: position.StateInfo align(16) = undefined;
        position.doMoveState(&p, moves[i], &new_st);
        const actual = position.hasCheckers(pp);
        position.undoMove(&p, moves[i]);
        try std.testing.expectEqual(actual, predicted);
    }
}

test "givesCheck agrees with the post-move check state" {
    position.initRuntime();
    try checkGivesCheck(start_fen);
    try checkGivesCheck(kiwipete_fen);
    try checkGivesCheck(cpw3_fen);
    try checkGivesCheck(cpw4_fen);
    try checkGivesCheck(cpw5_fen);
}

// A null move flips the side to move (and clears any en-passant square + rehashes
// the side key) without moving a piece; undoing it must restore the position
// exactly. In between, the side and key must have actually changed. Exercises the
// move_do null-move path the search's null-move pruning relies on.
fn checkNullMoveRoundTrip(fen: []const u8) !void {
    var p: position.Position align(64) = undefined;
    var st: position.StateInfo align(16) = undefined;
    if (position.setPosition(&p, fen.ptr, fen.len, 0, &st, position_size, state_info_size)) |err| {
        std.heap.c_allocator.free(std.mem.span(err));
        @panic("checkNullMoveRoundTrip: setPosition failed on a known-legal FEN");
    }
    const pos = &p;

    const key0 = pos.st.key;
    const side0 = pos.side_to_move;

    var null_st: position.StateInfo align(16) = undefined;
    position.doNullMove(&p, &null_st);
    try std.testing.expect(pos.side_to_move != side0); // side flipped
    try std.testing.expect(pos.st.key != key0); // key rehashed

    position.undoNullMove(&p);
    try std.testing.expectEqual(key0, pos.st.key); // key restored
    try std.testing.expectEqual(side0, pos.side_to_move); // side restored
}

test "null move round-trips" {
    position.initRuntime();
    try checkNullMoveRoundTrip(start_fen);
    try checkNullMoveRoundTrip(kiwipete_fen);
}

fn sq(file: u8, rank: u8) u8 {
    return rank * 8 + file;
}
fn mkMove(from: u8, to: u8) u16 {
    return (@as(u16, from) << 6) | @as(u16, to);
}

// Play both knights out and straight back (Nf3 Nc6 Ng1 Nb8): four reversible
// moves that return to a position identical to the start (same key -- move
// counters are not hashed), so the make/unmake repetition detector must flag it.
// The StateInfo chain must stay live across the moves, so each ply gets its own
// buffer (do NOT reuse one). hasRepeated walks that chain; it is false before the
// cycle closes and true once the start position recurs.
test "repetition detection flags a returned-to position" {
    position.initRuntime();
    var p: position.Position align(64) = undefined;
    var st: position.StateInfo align(16) = undefined;
    setup(&p, &st, start_fen);

    const moves = [_]u16{
        mkMove(sq(6, 0), sq(5, 2)), // Ng1-f3
        mkMove(sq(1, 7), sq(2, 5)), // Nb8-c6
        mkMove(sq(5, 2), sq(6, 0)), // Nf3-g1
        mkMove(sq(2, 5), sq(1, 7)), // Nc6-b8  (position == start)
    };
    var chain: [8]position.StateInfo align(16) = undefined;

    for (moves, 0..) |m, ply| {
        try std.testing.expect(!position.hasRepeated(&p)); // not yet repeated
        position.doMoveState(&p, m, &chain[ply]);
    }
    // After the fourth move the start position has recurred.
    try std.testing.expect(position.hasRepeated(&p));
}

// The parser must REJECT malformed input with an error message, not crash or
// silently accept it. Each of these violates a documented FEN invariant.
fn expectRejected(fen: []const u8) !void {
    var p: position.Position align(64) = undefined;
    var st: position.StateInfo align(16) = undefined;
    const err = position.setPosition(&p, fen.ptr, fen.len, 0, &st, position_size, state_info_size);
    if (err) |msg| {
        std.heap.c_allocator.free(std.mem.span(msg)); // rejected as expected
    } else {
        std.debug.print("FEN was accepted but should have been rejected: {s}\n", .{fen});
        return error.TestUnexpectedResult;
    }
}

test "malformed FENs are rejected, not accepted or crashed" {
    position.initRuntime();
    try expectRejected(""); // empty
    try expectRejected("8/8/8/8/8/8/8/8 w - - 0 1"); // no kings
    try expectRejected("3kk3/8/8/8/8/8/8/4K3 w - - 0 1"); // two black kings
    try expectRejected("9/8/8/8/8/8/8/8 w - - 0 1"); // 9 skipped squares in a rank
    try expectRejected("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNX w KQkq - 0 1"); // bad piece 'X'
    try expectRejected("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR x KQkq - 0 1"); // bad side 'x'
    try expectRejected("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBN w KQkq - 0 1"); // short back rank
    try expectRejected("4k3/8/8/8/8/8/8/4K3 w - z9 0 1"); // bad en-passant square
}

// FEN characters + separators + a few out-of-band bytes, so random strings drawn
// from this alphabet hit both the parser's happy path and its reject branches.
const fen_alphabet = "PNBRQKpnbrqk12345678/ wb-KQkqabcdefgh36xz0";

// Property (fuzz): setPosition must never crash / OOB on arbitrary input -- it
// either rejects it or produces a self-consistent position. And any position it
// DOES accept must survive movegen + one make/unmake without crashing. A
// deterministic PRNG (fixed seed) keeps it reproducible in `zig build test`; it is
// also the natural seed corpus for a real `--fuzz` run.
test "fuzz: setPosition tolerates arbitrary input without crashing" {
    position.initRuntime();
    var prng = std.Random.DefaultPrng.init(0x5EED_F00D);
    const rand = prng.random();

    var iter: usize = 0;
    while (iter < 50_000) : (iter += 1) {
        var buf: [96]u8 = undefined;
        const len = rand.intRangeAtMost(usize, 0, buf.len);
        for (buf[0..len]) |*byte| byte.* = fen_alphabet[rand.uintLessThan(usize, fen_alphabet.len)];

        var p: position.Position align(64) = undefined;
        var st: position.StateInfo align(16) = undefined;
        const err = position.setPosition(&p, &buf, len, 0, &st, position_size, state_info_size);
        if (err) |msg| {
            std.heap.c_allocator.free(std.mem.span(msg));
            continue; // rejected -- fine
        }
        // Accepted as a legal position: legal-move generation + one round-trip
        // must not crash on it either.
        var moves: [256]u16 = undefined;
        const n = movegen.generateLegal(&p, &moves);
        if (n > 0) {
            var new_st: position.StateInfo align(16) = undefined;
            position.doMoveState(&p, moves[0], &new_st);
            position.undoMove(&p, moves[0]);
        }
    }
}

// isDraw: the 50-move rule fires once rule50 exceeds 99 (in a non-mate position);
// a fresh position is not a draw.
test "isDraw honours the fifty-move rule" {
    position.initRuntime();
    var p: position.Position align(64) = undefined;
    var st: position.StateInfo align(16) = undefined;
    const pp = &p;

    // rule50 = 100 half-moves, not in check, legal moves available -> draw.
    setup(&p, &st, "4k3/8/8/8/8/8/8/4K3 w - - 100 60");
    try std.testing.expect(position.isDraw(pp, 0));

    // The start position is not a draw.
    setup(&p, &st, start_fen);
    try std.testing.expect(!position.isDraw(pp, 0));
}

fn setup(p: *position.Position, st: *position.StateInfo, fen: []const u8) void {
    if (position.setPosition(p, fen.ptr, fen.len, 0, st, position_size, state_info_size)) |err| {
        std.heap.c_allocator.free(std.mem.span(err));
        @panic("setup: setPosition failed on a known-legal FEN");
    }
}

// Static Exchange Evaluation (the seeGe predicate in the legality leaf). A pawn
// capturing an undefended queen is a large winning exchange; a queen capturing a
// pawn defended by a pawn is a large losing one. seeGe(move, t) answers SEE >= t.
test "seeGe classifies winning and losing captures" {
    position.initRuntime();
    var p: position.Position align(64) = undefined;
    var st: position.StateInfo align(16) = undefined;
    const pp = &p;

    // White pawn e4 captures an undefended black queen on d5.
    setup(&p, &st, "4k3/8/8/3q4/4P3/8/8/4K3 w - - 0 1");
    const pxq = mkMove(sq(4, 3), sq(3, 4)); // e4 -> d5
    try std.testing.expect(position.seeGe(pp, pxq, 0)); // winning: SEE >= 0
    try std.testing.expect(position.seeGe(pp, pxq, 1000)); // still wins a queen
    try std.testing.expect(!position.seeGe(pp, pxq, 3000)); // but not >= 3000

    // White queen d4 captures a black pawn c5 that is defended by the b6 pawn.
    setup(&p, &st, "4k3/8/1p6/2p5/3Q4/8/8/4K3 w - - 0 1");
    const qxp = mkMove(sq(3, 3), sq(2, 4)); // d4 -> c5
    try std.testing.expect(!position.seeGe(pp, qxp, 0)); // losing: SEE < 0
}

// refAllDecls over the board path + the typed-view graph, so every pub decl
// compiles under `zig build test` even if the exe never reaches it (catches dead/
// broken code the golden gates and the property tests above miss). Non-recursive is
// the Zig 0.16 std.testing API; it forces each module's top-level pub decls.
test "all public decls compile (position + movegen + graph_layout)" {
    std.testing.refAllDecls(position);
    std.testing.refAllDecls(movegen);
    std.testing.refAllDecls(graph_layout);
}
