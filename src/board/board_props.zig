// Board property tests (M17.4h).
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

const StateBuf = [state_info_size]u8;

fn perft(pos: *anyopaque, depth: c_int, states: *[perft_max_depth]StateBuf, ply: usize) u64 {
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
    var p: [position_size]u8 align(64) = undefined;
    var st: [state_info_size]u8 align(16) = undefined;
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

// For every legal move, do then immediately undo, and assert the Position is
// byte-for-byte the pre-move state -- key, bitboards, board, and piece counts.
// Perft only checks node COUNTS; this catches state corruption that leaves the
// count right but the derived state (e.g. an un-restored zobrist key, a stale
// bitboard, a leaked castling right) subtly wrong.
fn checkRoundTrip(fen: []const u8) !void {
    var p: [position_size]u8 align(64) = undefined;
    var st: [state_info_size]u8 align(16) = undefined;
    if (position.setPosition(&p, fen.ptr, fen.len, 0, &st, position_size, state_info_size)) |err| {
        std.heap.c_allocator.free(std.mem.span(err));
        @panic("checkRoundTrip: setPosition failed on a known-legal FEN");
    }
    const pos: *const position.Position = @ptrCast(&p);

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

        var new_st: [state_info_size]u8 align(16) = undefined;
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
    var p: [position_size]u8 align(64) = undefined;
    var st: [state_info_size]u8 align(16) = undefined;
    if (position.setPosition(&p, fen.ptr, fen.len, 0, &st, position_size, state_info_size)) |err| {
        std.heap.c_allocator.free(std.mem.span(err));
        @panic("checkFenRoundTrip: setPosition failed on a known-legal FEN");
    }
    const pos: *const position.Position = @ptrCast(&p);
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
