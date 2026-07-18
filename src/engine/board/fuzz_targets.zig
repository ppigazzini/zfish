// Define the coverage-guided fuzz targets.
//
// Provide real std.testing.fuzz targets driven by the Zig fuzzer's Smith input model, kept
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
const worker_layout = @import("worker_layout");
const position_snapshot = @import("position_snapshot");
const network = @import("network");
const nnue_acc = @import("nnue_accumulator");
const headless_search = @import("headless_search");

const position_size = worker_layout.position_size;
const state_info_size = worker_layout.state_info_size;

// Return the stored (incremental) zobrist key of the current position -- fillSnapshot copies
// `st.key`, the value doMove maintains, NOT a recomputed one, so comparing it across a
// make/unmake round-trip is a genuine incremental-hash correctness check.
fn positionKey(p: *const position.Position) u64 {
    var snap: position_snapshot.PositionSnapshot = undefined;
    position.fillSnapshot(p, &snap);
    return snap.key;
}

// Assert setPosition never crashes / OOBs on arbitrary input -- it rejects it
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

// Assert that playing a deep sequence of legal moves (each picked from the current
// legal list by a fuzzer byte) then unwinding it never crashes. This stresses
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

// Assert a deep line of legal moves, fully unwound, restores the incremental
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

// Assert that from a fuzzer-reached position, EVERY legal move restores the key on
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

    // Require every legal move at the reached board to round-trip the key on undo.
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

// Assert that at any fuzzer-reached position, the legal-move list is WELL-FORMED --
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

// Assert that making then immediately unmaking EACH legal move leaves the legal-move
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

// Exercise the whole eval crown jewel via the NNUE forward pass, which the board fuzz above
// never reaches: feature extraction from the position, a full accumulator refresh, the
// feature-transformer + fully-connected layers, and the psqt/positional bucket blend. The
// accumulator stack + refresh cache are opaque byte blocks (sized by worker_layout), reused
// across iterations (single-threaded fuzz) exactly like the eval-trace command's static
// arenas. Built under ReleaseSafe so an OOB feature index, a mis-aligned FT read, or an
// overflow in the accumulation trips a Zig safety check instead of reading garbage.
var eval_stack_buf: [worker_layout.accumulator_stack_size]u8 align(64) = undefined;
var eval_caches_buf: [worker_layout.accumulator_caches_size]u8 align(64) = undefined;

// Load the on-disk net once into the module-global weight storage (there is no embedded
// net in the Zig port). `network.load` scans cwd + the given root dir; the fuzz artifact
// runs from the repo root, so "net/" reaches net/nn-<default>.nnue (and the parity harness's
// cwd is net/ itself, which the "" scan covers). Return false when the net is absent so the
// body no-ops instead of dereferencing a null FT -- the target is then a vacuous pass rather
// than a spurious failure in an environment without the weights.
fn ensureNetLoaded() bool {
    if (network.ftPtr() != null) return true;
    const dir = "net/";
    network.load(dir, dir.len, "", 0);
    return network.ftPtr() != null;
}

// Assert the NNUE evaluation of ANY fuzzer-reached legal position completes without UB and
// returns a finite score. The reached board is arbitrary (a legal line from the start), so
// this steers the feature/accumulator code through positions the fixed golden `eval` test
// never sees (lopsided material, many promotions, deep pawn structures). The bound is a gross
// tripwire: a correct internal eval is in the hundreds (kiwipete = -427; startpos = +10), so
// 1<<22 cannot false-positive on a legal board yet still catches pointer-garbage / overflow.
fn fuzzNnueEval(_: void, smith: *std.testing.Smith) anyerror!void {
    if (!ensureNetLoaded()) return; // no weights available -- nothing to fuzz

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

    // Start from a fresh stack + cache so the first evaluate does a FULL accumulator refresh from the
    // reached position (the incremental doMove-driven update path is search-driven, exercised
    // by the shallow-search target once that lands).
    const stack: *nnue_acc.AccumulatorStack = @ptrCast(&eval_stack_buf);
    @memset(eval_stack_buf[0..], 0);
    nnue_acc.stackReset(stack);
    const cache: *nnue_acc.RefreshCache = @ptrCast(&eval_caches_buf);
    const biases: [*]const i16 = @ptrCast(@alignCast(network.ftPtr().?));
    nnue_acc.clearRefreshCache(cache, biases);

    const out = network.evaluate(&p, stack, cache);
    const limit: i32 = 1 << 22;
    if (out.psqt > limit or out.psqt < -limit) return error.NnuePsqtOutOfRange;
    if (out.positional > limit or out.positional < -limit) return error.NnuePositionalOutOfRange;

    while (ply > 0) {
        ply -= 1;
        position.undoMove(&p, played[ply]);
    }
}

test "fuzz: NNUE eval of reached positions is finite and crash-free" {
    position.initRuntime();
    try std.testing.fuzz({}, fuzzNnueEval, .{});
}

// Run the deepest crown-jewel target: a shallow SEARCH on a fuzzer-reached position. This
// drives the whole engine-zone search tree headless -- move ordering, the transposition
// table, pruning/reduction, qsearch, the incremental accumulator push/pop, and the eval
// -- via the headless_search helper (no platform thread pool). Built under ReleaseSafe so
// any OOB / overflow / null-deref anywhere in that tree trips a safety check. A correct
// search must return a move that is LEGAL at the reached root and a finite score.
fn fuzzShallowSearch(_: void, smith: *std.testing.Smith) anyerror!void {
    if (!ensureNetLoaded()) return; // no weights -> nothing to search

    var choices: [16]u8 = undefined;
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
        const cnt = movegen.generateLegal(&p, &moves);
        if (cnt == 0) break;
        const pick = moves[choices[ply] % cnt];
        played[ply] = pick;
        position.doMoveState(&p, pick, &chain[ply]);
    }

    // Search the reached position headless (depth 1..3 from a fuzzer byte -- shallow keeps
    // iterations fast while still entering the full search recursion + qsearch). searchPosition
    // copies the board, so `p` is untouched and stays valid for the legality check below.
    const depth: i32 = @as(i32, choices[0] % 3) + 1;
    const maybe = headless_search.searchPosition(&p, 0, depth);

    // Check the best move is legal at the reached root; capture before unwinding `p`.
    var search_err: ?anyerror = null;
    if (maybe) |res| {
        var moves2: [256]u16 = undefined;
        const cnt2 = movegen.generateLegal(&p, &moves2);
        var legal_best = false;
        for (moves2[0..cnt2]) |m| {
            if (m == res.best_move) legal_best = true;
        }
        if (!legal_best) search_err = error.SearchMoveNotLegalAtRoot;
        if (res.score <= -32000 or res.score >= 32000) search_err = error.SearchScoreOutOfRange;
        if (res.nodes == 0) search_err = error.SearchVisitedNoNodes;
    }

    while (ply > 0) {
        ply -= 1;
        position.undoMove(&p, played[ply]);
    }
    if (search_err) |e| return e;
}

test "fuzz: shallow headless search on reached positions is legal + finite" {
    position.initRuntime();
    try std.testing.fuzz({}, fuzzShallowSearch, .{});
}
