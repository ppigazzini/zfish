// Pure-Zig parity harness (M-PORT.2): the cross-platform replacement for the bash
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
//     run bench and assert `Nodes searched` == expected (the 2067208 arch/OS invariant).
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
        const bm = try firstLineWithPrefix(gpa, io, bin, r.seq, "bestmove", .stdout);
        defer gpa.free(bm);
        if (bm.len == 0) fail("search-modes: a test produced no bestmove (engine crashed?)", .{});
        try out.print(gpa, "{s}{s}\n", .{ r.label, bm });
    }
    return out.toOwnedSlice(gpa);
}

const Stream = enum { stdout, stderr };

// Run one UCI sequence (quit appended) and return the first line with `prefix` (owned).
fn firstLineWithPrefix(gpa: std.mem.Allocator, io: Io, bin: []const u8, seq: []const u8, prefix: []const u8, stream: Stream) ![]u8 {
    const input = try std.fmt.allocPrint(gpa, "{s}\nquit\n", .{seq});
    defer gpa.free(input);
    var cap = try runEngine(gpa, io, bin, &.{}, input);
    defer cap.deinit(gpa);
    const buf = if (stream == .stdout) cap.stdout else cap.stderr;
    var li = lines(buf);
    while (li.next()) |line| {
        if (startsWith(line, prefix)) return gpa.dupe(u8, line);
    }
    return gpa.dupe(u8, "");
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

// signature: bench must report the exact node count (the 2067208 arch/OS invariant).
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

// ---- driver -----------------------------------------------------------------

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print(fmt ++ "\n", args);
    std.process.exit(2);
}

const Check = enum { @"output-golden", @"search-parity", @"search-modes", perft, eval, misc };

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

    const check = std.meta.stringToEnum(Check, check_name) orelse
        fail("parity_harness: unknown check '{s}'", .{check_name});

    const live = switch (check) {
        .@"output-golden" => try buildOutputGolden(gpa, io, bin),
        .@"search-parity" => try buildSearchParity(gpa, io, bin),
        .@"search-modes" => try buildSearchModes(gpa, io, bin),
        .perft => try buildPerft(gpa, io, bin),
        .eval => try buildEval(gpa, io, bin),
        .misc => try buildMisc(gpa, io, bin),
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

// First ~40 differing lines, in `diff`-ish `< golden` / `> live` form.
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
            shown += 1;
        }
    }
}
