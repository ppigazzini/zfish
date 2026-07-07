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

const position_size = graph_layout.position_size;
const state_info_size = graph_layout.state_info_size;

// Property: setPosition must never crash / OOB on arbitrary input -- it rejects it
// or produces a self-consistent position, and any position it accepts must survive
// generateLegal + one make/unmake. The coverage-guided fuzzer explores toward
// inputs that pass more of the parser than random bytes would reach.
fn fuzzSetPosition(_: void, smith: *std.testing.Smith) anyerror!void {
    var raw: [129]u8 = undefined;
    smith.bytesWithHash(&raw, 1);
    const len = @as(usize, raw[0]) % (raw.len - 1); // 0..127, drawn from the input
    const fen = raw[1..][0..len];

    var p: [position_size]u8 align(64) = undefined;
    var st: [state_info_size]u8 align(16) = undefined;
    const err = position.setPosition(&p, fen.ptr, fen.len, 0, &st, position_size, state_info_size);
    if (err) |msg| {
        std.heap.c_allocator.free(std.mem.span(msg));
        return; // rejected -- fine
    }
    var moves: [256]u16 = undefined;
    const n = movegen.generateLegal(&p, &moves);
    if (n > 0) {
        var new_st: [state_info_size]u8 align(16) = undefined;
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

    var p: [position_size]u8 align(64) = undefined;
    var st: [state_info_size]u8 align(16) = undefined;
    if (position.setPosition(&p, start_fen, start_fen.len, 0, &st, position_size, state_info_size)) |msg| {
        std.heap.c_allocator.free(std.mem.span(msg));
        return; // start position is always legal, but stay defensive
    }

    var chain: [choices.len][state_info_size]u8 align(16) = undefined;
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
