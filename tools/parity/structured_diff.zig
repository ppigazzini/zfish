//! Parse a UCI `info` / `bestmove` line into a typed record, and say WHICH field drifted.
//!
//! A byte diff reports that two lines differ; the search-port workflow needs the field. Own
//! the golden diff printer as well, so the byte comparison and the field attribution stay in
//! one place: `printDiff` walks the pair and hands each differing line here.
//!
//! `ScoreKind` lives here rather than beside the session type because the record owns it --
//! the session reports a score, this file decides what a score IS.

const std = @import("std");
const run = @import("run.zig");

const lines = run.lines;
const startsWith = run.startsWith;

pub const ScoreKind = enum { none, cp, mate };

// Structured parity: a byte diff says "these two lines differ" but not WHICH field drifted.
// For the UCI search fingerprints (`info depth ...` / `bestmove ...`) that the search-port workflow
// diffs, parse both sides into a typed record and report the exact field(s) that changed -- so a
// score/nodes/pv regression is localized to one field instead of eyeballed out of a byte diff.

const Tokenizer = std.mem.TokenIterator(u8, .scalar);

fn nextInt(t: *Tokenizer) ?i64 {
    const tok = t.next() orelse return null;
    return std.fmt.parseInt(i64, tok, 10) catch null;
}

// Hold one parsed `info` line. Absent fields stay null; `pv` is the move-list tail (a slice of `line`).
pub const InfoLine = struct {
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

pub fn parseInfoLine(line: []const u8) ?InfoLine {
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

pub const BestmoveLine = struct { bestmove: []const u8 = "", ponder: []const u8 = "" };

pub fn parseBestmove(line: []const u8) ?BestmoveLine {
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

pub fn optEql(a: ?i64, b: ?i64) bool {
    if (a == null or b == null) return (a == null) == (b == null);
    return a.? == b.?;
}

fn diffIntField(name: []const u8, g: ?i64, l: ?i64) bool {
    if (optEql(g, l)) return false;
    std.debug.print("    {s}: golden={?d} live={?d}\n", .{ name, g, l });
    return true;
}

// Provide pure predicates (no I/O -> unit-testable): does any parsed field differ? structuredFieldDiff
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

// Print the field-level delta of a differing line pair. Return true iff the pair was a
// recognized (info / bestmove) shape AND at least one PARSED field differs -- if the lines
// differ only in an un-parsed field (wdl / time / nps), return false so the caller keeps the
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

// Print the first ~40 differing lines, in `diff`-ish `< golden` / `> live` form, each followed (when the
// pair is a parseable search line) by the structured field-level delta.
pub fn printDiff(golden: []const u8, live: []const u8) void {
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
