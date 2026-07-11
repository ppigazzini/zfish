// Coverage-guided fuzz targets (M17.5i).
//
// Real std.testing.fuzz targets driven by the Zig fuzzer's Smith input model, kept
// in a DEDICATED artifact wired to the `zig build fuzz` step -- deliberately OUT of
// the normal `zig build test` path (std.testing.fuzz depends on the fuzz runner via
// @import("root").fuzz; under a plain run each target executes once as a smoke, and
// under `zig build fuzz --fuzz` the fuzzer mutates toward new coverage). Complements
// the deterministic-PRNG fuzz in board_props.zig / uci_parse.zig (which run in the
// safety-checked CI test gate); here the input is coverage-guided instead of random.
//
// Build for real fuzzing under ReleaseSafe so a discovered crash trips a Zig safety
// check (bounds / overflow / alignment / null) rather than silently reading garbage.

const std = @import("std");
const position = @import("position");
const movegen = @import("movegen");
const graph_layout = @import("graph_layout");
const position_snapshot = @import("position_snapshot");

const position_size = graph_layout.position_size;
const state_info_size = graph_layout.state_info_size;

// The stored (incremental) zobrist key of the current position -- fillSnapshot copies
// `st.key`, the value doMove maintains, NOT a recomputed one, so comparing it across a
// make/unmake round-trip is a genuine incremental-hash correctness check.
fn positionKey(p: *const position.Position) u64 {
    var snap: position_snapshot.PositionSnapshot = undefined;
    position.fillSnapshot(p, &snap);
    return snap.key;
}

// Property: setPosition must never crash / OOB on arbitrary input -- it rejects it
// or produces a self-consistent position, and any position it accepts must survive
// generateLegal + one make/unmake. The coverage-guided fuzzer explores toward
// inputs that pass more of the parser than random bytes would reach.
fn fuzzSetPosition(_: void, smith: *std.testing.Smith) anyerror!void {
    var raw: [129]u8 = undefined;
    smith.bytesWithHash(&raw, 1);
    const len = @as(usize, raw[0]) % (raw.len - 1); // 0..127, drawn from the input
    const fen = raw[1..][0..len];

    var p: position.Position align(64) = undefined;
    var st: position.StateInfo align(16) = undefined;
    const err = position.setPosition(&p, fen.ptr, fen.len, 0, &st, position_size, state_info_size);
    if (err) |msg| {
        std.heap.c_allocator.free(std.mem.span(msg));
        return; // rejected -- fine
    }
    var moves: [256]u16 = undefined;
    const n = movegen.generateLegal(&p, &moves);
    if (n > 0) {
        var new_st: position.StateInfo align(16) = undefined;
        position.doMoveState(&p, moves[0], &new_st);
        position.undoMove(&p, moves[0]);
    }
}

test "fuzz: setPosition tolerates coverage-guided input" {
    position.initRuntime();
    try std.testing.fuzz({}, fuzzSetPosition, .{});
}

const start_fen = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1";

// Property: playing a deep sequence of legal moves (each picked from the current
// legal list by a fuzzer byte) then unwinding it must never crash. This stresses
// make/unmake far past the single-move setPosition fuzz -- the StateInfo previous-
// chain grows one live buffer per ply, repetition/50-move detection runs at every
// make, and undo must restore each ply byte-exactly. The coverage-guided fuzzer
// steers the byte stream toward move sequences that reach deeper board states.
fn fuzzRandomGame(_: void, smith: *std.testing.Smith) anyerror!void {
    var choices: [96]u8 = undefined;
    smith.bytesWithHash(&choices, 3);

    var p: position.Position align(64) = undefined;
    var st: position.StateInfo align(16) = undefined;
    if (position.setPosition(&p, start_fen, start_fen.len, 0, &st, position_size, state_info_size)) |msg| {
        std.heap.c_allocator.free(std.mem.span(msg));
        return; // start position is always legal, but stay defensive
    }

    var chain: [choices.len]position.StateInfo align(16) = undefined;
    var played: [choices.len]u16 = undefined;
    var ply: usize = 0;
    while (ply < choices.len) : (ply += 1) {
        var moves: [256]u16 = undefined;
        const n = movegen.generateLegal(&p, &moves);
        if (n == 0) break; // checkmate or stalemate -- game over
        const pick = moves[choices[ply] % n];
        played[ply] = pick;
        position.doMoveState(&p, pick, &chain[ply]);
    }
    // Unwind the whole line, exercising undoMove at every ply.
    while (ply > 0) {
        ply -= 1;
        position.undoMove(&p, played[ply]);
    }
}

test "fuzz: deep random legal-move games make/unmake cleanly" {
    position.initRuntime();
    try std.testing.fuzz({}, fuzzRandomGame, .{});
}

// Property: a deep line of legal moves, fully unwound, must restore the incremental
// zobrist key byte-exactly. This is a correctness invariant far stronger than "doesn't
// crash" -- a make/unmake key desync (mis-hashed castling right, en-passant file, or
// side-to-move) survives fuzzRandomGame silently but is caught here. The coverage-
// guided fuzzer steers toward lines that reach the rarely-hit hashing branches.
fn fuzzKeyStability(_: void, smith: *std.testing.Smith) anyerror!void {
    var choices: [96]u8 = undefined;
    smith.bytesWithHash(&choices, 3);

    var p: position.Position align(64) = undefined;
    var st: position.StateInfo align(16) = undefined;
    if (position.setPosition(&p, start_fen, start_fen.len, 0, &st, position_size, state_info_size)) |msg| {
        std.heap.c_allocator.free(std.mem.span(msg));
        return;
    }
    const key0 = positionKey(&p);

    var chain: [choices.len]position.StateInfo align(16) = undefined;
    var played: [choices.len]u16 = undefined;
    var ply: usize = 0;
    while (ply < choices.len) : (ply += 1) {
        var moves: [256]u16 = undefined;
        const n = movegen.generateLegal(&p, &moves);
        if (n == 0) break;
        const pick = moves[choices[ply] % n];
        played[ply] = pick;
        position.doMoveState(&p, pick, &chain[ply]);
    }
    while (ply > 0) {
        ply -= 1;
        position.undoMove(&p, played[ply]);
    }
    if (positionKey(&p) != key0) return error.KeyDesyncAfterUnwind;
}

test "fuzz: make/unmake restores the zobrist key over a deep line" {
    position.initRuntime();
    try std.testing.fuzz({}, fuzzKeyStability, .{});
}

// Property: from a fuzzer-reached position, EVERY legal move must restore the key on
// undo -- not just the first. This exercises each move category (captures, castling,
// en passant, promotions, double-push) at one board, so a category-specific
// incremental-hash bug cannot hide behind a quiet leading move.
fn fuzzAllMovesKeyStability(_: void, smith: *std.testing.Smith) anyerror!void {
    var choices: [24]u8 = undefined;
    smith.bytesWithHash(&choices, 3);

    var p: position.Position align(64) = undefined;
    var st: position.StateInfo align(16) = undefined;
    if (position.setPosition(&p, start_fen, start_fen.len, 0, &st, position_size, state_info_size)) |msg| {
        std.heap.c_allocator.free(std.mem.span(msg));
        return;
    }
    // Diversify the starting board with a shallow random line.
    var chain: [choices.len]position.StateInfo align(16) = undefined;
    var played: [choices.len]u16 = undefined;
    var ply: usize = 0;
    while (ply < choices.len) : (ply += 1) {
        var moves: [256]u16 = undefined;
        const n = movegen.generateLegal(&p, &moves);
        if (n == 0) break;
        const pick = moves[choices[ply] % n];
        played[ply] = pick;
        position.doMoveState(&p, pick, &chain[ply]);
    }

    // Every legal move at the reached board must round-trip the key on undo.
    const key = positionKey(&p);
    var moves: [256]u16 = undefined;
    const n = movegen.generateLegal(&p, &moves);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        var mst: position.StateInfo align(16) = undefined;
        position.doMoveState(&p, moves[i], &mst);
        position.undoMove(&p, moves[i]);
        if (positionKey(&p) != key) return error.KeyDesyncAfterMove;
    }

    while (ply > 0) {
        ply -= 1;
        position.undoMove(&p, played[ply]);
    }
}

test "fuzz: every legal move restores the zobrist key on undo" {
    position.initRuntime();
    try std.testing.fuzz({}, fuzzAllMovesKeyStability, .{});
}

// Property: at any fuzzer-reached position, the legal-move list is WELL-FORMED --
// every move has from != to (no null move leaks into the list) and no move is
// duplicated. A movegen bug (a stale mask, a double-emitted promotion) shows up here
// even when make/unmake and the key are all fine.
fn fuzzLegalMoveWellFormedness(_: void, smith: *std.testing.Smith) anyerror!void {
    var choices: [24]u8 = undefined;
    smith.bytesWithHash(&choices, 3);

    var p: position.Position align(64) = undefined;
    var st: position.StateInfo align(16) = undefined;
    if (position.setPosition(&p, start_fen, start_fen.len, 0, &st, position_size, state_info_size)) |msg| {
        std.heap.c_allocator.free(std.mem.span(msg));
        return;
    }
    var chain: [choices.len]position.StateInfo align(16) = undefined;
    var played: [choices.len]u16 = undefined;
    var ply: usize = 0;
    while (ply < choices.len) : (ply += 1) {
        var moves: [256]u16 = undefined;
        const n = movegen.generateLegal(&p, &moves);
        if (n == 0) break;
        const pick = moves[choices[ply] % n];
        played[ply] = pick;
        position.doMoveState(&p, pick, &chain[ply]);
    }

    var moves: [256]u16 = undefined;
    const n = movegen.generateLegal(&p, &moves);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const from: u16 = (moves[i] >> 6) & 0x3F;
        const to: u16 = moves[i] & 0x3F;
        if (from == to) return error.NullMoveInLegalList;
        var j: usize = i + 1;
        while (j < n) : (j += 1) {
            if (moves[j] == moves[i]) return error.DuplicateLegalMove;
        }
    }

    while (ply > 0) {
        ply -= 1;
        position.undoMove(&p, played[ply]);
    }
}

test "fuzz: the legal-move list is well-formed (no null / no duplicates)" {
    position.initRuntime();
    try std.testing.fuzz({}, fuzzLegalMoveWellFormedness, .{});
}

// Property: making then immediately unmaking EACH legal move leaves the legal-move
// COUNT unchanged. This is a coarser but broader corruption detector than the key
// check -- it catches a doMove/undoMove that restores the zobrist key but leaves a
// board field (occupancy, castling, ep) subtly wrong, since the very next generateLegal
// would then produce a different number of moves.
fn fuzzMoveCountStability(_: void, smith: *std.testing.Smith) anyerror!void {
    var choices: [24]u8 = undefined;
    smith.bytesWithHash(&choices, 3);

    var p: position.Position align(64) = undefined;
    var st: position.StateInfo align(16) = undefined;
    if (position.setPosition(&p, start_fen, start_fen.len, 0, &st, position_size, state_info_size)) |msg| {
        std.heap.c_allocator.free(std.mem.span(msg));
        return;
    }
    var chain: [choices.len]position.StateInfo align(16) = undefined;
    var played: [choices.len]u16 = undefined;
    var ply: usize = 0;
    while (ply < choices.len) : (ply += 1) {
        var moves: [256]u16 = undefined;
        const n = movegen.generateLegal(&p, &moves);
        if (n == 0) break;
        const pick = moves[choices[ply] % n];
        played[ply] = pick;
        position.doMoveState(&p, pick, &chain[ply]);
    }

    var moves: [256]u16 = undefined;
    const before = movegen.generateLegal(&p, &moves);
    var i: usize = 0;
    while (i < before) : (i += 1) {
        var mst: position.StateInfo align(16) = undefined;
        position.doMoveState(&p, moves[i], &mst);
        position.undoMove(&p, moves[i]);
    }
    var moves_after: [256]u16 = undefined;
    if (movegen.generateLegal(&p, &moves_after) != before) return error.MoveCountChangedAfterMakeUnmake;

    while (ply > 0) {
        ply -= 1;
        position.undoMove(&p, played[ply]);
    }
}

test "fuzz: make/unmake of every move preserves the legal-move count" {
    position.initRuntime();
    try std.testing.fuzz({}, fuzzMoveCountStability, .{});
}
