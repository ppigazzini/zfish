// Pure-Zig parity harness: the cross-platform replacement for the bash
// golden-diff scripts (output_parity_golden.sh / search_parity.sh / search_modes.sh /
// perft.sh / eval.sh / misc.sh). It drives the built stockfish binary over UCI, extracts
// the same deterministic fingerprints those scripts did, and diffs them against the same
// committed .golden files -- but with zero shell/coreutils dependency, so `zig build parity`
// runs identically on Linux, Windows, and macOS (the bash scripts relied on POSIX sh, GNU
// vs BSD sed/grep/sort, and process substitution, none of which hold across the three).
//
// Contract (matches the bash scripts, invoked by build.zig):
//   parity_harness <check> <stockfish-bin> <golden-path> [check|update]   (cwd = net/)
//     check  (default): rebuild the live fingerprint, diff vs the golden, exit 1 on drift.
//     update:           (re)write the golden from the live run.
//   parity_harness signature <stockfish-bin> <expected-nodes>
//     run bench and assert `Nodes searched` == expected (the 2466447 arch/OS invariant).
// Exit codes mirror the scripts: 0 pass, 1 golden mismatch, 2 crash / parse failure / usage.
//
// Stream routing (empirically verified, identical on every OS because the engine's print
// paths are the same): the interactive `d`/`go perft`/`go`/bestmove lines go to STDOUT; the
// bench `Position:`/`Nodes searched` banners and the `eval` NNUE trace go to STDERR. Each
// check captures both streams separately and reads the one(s) it needs, so no fragile
// stderr->stdout merge (bash `2>&1`) is reconstructed.

const std = @import("std");
const Io = std.Io;

const max_golden = 4 * 1024 * 1024;

const Captured = struct {
    stdout: []u8,
    stderr: []u8,
    fn deinit(self: Captured, gpa: std.mem.Allocator) void {
        gpa.free(self.stdout);
        gpa.free(self.stderr);
    }
};

// Spawn the engine, optionally feed it a UCI script on stdin, and capture stdout+stderr
// (CR-stripped so Windows text-mode CRLF matches the LF goldens). Mirrors std.process.run's
// deadlock-free MultiReader drain, adding the stdin write run() lacks.
fn runEngine(
    gpa: std.mem.Allocator,
    io: Io,
    bin: []const u8,
    extra_argv: []const []const u8,
    stdin_bytes: ?[]const u8,
) !Captured {
    var argv = try gpa.alloc([]const u8, 1 + extra_argv.len);
    defer gpa.free(argv);
    argv[0] = bin;
    for (extra_argv, 0..) |a, i| argv[i + 1] = a;

    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = if (stdin_bytes != null) .pipe else .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    defer child.kill(io);

    if (stdin_bytes) |bytes| {
        var wbuf: [4096]u8 = undefined;
        var fw = child.stdin.?.writer(io, &wbuf);
        try fw.interface.writeAll(bytes);
        try fw.interface.flush();
        child.stdin.?.close(io);
        child.stdin = null;
    }

    var mr_buffer: Io.File.MultiReader.Buffer(2) = undefined;
    var mr: Io.File.MultiReader = undefined;
    mr.init(gpa, io, mr_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer mr.deinit();
    while (mr.fill(64, .none)) |_| {} else |err| switch (err) {
        error.EndOfStream => {},
        else => |e| return e,
    }
    try mr.checkAnyError();
    _ = try child.wait(io);

    const raw_out = try mr.toOwnedSlice(0);
    defer gpa.free(raw_out);
    const raw_err = try mr.toOwnedSlice(1);
    defer gpa.free(raw_err);

    return .{ .stdout = try stripCR(gpa, raw_out), .stderr = try stripCR(gpa, raw_err) };
}

fn stripCR(gpa: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (bytes) |ch| if (ch != '\r') try out.append(gpa, ch);
    return out.toOwnedSlice(gpa);
}

// ---- small text helpers (POSIX-tool replacements) ---------------------------

const LineIter = struct {
    it: std.mem.SplitIterator(u8, .scalar),
    fn next(self: *LineIter) ?[]const u8 {
        while (self.it.next()) |l| {
            // splitScalar yields a trailing empty slice after the final '\n'; skip it so
            // callers see only real lines (bash pipelines never see that phantom line).
            if (self.it.index == null and l.len == 0) return null;
            return l;
        }
        return null;
    }
};
fn lines(text: []const u8) LineIter {
    return .{ .it = std.mem.splitScalar(u8, text, '\n') };
}

fn startsWith(line: []const u8, prefix: []const u8) bool {
    return std.mem.startsWith(u8, line, prefix);
}

fn startsWithIgnoreCase(line: []const u8, prefix: []const u8) bool {
    if (line.len < prefix.len) return false;
    return std.ascii.eqlIgnoreCase(line[0..prefix.len], prefix);
}

// Remove the first " <field> <digits>" run from a line (sed 's/ field [0-9]+//').
fn removeField(gpa: std.mem.Allocator, line: []const u8, field: []const u8) ![]u8 {
    const idx = std.mem.indexOf(u8, line, field) orelse return gpa.dupe(u8, line);
    var end = idx + field.len;
    while (end < line.len and std.ascii.isDigit(line[end])) end += 1;
    if (end == idx + field.len) return gpa.dupe(u8, line); // no digits -> not the field
    var out = try gpa.alloc(u8, line.len - (end - idx));
    @memcpy(out[0..idx], line[0..idx]);
    @memcpy(out[idx..], line[end..]);
    return out;
}

// ---- per-check fingerprint builders -----------------------------------------

// output-golden: bench info/bestmove lines with volatile `time`/`nps` stripped.
fn buildOutputGolden(gpa: std.mem.Allocator, io: Io, bin: []const u8) ![]u8 {
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

// driver-golden: pins the observable behaviour of the search-manager DRIVER + its emit
// callbacks (ss_emit_pv / emit_bestmove / emit_no_moves / search_emit_info_full /
// search_cb_pv_context / search_cb_root_on_iter / search_id_pv / ss_pv_one_and_ponder).
// A single-thread (deterministic) battery that exercises MultiPV (multi-line info +
// pv_context), UCI_ShowWDL (wdl formatting), a deep endgame (currmove / currmovenumber),
// a mate score, and a checkmated side-to-move ("bestmove (none)"). Every emitted info/
// bestmove line is captured (volatile `time`/`nps` stripped). Purpose: de-risk relocating
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
    // currmove coverage: searchCbRootOnIter (the "info depth D currmove M
    // currmovenumber N" emit callback) only fires on the main thread once the search
    // passes 10M nodes (search_back.zig, `nodes > 10_000_000`). None of the other
    // searches reach that, so the callback was UNCOVERED by every golden. A node-limited
    // search past the threshold exercises it deterministically (single-thread, fixed
    // node budget -> arch/OS-invariant), pinning the currmove format + numbering. It is
    // NOT last: the following checkmate `go` blocks in startThinking's
    // wait-for-search-finished, so this node-limited search runs to completion (a
    // trailing `quit` would stopEngine and truncate it before 10M -- see the batch
    // note in runEngine).
    "position fen 8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1\n" ++
    "go nodes 13000000\n" ++
    "position fen rnb1kbnr/pppp1ppp/8/4p3/6Pq/5P2/PPPPP2P/RNBQKBNR w KQkq - 1 3\n" ++
    "go depth 5\n" ++
    "quit\n";

fn buildDriverGolden(gpa: std.mem.Allocator, io: Io, bin: []const u8) ![]u8 {
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

// search-parity: per-position (depth, score, nodes, bestmove) fingerprint + TOTAL. bench
// info/bestmove are on stdout (51 blocks ending in `bestmove`); `Position:` + `Nodes
// searched` are on stderr. Pair the K-th Position with the K-th stdout block by index.
fn buildSearchParity(gpa: std.mem.Allocator, io: Io, bin: []const u8) ![]u8 {
    var cap = try runEngine(gpa, io, bin, &.{"bench"}, null);
    defer cap.deinit(gpa);

    // stderr: ordered Position fields (the "N/51" token) + the final total.
    var positions: std.ArrayList([]const u8) = .empty;
    defer positions.deinit(gpa);
    var total: ?[]const u8 = null;
    var eli = lines(cap.stderr);
    while (eli.next()) |line| {
        if (startsWith(line, "Position: ")) {
            var toks = std.mem.tokenizeScalar(u8, line, ' ');
            _ = toks.next(); // "Position:"
            if (toks.next()) |p| try positions.append(gpa, p);
        } else if (startsWith(line, "Nodes searched")) {
            var toks = std.mem.tokenizeScalar(u8, line, ' ');
            var last: []const u8 = "";
            while (toks.next()) |t| last = t;
            total = last;
        }
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    // stdout: split into blocks at each `bestmove`, keeping the last `info depth` line.
    var block: usize = 0;
    var last_info: ?[]const u8 = null;
    var sli = lines(cap.stdout);
    while (sli.next()) |line| {
        if (startsWith(line, "info depth")) {
            last_info = line;
        } else if (startsWith(line, "bestmove")) {
            const pos = if (block < positions.items.len) positions.items[block] else "";
            var d: []const u8 = "";
            var nd: []const u8 = "";
            var sc: [32]u8 = undefined;
            var sc_len: usize = 0;
            if (last_info) |info| {
                var t = std.mem.tokenizeScalar(u8, info, ' ');
                var prev: []const u8 = "";
                while (t.next()) |tok| {
                    if (std.mem.eql(u8, prev, "depth")) d = tok;
                    if (std.mem.eql(u8, prev, "nodes")) nd = tok;
                    if (std.mem.eql(u8, prev, "score")) {
                        const kind = tok;
                        const val = t.next() orelse "";
                        if (std.fmt.bufPrint(&sc, "{s} {s}", .{ kind, val })) |printed| {
                            sc_len = printed.len;
                        } else |_| {}
                    }
                    prev = tok;
                }
            }
            var bm_toks = std.mem.tokenizeScalar(u8, line, ' ');
            _ = bm_toks.next(); // "bestmove"
            const bm = bm_toks.next() orelse "";
            try out.print(gpa, "{s:<6} depth={s:<3} score={s:<9} nodes={s:<9} bestmove={s}\n", .{ pos, d, sc[0..sc_len], nd, bm });
            block += 1;
            last_info = null;
        }
    }
    if (total) |t| {
        try out.print(gpa, "TOTAL nodes={s}\n", .{t});
    } else {
        fail("search-parity: could not parse bench output (engine crashed?)", .{});
    }
    return out.toOwnedSlice(gpa);
}

// A labelled position sequence for the multi-run checks.
const Pos = struct { label: []const u8, cmds: []const u8 };

// search-modes: one bestmove per deterministic node/depth-limited mode.
fn buildSearchModes(gpa: std.mem.Allocator, io: Io, bin: []const u8) ![]u8 {
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
// full `bestmove ...` line (owned). The old approach piped `go\nquit`, which stops the search
// mid-flight -- the resulting move is timing-dependent (a hollow, cross-platform-flaky gate).
// These node/depth-limited single-thread modes are deterministic, so the completed bestmove
// is a stable golden on every OS/arch.
fn searchBestmoveLine(gpa: std.mem.Allocator, io: Io, bin: []const u8, seq: []const u8) ![]u8 {
    var s: Interactive = undefined;
    try s.init(io, gpa, bin);
    s.send(seq);
    s.send("\n");
    _ = s.fillUntil("\nbestmove");
    const buf = s.buffered();
    var result: []const u8 = "";
    if (std.mem.lastIndexOf(u8, buf, "\nbestmove")) |pos| {
        const start = pos + 1;
        const nl = std.mem.indexOfScalarPos(u8, buf, start, '\n') orelse buf.len;
        result = trimCR(buf[start..nl]);
    }
    const owned = try gpa.dupe(u8, result);
    _ = s.finish();
    return owned;
}

// perft: `== label ==` header, then SORTED divide lines (byte order == C locale), then the
// `Nodes searched` total, per position. Divide + total are on stdout.
fn buildPerft(gpa: std.mem.Allocator, io: Io, bin: []const u8) ![]u8 {
    const sp = "position startpos";
    const kiwi = "position fen r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1";
    const pos3 = "position fen 8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1";
    const pos4 = "position fen r3k2r/Pppp1ppp/1b3nbN/nP6/BBP1P3/q4N2/Pp1P2PP/R2Q1RK1 w kq - 0 1";
    const pos5 = "position fen rnbq1k1r/pp1Pbppp/2p5/8/2B5/8/PPP1NnPP/RNBQK2R w KQ - 1 8";
    const pos6 = "position fen r4rk1/1pp1qppp/p1np1n2/2b1p1B1/2B1P1b1/P1NP1N2/1PP1QPPP/R4RK1 w - - 0 10";
    const frc = "position fen nrkrbbqn/pppppppp/8/8/8/8/PPPPPPPP/NRKRBBQN w KQkq - 0 1";
    const runs = [_]struct { label: []const u8, seq: []const u8 }{
        .{ .label = "== startpos d5 ==", .seq = sp ++ "\ngo perft 5" },
        .{ .label = "== kiwipete d4 ==", .seq = kiwi ++ "\ngo perft 4" },
        .{ .label = "== pos3 d6 ==", .seq = pos3 ++ "\ngo perft 6" },
        .{ .label = "== pos4 d4 ==", .seq = pos4 ++ "\ngo perft 4" },
        .{ .label = "== pos5 d4 ==", .seq = pos5 ++ "\ngo perft 4" },
        .{ .label = "== pos6 d4 ==", .seq = pos6 ++ "\ngo perft 4" },
        .{ .label = "== frc960 d4 ==", .seq = "setoption name UCI_Chess960 value true\n" ++ frc ++ "\ngo perft 4" },
    };
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var totals: usize = 0;
    for (runs) |r| {
        try out.print(gpa, "{s}\n", .{r.label});
        const input = try std.fmt.allocPrint(gpa, "{s}\nquit\n", .{r.seq});
        defer gpa.free(input);
        var cap = try runEngine(gpa, io, bin, &.{}, input);
        defer cap.deinit(gpa);

        var divides: std.ArrayList([]const u8) = .empty;
        defer divides.deinit(gpa);
        var nodes_line: ?[]const u8 = null;
        var li = lines(cap.stdout);
        while (li.next()) |line| {
            if (isDivideLine(line)) {
                try divides.append(gpa, line);
            } else if (startsWith(line, "Nodes searched")) {
                nodes_line = line;
            }
        }
        std.mem.sort([]const u8, divides.items, {}, lessThanBytes);
        for (divides.items) |d| try out.print(gpa, "{s}\n", .{d});
        if (nodes_line) |nl| {
            try out.print(gpa, "{s}\n", .{nl});
            totals += 1;
        }
    }
    if (totals != 7) fail("perft: expected 7 totals, got {d} (engine crashed?)", .{totals});
    return out.toOwnedSlice(gpa);
}

fn lessThanBytes(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

// Matches ^[a-h][1-8][a-h][1-8][qrbnQRBN]?: [0-9]+ (a perft divide line).
fn isDivideLine(line: []const u8) bool {
    if (line.len < 6) return false;
    var i: usize = 0;
    if (line[i] < 'a' or line[i] > 'h') return false;
    i += 1;
    if (line[i] < '1' or line[i] > '8') return false;
    i += 1;
    if (line[i] < 'a' or line[i] > 'h') return false;
    i += 1;
    if (line[i] < '1' or line[i] > '8') return false;
    i += 1;
    if (i < line.len and std.mem.indexOfScalar(u8, "qrbnQRBN", line[i]) != null) i += 1;
    if (i + 1 >= line.len or line[i] != ':' or line[i + 1] != ' ') return false;
    i += 2;
    if (i >= line.len or !std.ascii.isDigit(line[i])) return false;
    return true;
}

// eval: the NNUE trace block from `NNUE network contributions` through `Final evaluation`
// (inclusive), per position. The trace is on stderr.
fn buildEval(gpa: std.mem.Allocator, io: Io, bin: []const u8) ![]u8 {
    const sp = "position startpos";
    const kiwi = "position fen r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1";
    const end = "position fen 8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1";
    const mid = "position fen r1bqk2r/pppp1ppp/2n2n2/2b1p3/2B1P3/3P1N2/PPP2PPP/RNBQK2R w KQkq - 0 5";
    const runs = [_]struct { label: []const u8, pos: []const u8 }{
        .{ .label = "== startpos ==", .pos = sp },
        .{ .label = "== kiwipete ==", .pos = kiwi },
        .{ .label = "== endgame ==", .pos = end },
        .{ .label = "== midgame ==", .pos = mid },
    };
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var finals: usize = 0;
    for (runs) |r| {
        try out.print(gpa, "{s}\n", .{r.label});
        const input = try std.fmt.allocPrint(gpa, "{s}\neval\nquit\n", .{r.pos});
        defer gpa.free(input);
        var cap = try runEngine(gpa, io, bin, &.{}, input);
        defer cap.deinit(gpa);
        // range filter over stderr (trace) then stdout, sharing state (block is contiguous).
        var f = false;
        inline for (.{ cap.stderr, cap.stdout }) |buf| {
            var li = lines(buf);
            while (li.next()) |line| {
                if (std.mem.indexOf(u8, line, "NNUE network contributions") != null) f = true;
                if (f) {
                    try out.appendSlice(gpa, line);
                    try out.append(gpa, '\n');
                }
                if (startsWith(line, "Final evaluation")) {
                    if (f) finals += 1;
                    f = false;
                }
            }
        }
    }
    if (finals != 4) fail("eval: expected 4 'Final evaluation' lines, got {d} (crash?)", .{finals});
    return out.toOwnedSlice(gpa);
}

// misc: the `d`-command Fen/Key/Checkers triple (on stdout), per sequence.
fn buildMisc(gpa: std.mem.Allocator, io: Io, bin: []const u8) ![]u8 {
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
        while (li.next()) |line| {
            if (startsWithIgnoreCase(line, "Fen:") or startsWithIgnoreCase(line, "Key:") or startsWithIgnoreCase(line, "Checkers:")) {
                try out.appendSlice(gpa, line);
                try out.append(gpa, '\n');
                if (startsWith(line, "Key:")) keys += 1;
            }
        }
    }
    if (keys != 5) fail("misc: expected 5 Key lines, got {d} (crash?)", .{keys});
    return out.toOwnedSlice(gpa);
}

// uci-options: the `uci` handshake option list -- the compatibility surface a GUI reads.
// The 19 `option name ...` lines are emitted via std.debug.print (stderr); the id name /
// id author lines and the startup banner carry the git sha + date (misc.zig) and are
// volatile every commit, so ONLY the `option name` lines are pinned. Their defaults and
// min/max are static constants -> machine/OS-invariant (Threads max is a fixed 1024, not the
// core count; Hash max is fixed), except EvalFile's default which is the net name (regenerate
// on a net bump, like the other goldens). Complements the option-model unit test
// (option_model.zig) by covering the command -> rendered-output wiring end to end.
fn buildUciOptions(gpa: std.mem.Allocator, io: Io, bin: []const u8) ![]u8 {
    var cap = try runEngine(gpa, io, bin, &.{}, "uci\nquit\n");
    defer cap.deinit(gpa);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var n: usize = 0;
    var li = lines(cap.stderr);
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

// FNV-1a 64-bit -- a dependency-free content hash for the ~90 MB exported net (shipping
// the net as a golden would be absurd; a 64-bit hash + exact length pins any change).
fn fnv1a64(data: []const u8) u64 {
    var h: u64 = 0xcbf29ce484222325;
    for (data) |b| {
        h ^= b;
        h *%= 0x100000001b3;
    }
    return h;
}

// export-net: fingerprint (length + FNV-1a) of the net produced by `export_net`. The
// serializer (nnue_parse.serializeFeatureTransformer/serializeLayer, i.e. Stockfish's
// write_parameters) must reproduce the canonical .nnue byte-for-byte -- upstream's
// export round-trips to the input net exactly, so this gate is a differential-vs-upstream
// check authored against the pristine oracle (see tools/upstream_parity.sh): a matching
// hash means zfish's export == upstream's export == the distributed net. `export_net` is
// synchronous (it runs to completion in the command handler, no async search), so the
// feed-all-then-quit runEngine path is safe here. Writes a temp net in cwd (net/), hashes
// it, and removes it.
fn buildExportNet(gpa: std.mem.Allocator, io: Io, bin: []const u8) ![]u8 {
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

// nodestime: with `nodestime` set, wall-clock budgets convert to a NODE budget
// (timeman.zig `npmsec`), so the otherwise non-deterministic time-management path becomes
// BIT-EXACT -- the `time-mgmt` gate can only band-check the reported ms. This pins the
// allocation arithmetic across its distinct branches (sudden-death wtime/btime, movestogo,
// increment, and the movetime hard limit) by the deterministic depth/score/nodes/bestmove
// the budget yields; the volatile `time`/`nps` fields are dropped. Single thread + node
// budget -> arch/OS-invariant. It is an async search, so it drives the engine via the
// Interactive read-to-bestmove path -- a feed-all-then-quit pipe would truncate it (the
// batch hazard the search-modes gate also avoids).
const NodestimeRow = struct { label: []const u8, cmds: []const u8 };
fn buildNodestime(gpa: std.mem.Allocator, io: Io, bin: []const u8) ![]u8 {
    const sp = "position startpos";
    const end = "position fen 8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1";
    const rows = [_]NodestimeRow{
        .{ .label = "sudden-death ", .cmds = sp ++ "\ngo wtime 10000 btime 10000" },
        .{ .label = "movestogo    ", .cmds = sp ++ "\ngo wtime 10000 btime 10000 movestogo 30" },
        .{ .label = "with-inc     ", .cmds = sp ++ "\ngo wtime 10000 btime 10000 winc 100 binc 100" },
        .{ .label = "endgame-sd   ", .cmds = end ++ "\ngo wtime 5000 btime 5000" },
        .{ .label = "movetime     ", .cmds = sp ++ "\ngo movetime 500" },
    };
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (rows) |r| {
        var s: Interactive = undefined;
        try s.init(io, gpa, bin);
        s.send("setoption name Threads value 1\nsetoption name nodestime value 600\n");
        s.send(r.cmds);
        s.send("\n");
        _ = s.fillUntil("\nbestmove");
        const buf = s.buffered();

        // Keep the last SCORED info line (the final iteration) + the bestmove; any
        // currmove line has no nodes/score and is skipped (the budget stays <10M anyway).
        var last_info: ?InfoLine = null;
        var best: ?BestmoveLine = null;
        var li = lines(buf);
        while (li.next()) |raw| {
            const line = trimCR(raw);
            if (parseInfoLine(line)) |info| {
                if (info.nodes != null and info.score_kind != .none) last_info = info;
            } else if (parseBestmove(line)) |bm| {
                best = bm;
            }
        }
        _ = s.finish();

        const info = last_info orelse fail("nodestime: {s}: no scored info line (truncated?)", .{r.label});
        const bm = best orelse fail("nodestime: {s}: no bestmove", .{r.label});
        try out.print(gpa, "{s}depth={?d} score={s} {?d} nodes={?d} bestmove={s} ponder={s}\n", .{
            r.label, info.depth, @tagName(info.score_kind), info.score_val, info.nodes, bm.bestmove, bm.ponder,
        });
    }
    return out.toOwnedSlice(gpa);
}

// signature: bench must report the exact node count (the 2466447 arch/OS invariant).
fn runSignature(gpa: std.mem.Allocator, io: Io, bin: []const u8, expected: []const u8) noreturn {
    var cap = runEngine(gpa, io, bin, &.{"bench"}, null) catch fail("signature: engine run failed", .{});
    defer cap.deinit(gpa);
    var li = lines(cap.stderr);
    while (li.next()) |line| {
        if (startsWith(line, "Nodes searched")) {
            var toks = std.mem.tokenizeScalar(u8, line, ' ');
            var last: []const u8 = "";
            while (toks.next()) |t| last = t;
            if (std.mem.eql(u8, last, expected)) {
                std.debug.print("signature: OK -- bench == {s}\n", .{expected});
                std.process.exit(0);
            }
            std.debug.print("signature: FAIL -- bench {s} != {s}\n", .{ last, expected });
            std.process.exit(1);
        }
    }
    fail("signature: no 'Nodes searched' line (crash?)", .{});
}

// ---- interactive gates (concurrency + timing) -------------------------------
//
// mt-sanity / stress / time-mgmt drive a *live* search and must not truncate it: this
// engine's UCI loop treats a `quit` (or stdin EOF) arriving during `go` as a stop, so the
// bash gates held stdin open with a sleep. Here we instead read stdout to the `bestmove`
// line BEFORE sending quit -- the search runs to its real depth/time limit. stderr is sent
// to null (the target info/bestmove lines are on stdout) so a single-stream read can't
// deadlock. This is what exercises the sync primitives (futex / RtlWaitOnAddress /
// __ulock) and the ported steady clock (QueryPerformanceCounter on Windows) under real
// concurrency and wall-clock timing -- coverage the single-threaded goldens can't give.

const ScoreKind = enum { none, cp, mate };

const Outcome = struct {
    got_bestmove: bool = false,
    kind: ScoreKind = .none,
    val: i64 = 0,
    time_ms: ?i64 = null,
    bm_buf: [8]u8 = undefined,
    bm_len: usize = 0,
    exited_clean: bool = false,
    fn bestmove(self: *const Outcome) []const u8 {
        return self.bm_buf[0..self.bm_len];
    }
};

fn trimCR(line: []const u8) []const u8 {
    return if (line.len > 0 and line[line.len - 1] == '\r') line[0 .. line.len - 1] else line;
}

fn wellFormedMove(m: []const u8) bool {
    if (std.mem.eql(u8, m, "(none)")) return true;
    if (m.len < 4 or m.len > 5) return false;
    if (m[0] < 'a' or m[0] > 'h' or m[2] < 'a' or m[2] > 'h') return false;
    if (m[1] < '1' or m[1] > '8' or m[3] < '1' or m[3] > '8') return false;
    if (m.len == 5 and std.mem.indexOfScalar(u8, "qrbn", m[4]) == null) return false;
    return true;
}

// Parse "score cp N" / "score mate N" (last one wins) and "time N" into `out`.
fn scanInfo(out: *Outcome, line: []const u8) void {
    var t = std.mem.tokenizeScalar(u8, line, ' ');
    var prev: []const u8 = "";
    while (t.next()) |tok| {
        if (std.mem.eql(u8, prev, "score")) {
            const vtok = t.next() orelse "";
            if (std.mem.eql(u8, tok, "cp")) {
                out.kind = .cp;
                out.val = std.fmt.parseInt(i64, vtok, 10) catch out.val;
            } else if (std.mem.eql(u8, tok, "mate")) {
                out.kind = .mate;
                out.val = std.fmt.parseInt(i64, vtok, 10) catch out.val;
            }
        } else if (std.mem.eql(u8, prev, "time")) {
            out.time_ms = std.fmt.parseInt(i64, tok, 10) catch out.time_ms;
        }
        prev = tok;
    }
}

// Interactive UCI session. The child's stdout pipe is non-blocking (the Io sets it so), so a
// raw File.Reader busy-spins; MultiReader.fill is the Io-aware await that std.process.run
// uses, so this drives the search through it -- accumulate stdout, scan the buffer for a
// marker, keep the search alive (no early quit) until it emits its real bestmove. stderr ->
// null so a single-stream read can't deadlock. Init in place (self-referential buffers).
const Interactive = struct {
    io: Io,
    gpa: std.mem.Allocator,
    child: std.process.Child,
    wbuf: [2048]u8,
    fw: Io.File.Writer,
    mrbuf: Io.File.MultiReader.Buffer(1),
    mr: Io.File.MultiReader,
    // Offset in the accumulated buffer past the last marker matched by fillUntil, so each call
    // waits for the NEXT (new) occurrence rather than re-finding markers from earlier commands.
    scanned: usize,

    fn init(self: *Interactive, io: Io, gpa: std.mem.Allocator, bin: []const u8) !void {
        self.io = io;
        self.gpa = gpa;
        self.scanned = 0;
        self.child = try std.process.spawn(io, .{ .argv = &.{bin}, .stdin = .pipe, .stdout = .pipe, .stderr = .ignore });
        self.fw = self.child.stdin.?.writer(io, &self.wbuf);
        self.mr.init(gpa, io, self.mrbuf.toStreams(), &.{self.child.stdout.?});
    }

    fn send(self: *Interactive, bytes: []const u8) void {
        self.fw.interface.writeAll(bytes) catch {};
        self.fw.interface.flush() catch {};
    }

    fn buffered(self: *Interactive) []const u8 {
        return self.mr.reader(0).buffered();
    }

    // Read more stdout until the NEXT `needle` appears (past prior matches); false at EOF.
    fn fillUntil(self: *Interactive, needle: []const u8) bool {
        while (true) {
            if (std.mem.indexOfPos(u8, self.buffered(), self.scanned, needle)) |pos| {
                self.scanned = pos + needle.len;
                return true;
            }
            self.mr.fill(4096, .none) catch {
                if (std.mem.indexOfPos(u8, self.buffered(), self.scanned, needle)) |pos| {
                    self.scanned = pos + needle.len;
                    return true;
                }
                return false;
            };
        }
    }

    // Send quit, drain to EOF, reap. Returns whether the process exited with code 0.
    fn finish(self: *Interactive) bool {
        self.send("quit\n");
        self.child.stdin.?.close(self.io);
        self.child.stdin = null;
        while (self.mr.fill(4096, .none)) |_| {} else |_| {}
        const term = self.child.wait(self.io) catch std.process.Child.Term{ .unknown = 0 };
        self.mr.deinit();
        self.child.kill(self.io);
        return switch (term) {
            .exited => |c| c == 0,
            else => false,
        };
    }
};

// Scan a captured transcript for the last score/time before the first bestmove, and the move.
fn parseOutcome(text: []const u8) Outcome {
    var out = Outcome{};
    var li = lines(text);
    while (li.next()) |raw| {
        const line = trimCR(raw);
        scanInfo(&out, line);
        if (startsWith(line, "bestmove")) {
            var bt = std.mem.tokenizeScalar(u8, line, ' ');
            _ = bt.next();
            if (bt.next()) |m| {
                const n = @min(m.len, out.bm_buf.len);
                @memcpy(out.bm_buf[0..n], m[0..n]);
                out.bm_len = n;
            }
            out.got_bestmove = true;
            break;
        }
    }
    return out;
}

// One interactive search: send `cmds`, read to the real bestmove (no early-quit truncation).
fn runSearch(io: Io, gpa: std.mem.Allocator, bin: []const u8, cmds: []const u8) !Outcome {
    var s: Interactive = undefined;
    try s.init(io, gpa, bin);
    s.send(cmds);
    _ = s.fillUntil("\nbestmove");
    var out = parseOutcome(s.buffered());
    out.exited_clean = s.finish();
    return out;
}

const MtPos = struct { name: []const u8, cmds: []const u8 };
const mt_positions = [_]MtPos{
    .{ .name = "startpos", .cmds = "position startpos" },
    .{ .name = "open", .cmds = "position startpos moves e2e4 e7e5 g1f3 b8c6 f1b5 a7a6" },
    .{ .name = "endgame", .cmds = "position fen 8/5k2/4p3/4P3/5K2/8/8/8 w - - 0 1" },
    .{ .name = "queens", .cmds = "position startpos moves d2d4 d7d5 c2c4 e7e6 b1c3 g8f6" },
};
const mt_depth = 12;
const mt_band = 150;

// mt-sanity: multi-threaded search must complete with a well-formed bestmove and a score of
// the same kind/sign and within BAND cp of the deterministic single-thread golden. Non-
// deterministic (Lazy SMP), so a band, not a bit-exact gate -- it catches garbled result
// aggregation (wrong voting, dropped PV, sign flips) that the single-thread goldens can't.
fn runMtSanity(gpa: std.mem.Allocator, io: Io, bin: []const u8, golden: []const u8, mode: []const u8) noreturn {
    if (std.mem.eql(u8, mode, "update")) {
        var out: std.ArrayList(u8) = .empty;
        for (mt_positions) |p| {
            const cmds = std.fmt.allocPrint(gpa, "setoption name Threads value 1\n{s}\ngo depth {d}\n", .{ p.cmds, mt_depth }) catch fail("mt-sanity: oom", .{});
            defer gpa.free(cmds);
            const o = runSearch(io, gpa, bin, cmds) catch fail("mt-sanity: engine run failed", .{});
            if (!o.got_bestmove) fail("mt-sanity: {s} single-thread produced no bestmove", .{p.name});
            const kind = if (o.kind == .mate) "mate" else "cp";
            out.print(gpa, "{s:<10} score {s} {d}|bestmove {s}\n", .{ p.name, kind, o.val, o.bestmove() }) catch fail("mt-sanity: oom", .{});
        }
        Io.Dir.cwd().writeFile(io, .{ .sub_path = golden, .data = out.items }) catch fail("mt-sanity: cannot write {s}", .{golden});
        std.debug.print("mt-sanity: wrote golden ({d} positions, depth {d})\n", .{ mt_positions.len, mt_depth });
        std.process.exit(0);
    }

    const raw_golden = Io.Dir.cwd().readFileAlloc(io, golden, gpa, .unlimited) catch
        fail("mt-sanity: golden missing: {s} (run update first)", .{golden});
    defer gpa.free(raw_golden);

    for (mt_positions) |p| {
        // Find this position's single-thread reference score in the golden.
        var ref = Outcome{};
        var found = false;
        var gl = lines(raw_golden);
        while (gl.next()) |line_raw| {
            const line = trimCR(line_raw);
            var toks = std.mem.tokenizeScalar(u8, line, ' ');
            const name = toks.next() orelse continue;
            if (!std.mem.eql(u8, name, p.name)) continue;
            scanInfo(&ref, line);
            found = true;
            break;
        }
        if (!found or ref.kind == .none) fail("mt-sanity: golden has no score for {s} (regenerate)", .{p.name});

        for ([_]u8{ 2, 4 }) |tc| {
            const cmds = std.fmt.allocPrint(gpa, "setoption name Threads value {d}\n{s}\ngo depth {d}\n", .{ tc, p.cmds, mt_depth }) catch fail("mt-sanity: oom", .{});
            defer gpa.free(cmds);
            const o = runSearch(io, gpa, bin, cmds) catch fail("mt-sanity: engine run failed", .{});
            if (!o.got_bestmove or !wellFormedMove(o.bestmove())) fail("mt-sanity: {s} Threads={d}: no/garbled bestmove", .{ p.name, tc });
            if (o.kind == .none) fail("mt-sanity: {s} Threads={d}: no score emitted", .{ p.name, tc });
            if (o.kind != ref.kind) fail("mt-sanity: {s} Threads={d}: score kind differs from single-thread", .{ p.name, tc });
            if (ref.kind == .mate) {
                if ((ref.val < 0) != (o.val < 0)) fail("mt-sanity: {s} Threads={d}: mate sign flipped ({d} vs {d})", .{ p.name, tc, o.val, ref.val });
            } else {
                const diff = if (o.val > ref.val) o.val - ref.val else ref.val - o.val;
                if (diff > mt_band) fail("mt-sanity: {s} Threads={d}: cp {d} vs st {d} exceeds band {d}", .{ p.name, tc, o.val, ref.val, mt_band });
            }
        }
    }
    std.debug.print("mt-sanity: OK ({d} positions, Threads {{2,4}} within band {d} of single-thread, depth {d})\n", .{ mt_positions.len, mt_band, mt_depth });
    std.process.exit(0);
}

const stress_cycles = 24;
const stress_churn = 12;

// stress: liveness for the thread runtime. Phase A hammers ONE process with go/stop
// cycles across thread counts {1,2,4,8} (a third use the go-infinite -> stop handshake, which
// exercises the futex/RtlWaitOnAddress/__ulock wakeup); Phase B churns fresh engine graphs.
// A hang trips the CI job timeout; every search must yield a well-formed bestmove and every
// process must exit cleanly. Not a determinism gate.
fn runStress(gpa: std.mem.Allocator, io: Io, bin: []const u8) noreturn {
    const threads = [_]u8{ 1, 2, 4, 8 };
    std.debug.print("stress: phase A -- {d} go/stop cycles across threads {{1,2,4,8}}\n", .{stress_cycles});

    var s: Interactive = undefined;
    s.init(io, gpa, bin) catch fail("stress: spawn failed", .{});
    // No uciok/readyok barriers: those protocol replies go to stderr (discarded here), and
    // the engine processes commands in order regardless. Synchronize on the stdout markers
    // the search itself emits -- `info depth` (spun up) and `bestmove` (done).
    s.send("setoption name Hash value 16\n");
    var buf: [128]u8 = undefined;
    for (0..stress_cycles) |i| {
        const tc = threads[i % threads.len];
        s.send(std.fmt.bufPrint(&buf, "setoption name Threads value {d}\nucinewgame\n", .{tc}) catch unreachable);
        if (i % 3 == 0) {
            // stop-handshake path: start an unbounded search, wait for it to actually spin up,
            // then stop -- this is what exercises the sync-primitive wakeup under contention.
            s.send("position startpos\ngo infinite\n");
            if (!s.fillUntil("\ninfo depth")) fail("stress: phase A cycle {d} -- infinite search never started", .{i});
            s.send("stop\n");
        } else {
            s.send("position startpos moves e2e4 e7e5\ngo depth 10\n");
        }
        // The cursor makes this wait for THIS cycle's bestmove (not an earlier one).
        if (!s.fillUntil("\nbestmove")) fail("stress: phase A cycle {d} -- no bestmove (lost search?)", .{i});
    }
    const got = std.mem.count(u8, s.buffered(), "\nbestmove");
    const clean = s.finish();
    if (!clean) fail("stress: phase A process did not exit cleanly (crash/abort)", .{});
    if (got != stress_cycles) fail("stress: phase A produced {d} bestmoves, expected {d}", .{ got, stress_cycles });

    std.debug.print("stress: phase B -- {d} construct/destroy iterations\n", .{stress_churn});
    for (0..stress_churn) |j| {
        const tc = threads[j % threads.len];
        const cmds = std.fmt.bufPrint(&buf, "setoption name Threads value {d}\nucinewgame\nposition startpos\ngo depth 8\n", .{tc}) catch unreachable;
        const o = runSearch(io, gpa, bin, cmds) catch fail("stress: phase B iter {d} spawn/run failed", .{j});
        if (!o.got_bestmove) fail("stress: phase B iter {d} (Threads={d}) produced no bestmove", .{ j, tc });
        if (!o.exited_clean) fail("stress: phase B iter {d} (Threads={d}) did not exit cleanly", .{ j, tc });
    }
    std.debug.print("stress: OK (phase A {d} cycles + phase B {d} churns, no hang/crash)\n", .{ stress_cycles, stress_churn });
    std.process.exit(0);
}

// time-mgmt: wall-clock invariants no depth/node gate covers (the startTime=0 class of bug).
// BAND: `go movetime T` reports elapsed within [T/3, 3T+1500]. SCALE: it grows with the
// budget. ALLOC: `go wtime/btime` picks a sane sub-budget. Directly exercises the ported
// steady clock (QueryPerformanceCounter on Windows, CLOCK_MONOTONIC on POSIX).
fn runTimeMgmt(gpa: std.mem.Allocator, io: Io, bin: []const u8) noreturn {
    var reported: [2]i64 = .{ 0, 0 };
    const budgets = [_]i64{ 300, 900 };
    for (budgets, 0..) |t, idx| {
        var cmdbuf: [64]u8 = undefined;
        const cmds = std.fmt.bufPrint(&cmdbuf, "position startpos\ngo movetime {d}\n", .{t}) catch unreachable;
        const o = runSearch(io, gpa, bin, cmds) catch fail("time-mgmt: engine run failed", .{});
        if (!o.got_bestmove or !wellFormedMove(o.bestmove())) fail("time-mgmt: movetime {d}: no legal bestmove", .{t});
        const n = o.time_ms orelse fail("time-mgmt: movetime {d}: engine reported no 'time' field", .{t});
        const lo = @divTrunc(t, 3);
        const hi = 3 * t + 1500;
        if (n < lo or n > hi) fail("time-mgmt: movetime {d}: reported {d}ms outside [{d},{d}] -- startTime/clock regression", .{ t, n, lo, hi });
        reported[idx] = n;
        std.debug.print("time-mgmt: movetime {d} -> reported {d}ms, bestmove ok\n", .{ t, n });
    }
    if (reported[1] - reported[0] < 200) fail("time-mgmt: reported time does not scale with budget (300->{d}, 900->{d}) -- frozen clock", .{ reported[0], reported[1] });

    const o = runSearch(io, gpa, bin, "position startpos\ngo wtime 3000 btime 3000\n") catch fail("time-mgmt: engine run failed", .{});
    if (!o.got_bestmove or !wellFormedMove(o.bestmove())) fail("time-mgmt: wtime/btime: no legal bestmove", .{});
    const w = o.time_ms orelse fail("time-mgmt: wtime/btime: engine reported no 'time' field", .{});
    if (w < 1 or w > 3000) fail("time-mgmt: wtime/btime: allocated {d}ms outside (0,3000] -- allocation regression", .{w});
    std.debug.print("time-mgmt: wtime/btime 3000 -> allocated {d}ms, bestmove ok\n", .{w});
    std.debug.print("time-mgmt: OK (movetime band+scale, wtime allocation)\n", .{});
    std.process.exit(0);
}

// ---- driver -----------------------------------------------------------------

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print(fmt ++ "\n", args);
    std.process.exit(2);
}

const Check = enum { @"output-golden", @"driver-golden", @"search-parity", @"search-modes", perft, eval, misc, @"export-net", nodestime, @"uci-options" };

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var arg_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer arg_it.deinit();
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(gpa);
    while (arg_it.next()) |a| try args.append(gpa, a);

    if (args.items.len < 4) fail("usage: parity_harness <check> <stockfish-bin> <golden|expected> [check|update]", .{});
    const check_name = args.items[1];
    const bin = args.items[2];
    const golden = args.items[3];
    const mode = if (args.items.len >= 5) args.items[4] else "check";

    if (std.mem.eql(u8, check_name, "signature")) runSignature(gpa, io, bin, golden);
    if (std.mem.eql(u8, check_name, "mt-sanity")) runMtSanity(gpa, io, bin, golden, mode);
    if (std.mem.eql(u8, check_name, "stress")) runStress(gpa, io, bin);
    if (std.mem.eql(u8, check_name, "time-mgmt")) runTimeMgmt(gpa, io, bin);

    const check = std.meta.stringToEnum(Check, check_name) orelse
        fail("parity_harness: unknown check '{s}'", .{check_name});

    const live = switch (check) {
        .@"output-golden" => try buildOutputGolden(gpa, io, bin),
        .@"driver-golden" => try buildDriverGolden(gpa, io, bin),
        .@"search-parity" => try buildSearchParity(gpa, io, bin),
        .@"search-modes" => try buildSearchModes(gpa, io, bin),
        .perft => try buildPerft(gpa, io, bin),
        .eval => try buildEval(gpa, io, bin),
        .misc => try buildMisc(gpa, io, bin),
        .@"export-net" => try buildExportNet(gpa, io, bin),
        .nodestime => try buildNodestime(gpa, io, bin),
        .@"uci-options" => try buildUciOptions(gpa, io, bin),
    };
    defer gpa.free(live);

    if (std.mem.eql(u8, mode, "update")) {
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = golden, .data = live });
        std.debug.print("{s}: wrote golden ({d} bytes)\n", .{ check_name, live.len });
        return;
    }

    const raw_golden = Io.Dir.cwd().readFileAlloc(io, golden, gpa, .unlimited) catch
        fail("{s}: golden missing or unreadable: {s} (run the update step first)", .{ check_name, golden });
    defer gpa.free(raw_golden);
    // Normalize the golden's line endings: git may check the committed LF golden out as
    // CRLF on Windows (core.autocrlf), and the live capture is already CR-stripped, so
    // compare CR-free on both sides. (A .gitattributes also pins the goldens to LF.)
    const golden_bytes = try stripCR(gpa, raw_golden);
    defer gpa.free(golden_bytes);

    if (std.mem.eql(u8, golden_bytes, live)) {
        std.debug.print("{s}: OK (matches golden)\n", .{check_name});
        return;
    }

    std.debug.print("{s}: MISMATCH vs golden (< golden, > live):\n", .{check_name});
    printDiff(golden_bytes, live);
    std.process.exit(1);
}

// Structured parity: a byte diff says "these two lines differ" but not WHICH field drifted.
// For the UCI search fingerprints (`info depth ...` / `bestmove ...`) that the search-port workflow
// diffs, parse both sides into a typed record and report the exact field(s) that changed -- so a
// score/nodes/pv regression is localized to one field instead of eyeballed out of a byte diff.

const Tokenizer = std.mem.TokenIterator(u8, .scalar);

fn nextInt(t: *Tokenizer) ?i64 {
    const tok = t.next() orelse return null;
    return std.fmt.parseInt(i64, tok, 10) catch null;
}

// One parsed `info` line. Absent fields stay null; `pv` is the move-list tail (a slice of `line`).
const InfoLine = struct {
    depth: ?i64 = null,
    seldepth: ?i64 = null,
    multipv: ?i64 = null,
    score_kind: ScoreKind = .none,
    score_val: ?i64 = null,
    nodes: ?i64 = null,
    hashfull: ?i64 = null,
    tbhits: ?i64 = null,
    pv: []const u8 = "",
};

fn parseInfoLine(line: []const u8) ?InfoLine {
    if (!startsWith(line, "info ")) return null;
    var r: InfoLine = .{};
    var t = std.mem.tokenizeScalar(u8, line, ' ');
    _ = t.next(); // "info"
    while (t.next()) |tok| {
        if (std.mem.eql(u8, tok, "depth")) {
            r.depth = nextInt(&t);
        } else if (std.mem.eql(u8, tok, "seldepth")) {
            r.seldepth = nextInt(&t);
        } else if (std.mem.eql(u8, tok, "multipv")) {
            r.multipv = nextInt(&t);
        } else if (std.mem.eql(u8, tok, "nodes")) {
            r.nodes = nextInt(&t);
        } else if (std.mem.eql(u8, tok, "hashfull")) {
            r.hashfull = nextInt(&t);
        } else if (std.mem.eql(u8, tok, "tbhits")) {
            r.tbhits = nextInt(&t);
        } else if (std.mem.eql(u8, tok, "score")) {
            const kind = t.next() orelse continue;
            if (std.mem.eql(u8, kind, "cp")) {
                r.score_kind = .cp;
            } else if (std.mem.eql(u8, kind, "mate")) {
                r.score_kind = .mate;
            }
            r.score_val = nextInt(&t);
        } else if (std.mem.eql(u8, tok, "pv")) {
            r.pv = std.mem.trim(u8, t.rest(), " ");
            break; // pv is always last; the rest is the move list
        }
    }
    return r;
}

const BestmoveLine = struct { bestmove: []const u8 = "", ponder: []const u8 = "" };

fn parseBestmove(line: []const u8) ?BestmoveLine {
    if (!startsWith(line, "bestmove")) return null;
    var r: BestmoveLine = .{};
    var t = std.mem.tokenizeScalar(u8, line, ' ');
    _ = t.next(); // "bestmove"
    r.bestmove = t.next() orelse "";
    while (t.next()) |tok| {
        if (std.mem.eql(u8, tok, "ponder")) {
            r.ponder = t.next() orelse "";
            break;
        }
    }
    return r;
}

fn optEql(a: ?i64, b: ?i64) bool {
    if (a == null or b == null) return (a == null) == (b == null);
    return a.? == b.?;
}

fn diffIntField(name: []const u8, g: ?i64, l: ?i64) bool {
    if (optEql(g, l)) return false;
    std.debug.print("    {s}: golden={?d} live={?d}\n", .{ name, g, l });
    return true;
}

// Pure predicates (no I/O -> unit-testable): does any parsed field differ? structuredFieldDiff
// prints the per-field breakdown for the same decision, so these mirror its "any differ" result.
fn infoLinesDiffer(g: InfoLine, l: InfoLine) bool {
    return !optEql(g.depth, l.depth) or !optEql(g.seldepth, l.seldepth) or
        !optEql(g.multipv, l.multipv) or g.score_kind != l.score_kind or
        !optEql(g.score_val, l.score_val) or !optEql(g.nodes, l.nodes) or
        !optEql(g.hashfull, l.hashfull) or !optEql(g.tbhits, l.tbhits) or
        !std.mem.eql(u8, g.pv, l.pv);
}

fn bestmoveLinesDiffer(g: BestmoveLine, l: BestmoveLine) bool {
    return !std.mem.eql(u8, g.bestmove, l.bestmove) or !std.mem.eql(u8, g.ponder, l.ponder);
}

// Print the field-level delta of a differing line pair. Returns true iff the pair was a
// recognized (info / bestmove) shape AND at least one PARSED field differs -- if the lines
// differ only in an un-parsed field (wdl / time / nps), returns false so the caller keeps the
// raw `< / >` fallback rather than claiming "no field differs".
fn structuredFieldDiff(golden_line: []const u8, live_line: []const u8) bool {
    if (parseInfoLine(golden_line)) |g| {
        const l = parseInfoLine(live_line) orelse return false;
        var any = false;
        if (diffIntField("depth", g.depth, l.depth)) any = true;
        if (diffIntField("seldepth", g.seldepth, l.seldepth)) any = true;
        if (diffIntField("multipv", g.multipv, l.multipv)) any = true;
        if (g.score_kind != l.score_kind or !optEql(g.score_val, l.score_val)) {
            std.debug.print("    score: golden={s} {?d} live={s} {?d}\n", .{ @tagName(g.score_kind), g.score_val, @tagName(l.score_kind), l.score_val });
            any = true;
        }
        if (diffIntField("nodes", g.nodes, l.nodes)) any = true;
        if (diffIntField("hashfull", g.hashfull, l.hashfull)) any = true;
        if (diffIntField("tbhits", g.tbhits, l.tbhits)) any = true;
        if (!std.mem.eql(u8, g.pv, l.pv)) {
            std.debug.print("    pv: golden='{s}' live='{s}'\n", .{ g.pv, l.pv });
            any = true;
        }
        return any;
    }
    if (parseBestmove(golden_line)) |g| {
        const l = parseBestmove(live_line) orelse return false;
        var any = false;
        if (!std.mem.eql(u8, g.bestmove, l.bestmove)) {
            std.debug.print("    bestmove: golden='{s}' live='{s}'\n", .{ g.bestmove, l.bestmove });
            any = true;
        }
        if (!std.mem.eql(u8, g.ponder, l.ponder)) {
            std.debug.print("    ponder: golden='{s}' live='{s}'\n", .{ g.ponder, l.ponder });
            any = true;
        }
        return any;
    }
    return false;
}

// First ~40 differing lines, in `diff`-ish `< golden` / `> live` form, each followed (when the
// pair is a parseable search line) by the structured field-level delta.
fn printDiff(golden: []const u8, live: []const u8) void {
    var g = lines(golden);
    var l = lines(live);
    var shown: usize = 0;
    while (shown < 40) {
        const gl = g.next();
        const ll = l.next();
        if (gl == null and ll == null) break;
        const ga = gl orelse "";
        const la = ll orelse "";
        if (!std.mem.eql(u8, ga, la)) {
            if (gl != null) std.debug.print("< {s}\n", .{ga});
            if (ll != null) std.debug.print("> {s}\n", .{la});
            if (gl != null and ll != null) _ = structuredFieldDiff(ga, la);
            shown += 1;
        }
    }
}

test "parseInfoLine extracts depth / score / nodes / pv" {
    const r = parseInfoLine("info depth 8 seldepth 13 multipv 1 score cp 26 wdl 56 936 8 nodes 13178 hashfull 3 tbhits 0 pv e2e4 e7e5 g1f3").?;
    try std.testing.expectEqual(@as(?i64, 8), r.depth);
    try std.testing.expectEqual(@as(?i64, 13), r.seldepth);
    try std.testing.expectEqual(ScoreKind.cp, r.score_kind);
    try std.testing.expectEqual(@as(?i64, 26), r.score_val);
    try std.testing.expectEqual(@as(?i64, 13178), r.nodes);
    try std.testing.expectEqual(@as(?i64, 3), r.hashfull);
    try std.testing.expectEqualStrings("e2e4 e7e5 g1f3", r.pv);
}

test "parseInfoLine handles a mate score and an empty pv tail" {
    const r = parseInfoLine("info depth 24 score mate 5 nodes 999 pv").?;
    try std.testing.expectEqual(ScoreKind.mate, r.score_kind);
    try std.testing.expectEqual(@as(?i64, 5), r.score_val);
    try std.testing.expectEqualStrings("", r.pv);
}

test "parseInfoLine rejects a non-info line" {
    try std.testing.expect(parseInfoLine("bestmove e2e4") == null);
}

test "parseBestmove extracts bestmove + ponder" {
    const r = parseBestmove("bestmove e2e4 ponder e7e5").?;
    try std.testing.expectEqualStrings("e2e4", r.bestmove);
    try std.testing.expectEqualStrings("e7e5", r.ponder);
    const np = parseBestmove("bestmove d2d4").?;
    try std.testing.expectEqualStrings("d2d4", np.bestmove);
    try std.testing.expectEqualStrings("", np.ponder);
}

test "infoLinesDiffer flags a nodes-only drift and passes an identical pair" {
    const a = parseInfoLine("info depth 8 score cp 26 nodes 13178 pv e2e4").?;
    const b = parseInfoLine("info depth 8 score cp 26 nodes 13200 pv e2e4").?;
    try std.testing.expect(infoLinesDiffer(a, b)); // one parsed field (nodes) differs
    try std.testing.expect(!infoLinesDiffer(a, a)); // identical -> no field differs
    try std.testing.expectEqual(@as(?i64, 13178), a.nodes);
    try std.testing.expectEqual(@as(?i64, 13200), b.nodes);
}

test "field comparison detects a bestmove change and a score-kind flip" {
    const gm = parseBestmove("bestmove e2e4 ponder e7e5").?;
    const lm = parseBestmove("bestmove d2d4 ponder d7d5").?;
    try std.testing.expect(bestmoveLinesDiffer(gm, lm));
    const cp = parseInfoLine("info depth 5 score cp 20 nodes 9").?;
    const mate = parseInfoLine("info depth 5 score mate 3 nodes 9").?;
    try std.testing.expect(infoLinesDiffer(cp, mate));
    try std.testing.expectEqual(ScoreKind.mate, mate.score_kind);
}

test "optEql treats null / value / equal correctly" {
    try std.testing.expect(optEql(null, null));
    try std.testing.expect(optEql(5, 5));
    try std.testing.expect(!optEql(null, 5));
    try std.testing.expect(!optEql(5, 6));
}
