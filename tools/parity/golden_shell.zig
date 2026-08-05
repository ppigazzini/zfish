//! Build the goldens that pin what the SHELL prints: the bench info lines, the driver's
//! emit callbacks, a completed bestmove per search mode, the FEN refusals, `d`/`flip`, the
//! `uci` option list, and the `export_net` serializer.
//!
//! Each builder returns an owned fingerprint the root diffs against a committed golden; none
//! of them decides pass or fail. A gate that pins a stream should PIN it -- `buildUciOptions`
//! asserts the handshake on stdout AND asserts stderr is clean, because reading the wrong
//! stream is how a whole broken handshake passed for months.

const std = @import("std");
const Io = std.Io;
const run = @import("run.zig");
const session = @import("session.zig");
const structured_diff = @import("structured_diff.zig");

const runEngine = run.runEngine;
const lines = run.lines;
const startsWith = run.startsWith;
const startsWithIgnoreCase = run.startsWithIgnoreCase;
const removeField = run.removeField;
const trimCR = run.trimCR;
const isDivideLine = run.isDivideLine;
const fail = run.fail;
const Interactive = session.Interactive;
const InfoLine = structured_diff.InfoLine;
const BestmoveLine = structured_diff.BestmoveLine;
const parseInfoLine = structured_diff.parseInfoLine;
const parseBestmove = structured_diff.parseBestmove;

// output-golden: capture the bench info/bestmove lines with volatile `time`/`nps` stripped.
pub fn buildOutputGolden(gpa: std.mem.Allocator, io: Io, bin: []const u8) ![]u8 {
    var cap = try runEngine(gpa, io, bin, &.{"bench"}, null);
    defer cap.deinit(gpa);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var li = lines(cap.stdout);
    while (li.next()) |line| {
        if (!(startsWith(line, "info depth") or startsWith(line, "bestmove"))) continue;
        const no_time = try removeField(gpa, line, " time ");
        defer gpa.free(no_time);
        const no_nps = try removeField(gpa, no_time, " nps ");
        defer gpa.free(no_nps);
        try out.appendSlice(gpa, no_nps);
        try out.append(gpa, '\n');
    }
    if (out.items.len == 0) fail("output-golden: binary produced no info output (crash?)", .{});
    return out.toOwnedSlice(gpa);
}

// driver-golden: pin the observable behaviour of the search-manager DRIVER + its emit
// callbacks (ss_emit_pv / emit_bestmove / emit_no_moves / search_emit_info_full /
// search_cb_pv_context / search_cb_root_on_iter / search_id_pv / ss_pv_one_and_ponder).
// Run a single-thread (deterministic) battery that exercises MultiPV (multi-line info +
// pv_context), UCI_ShowWDL (wdl formatting), a deep endgame (currmove / currmovenumber),
// a mate score, and a checkmated side-to-move ("bestmove (none)"). Capture every emitted
// info/bestmove line (volatile `time`/`nps` stripped). Purpose: de-risk relocating
// those callbacks off main.zig -- a driver refactor that changes ANY emitted line is caught
// bit-exact, so the moves need not be "trusted", they are gate-proven.
const driver_battery =
    "uci\n" ++
    "setoption name Threads value 1\n" ++
    "setoption name MultiPV value 3\n" ++
    "setoption name UCI_ShowWDL value true\n" ++
    "position startpos\n" ++
    "go depth 12\n" ++
    "position fen r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1\n" ++
    "go depth 11\n" ++
    "setoption name MultiPV value 1\n" ++
    "setoption name UCI_ShowWDL value false\n" ++
    "position fen 8/8/8/8/8/6k1/6p1/6K1 w - - 0 1\n" ++
    "go depth 24\n" ++
    // NOTE: deliberately do NOT pin the currmove emit callback (searchCbRootOnIter, gated at
    // `nodes > 10_000_000` in search_back.zig) here. Triggering it needs a >10M-node
    // search, which -- node-limited -- is cut off mid-iteration at ~depth 50; that boundary
    // tail is NOT bit-exact across build modes (ReleaseFast vs ReleaseSafe diverged in CI),
    // unlike the depth-limited searches above, which are bit-exact like `bench`. A robust
    // currmove golden would need a >10M-node DEPTH-limited search (deep + slow + a huge
    // currmove list), not worth its fragility for a cosmetic progress line; left uncovered.
    "position fen rnb1kbnr/pppp1ppp/8/4p3/6Pq/5P2/PPPPP2P/RNBQKBNR w KQkq - 1 3\n" ++
    "go depth 5\n" ++
    "quit\n";

pub fn buildDriverGolden(gpa: std.mem.Allocator, io: Io, bin: []const u8) ![]u8 {
    var cap = try runEngine(gpa, io, bin, &.{}, driver_battery);
    defer cap.deinit(gpa);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var li = lines(cap.stdout);
    while (li.next()) |line| {
        if (!(startsWith(line, "info depth") or startsWith(line, "info currmove") or
            startsWith(line, "bestmove"))) continue;
        const no_time = try removeField(gpa, line, " time ");
        defer gpa.free(no_time);
        const no_nps = try removeField(gpa, no_time, " nps ");
        defer gpa.free(no_nps);
        try out.appendSlice(gpa, no_nps);
        try out.append(gpa, '\n');
    }
    if (out.items.len == 0) fail("driver-golden: binary produced no info output (crash?)", .{});
    return out.toOwnedSlice(gpa);
}

// search-modes: produce one bestmove per deterministic node/depth-limited mode.
pub fn buildSearchModes(gpa: std.mem.Allocator, io: Io, bin: []const u8) ![]u8 {
    const sp = "position startpos";
    const kiwi = "position fen r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 10";
    const end = "position fen 8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1";
    const rows = [_]struct { label: []const u8, seq: []const u8 }{
        .{ .label = "nodes-startpos     ", .seq = sp ++ "\ngo nodes 300000" },
        .{ .label = "nodes-kiwipete     ", .seq = kiwi ++ "\ngo nodes 300000" },
        .{ .label = "nodes-endgame      ", .seq = end ++ "\ngo nodes 500000" },
        .{ .label = "depth-searchmoves  ", .seq = sp ++ "\ngo depth 14 searchmoves d2d4 g1f3" },
        .{ .label = "multipv3-startpos  ", .seq = "setoption name MultiPV value 3\n" ++ sp ++ "\ngo depth 12" },
        .{ .label = "multipv4-kiwipete  ", .seq = "setoption name MultiPV value 4\n" ++ kiwi ++ "\ngo depth 11" },
    };
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (rows) |r| {
        const bm = try searchBestmoveLine(gpa, io, bin, r.seq);
        defer gpa.free(bm);
        if (bm.len == 0) fail("search-modes: a test produced no bestmove (engine crashed?)", .{});
        try out.print(gpa, "{s}{s}\n", .{ r.label, bm });
    }
    return out.toOwnedSlice(gpa);
}

// Run a search to its REAL bestmove (interactive; no early-quit truncation) and return the
// full `bestmove ...` line (owned). Avoid the old approach that piped `go\nquit`, which stops
// the search mid-flight -- the resulting move is timing-dependent (a hollow, cross-platform-flaky
// gate). Rely on these deterministic node/depth-limited single-thread modes, so the completed
// bestmove is a stable golden on every OS/arch.
fn searchBestmoveLine(gpa: std.mem.Allocator, io: Io, bin: []const u8, seq: []const u8) ![]u8 {
    var s: Interactive = undefined;
    try s.init(io, gpa, bin);
    s.send(seq);
    s.send("\n");
    _ = s.fillUntil("\nbestmove");
    const buf = s.buffered();
    var result: []const u8 = "";
    if (std.mem.findLast(u8, buf, "\nbestmove")) |pos| {
        const start = pos + 1;
        const nl = std.mem.findScalarPos(u8, buf, start, '\n') orelse buf.len;
        result = trimCR(buf[start..nl]);
    }
    const owned = try gpa.dupe(u8, result);
    _ = s.finish();
    return owned;
}

// fen-errors: pin the FEN-validation diagnostics restored in fen_parse.zig (the piece-char,
// pawn/piece-count, side-to-move, castling, en-passant, king-count, and board-length rules that
// upstream enforces at position.cpp). Each malformed `position fen` is a CRITICAL command error
// that ABORTS the engine, so every case runs in its own process and the follow-up `isready`
// must produce NO `readyok` -- that flag pins the terminate-on-critical-error behaviour. The
// `Reason: ...` text, its quoted offending token, and the stdout routing all match the upstream
// oracle byte-for-byte (verified against sf_sse41); regenerate the golden on an upstream sync,
// exactly like the search/tb goldens.
const FenErrorCase = struct { label: []const u8, fen: []const u8 };
const fen_error_cases = [_]FenErrorCase{
    .{ .label = "invalid-piece   ", .fen = "not_a_fen" },
    .{ .label = "too-many-pawns  ", .fen = "8/pppppppp/p7/8/8/8/8/K6k w - - 0 1" },
    .{ .label = "too-many-pieces ", .fen = "QQQQQQQQ/QQQQQQQQ/8/8/8/8/8/K6k w - - 0 1" },
    .{ .label = "bad-side-to-move", .fen = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR x KQkq - 0 1" },
    .{ .label = "bad-castling    ", .fen = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w XQkq - 0 1" },
    .{ .label = "bad-en-passant  ", .fen = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq z9 0 1" },
    .{ .label = "no-kings        ", .fen = "8/8/8/8/8/8/8/8 w - - 0 1" },
    .{ .label = "short-board     ", .fen = "rnbqkbnr/pppppppp/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1" },
};

pub fn buildFenErrors(gpa: std.mem.Allocator, io: Io, bin: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (fen_error_cases) |c| {
        const stdin_bytes = try std.fmt.allocPrint(gpa, "position fen {s}\nisready\nquit\n", .{c.fen});
        defer gpa.free(stdin_bytes);
        var cap = try runEngine(gpa, io, bin, &.{}, stdin_bytes);
        defer cap.deinit(gpa);
        var reason: []const u8 = "";
        var readyok = false;
        var li = lines(cap.stdout);
        while (li.next()) |line| {
            if (std.mem.find(u8, line, "CRITICAL ERROR:") != null) {
                if (std.mem.find(u8, line, "Reason: ")) |r| reason = line[r + "Reason: ".len ..];
            } else if (startsWith(line, "readyok")) readyok = true;
        }
        if (reason.len == 0) fail("fen-errors: {s}: no CRITICAL ERROR line on stdout (crash?)", .{c.label});
        // terminated == the engine aborted before reaching `isready` (no readyok leaked).
        try out.print(gpa, "{s} terminated={} {s}\n", .{ c.label, !readyok, reason });
    }
    return out.toOwnedSlice(gpa);
}

// misc: capture the `d`-command BOARD plus its Fen/Key/Checkers triple (on stdout), per
// sequence.
//
// The board rows are here because nothing else reads them. `d` renders each square through
// `trace.zig`'s own copy of the piece->character table -- a third copy of the same bijection
// `fen.zig` writes FENs with and `fen_parse.zig` parses them with. The other two are held:
// mutating `fen.zig`'s copy reddens `flip-chess960`, because that gate round-trips the
// writer's output back through the parser. `trace.zig`'s copy had no such reader -- this
// gate captured Fen/Key/Checkers and filtered the diagram out, so changing its last
// character to 'x' left every gate in the tree green while the `d` command printed a board
// with no black king on it. Checked, not assumed: that mutation passed `misc` before this
// change.
pub fn buildMisc(gpa: std.mem.Allocator, io: Io, bin: []const u8) ![]u8 {
    const sp = "position startpos";
    const kiwi = "position fen r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1";
    const chk = "position fen rnb1kbnr/pppp1ppp/8/4p3/6Pq/5P2/PPPPP2P/RNBQKBNR w KQkq - 1 3";
    const runs = [_]struct { label: []const u8, seq: []const u8 }{
        .{ .label = "== startpos d ==", .seq = sp ++ "\nd" },
        .{ .label = "== startpos flip d ==", .seq = sp ++ "\nflip\nd" },
        .{ .label = "== kiwipete d ==", .seq = kiwi ++ "\nd" },
        .{ .label = "== kiwipete flip d ==", .seq = kiwi ++ "\nflip\nd" },
        .{ .label = "== in-check d ==", .seq = chk ++ "\nd" },
    };
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var keys: usize = 0;
    for (runs) |r| {
        try out.print(gpa, "{s}\n", .{r.label});
        const input = try std.fmt.allocPrint(gpa, "{s}\nquit\n", .{r.seq});
        defer gpa.free(input);
        var cap = try runEngine(gpa, io, bin, &.{}, input);
        defer cap.deinit(gpa);
        var li = lines(cap.stdout);
        var rows: usize = 0;
        while (li.next()) |line| {
            // The board rows and the rule between them both start with a space; the file/rank
            // legend is the trailing "   a   b   ...". Take every line the diagram is made of.
            const is_board = startsWith(line, " +---+") or startsWith(line, " | ") or startsWith(line, "   a   b");
            if (is_board) rows += 1;
            if (is_board or startsWithIgnoreCase(line, "Fen:") or startsWithIgnoreCase(line, "Key:") or startsWithIgnoreCase(line, "Checkers:")) {
                try out.appendSlice(gpa, line);
                try out.append(gpa, '\n');
                if (startsWith(line, "Key:")) keys += 1;
            }
        }
        // 9 rules + 8 rank rows + 1 legend. A filter that stops matching would silently
        // shrink the subject back to what it was, and a shrunk subject reports OK.
        if (rows != 18) fail("misc: {s}: captured {d} board lines, expected 18", .{ r.label, rows });
    }
    if (keys != 5) fail("misc: expected 5 Key lines, got {d} (crash?)", .{keys});
    return out.toOwnedSlice(gpa);
}

// uci-options: capture the `uci` handshake option list -- the compatibility surface a GUI reads.
// The `uci` handshake is protocol: it MUST reach the GUI on stdout. Read it from stdout
// and assert stderr carries none of it -- this gate previously read stderr, which is where
// a std.debug.print bug was putting the whole handshake, so the gate passed while a
// conforming GUI (which reads stdout) got nothing and hung. Pinning the stream is the
// contract; a regression to stderr must fail here, not in a GUI.
//
// The id name / id author lines and the startup banner carry the git sha + date (misc.zig)
// and are volatile every commit, so pin ONLY the `option name` lines. Their defaults and
// min/max are static constants -> machine/OS-invariant (Threads max is a fixed 1024, not the
// core count; Hash max is fixed), except EvalFile's default which is the net name
// (regenerate on a net bump, like the other goldens). Complement the option-model unit test
// (option_model.zig) by covering the command -> rendered-output wiring end to end.
pub fn buildUciOptions(gpa: std.mem.Allocator, io: Io, bin: []const u8) ![]u8 {
    var cap = try runEngine(gpa, io, bin, &.{}, "uci\nquit\n");
    defer cap.deinit(gpa);

    // Pin the stream, not just the content: uciok and the option list belong on stdout.
    var eli = lines(cap.stderr);
    while (eli.next()) |line| {
        if (startsWith(line, "option name ") or std.mem.eql(u8, line, "uciok"))
            fail("uci-options: handshake line on STDERR, must be stdout: '{s}'", .{line});
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var n: usize = 0;
    var li = lines(cap.stdout);
    while (li.next()) |line| {
        if (startsWith(line, "option name ")) {
            try out.appendSlice(gpa, line);
            try out.append(gpa, '\n');
            n += 1;
        }
    }
    if (n == 0) fail("uci-options: no 'option name' lines (uci handshake changed / wrong stream?)", .{});
    return out.toOwnedSlice(gpa);
}

// Hash with FNV-1a 64-bit -- a dependency-free content hash for the ~90 MB exported net (shipping
// the net as a golden would be absurd; a 64-bit hash + exact length pins any change).
fn fnv1a64(data: []const u8) u64 {
    var h: u64 = 0xcbf29ce484222325;
    for (data) |b| {
        h ^= b;
        h *%= 0x100000001b3;
    }
    return h;
}

// export-net: fingerprint (length + FNV-1a) the net produced by `export_net`. Require the
// serializer (nnue_parse.serializeFeatureTransformer/serializeLayer, i.e. Stockfish's
// write_parameters) to reproduce the canonical .nnue byte-for-byte -- upstream's
// export round-trips to the input net exactly, so this gate is a differential-vs-upstream
// check authored against the pristine oracle (see tools/upstream_parity.sh): a matching
// hash means zfish's export == upstream's export == the distributed net. `export_net` is
// synchronous (it runs to completion in the command handler, no async search), so the
// feed-all-then-quit runEngine path is safe here. Write a temp net in cwd (resources/), hash
// it, and remove it.
pub fn buildExportNet(gpa: std.mem.Allocator, io: Io, bin: []const u8) ![]u8 {
    const tmp = "parity_export.tmp.nnue";
    var cap = try runEngine(gpa, io, bin, &.{}, "export_net " ++ tmp ++ "\nquit\n");
    cap.deinit(gpa);

    const bytes = Io.Dir.cwd().readFileAlloc(io, tmp, gpa, .unlimited) catch
        fail("export-net: engine wrote no {s} (export_net failed / panicked?)", .{tmp});
    defer gpa.free(bytes);
    Io.Dir.cwd().deleteFile(io, tmp) catch {};
    if (bytes.len == 0) fail("export-net: exported net is empty (export_net failed?)", .{});

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.print(gpa, "export_net len={d} fnv1a={x:0>16}\n", .{ bytes.len, fnv1a64(bytes) });
    return out.toOwnedSlice(gpa);
}
