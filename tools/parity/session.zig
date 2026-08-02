//! Hold one engine as a LIVE process and read its stdout to a mark.
//!
//! The UCI loop treats a `quit` -- or stdin EOF -- arriving during `go` as a stop, so a piped
//! script truncates the search it was meant to measure and the resulting move is
//! timing-dependent. Read to the `bestmove` line BEFORE sending quit and the search runs to
//! its real depth or time limit. stderr goes to null: the info and bestmove lines are on
//! stdout, and a single-stream read cannot then deadlock.
//!
//! This is the only way a gate here reaches the sync primitives (futex / RtlWaitOnAddress /
//! __ulock) and the ported steady clock under real concurrency and wall-clock timing. Every
//! gate that must not truncate builds on `Interactive`; the one-shot capture in `run.zig` is
//! for everything that can be fed a whole script and read afterwards.
const std = @import("std");
const Io = std.Io;
const run = @import("run.zig");
const structured_diff = @import("structured_diff.zig");

const lines = run.lines;
const startsWith = run.startsWith;
const trimCR = run.trimCR;
const fail = run.fail;
const ScoreKind = structured_diff.ScoreKind;

pub const Outcome = struct {
    got_bestmove: bool = false,
    kind: ScoreKind = .none,
    val: i64 = 0,
    nodes: ?i64 = null,
    time_ms: ?i64 = null,
    bm_buf: [8]u8 = undefined,
    bm_len: usize = 0,
    exited_clean: bool = false,
    pub fn bestmove(self: *const Outcome) []const u8 {
        return self.bm_buf[0..self.bm_len];
    }
};

pub fn wellFormedMove(m: []const u8) bool {
    if (std.mem.eql(u8, m, "(none)")) return true;
    if (m.len < 4 or m.len > 5) return false;
    if (m[0] < 'a' or m[0] > 'h' or m[2] < 'a' or m[2] > 'h') return false;
    if (m[1] < '1' or m[1] > '8' or m[3] < '1' or m[3] > '8') return false;
    if (m.len == 5 and std.mem.findScalar(u8, "qrbn", m[4]) == null) return false;
    return true;
}

// Parse "score cp N" / "score mate N" (last one wins), "time N", "nodes N", and the
// "bestmove M" move token into `out`. Use it both on live engine output (info + bestmove
// lines) and on a committed golden line that packs the same fields.
pub fn scanInfo(out: *Outcome, line: []const u8) void {
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
        } else if (std.mem.eql(u8, prev, "nodes")) {
            out.nodes = std.fmt.parseInt(i64, tok, 10) catch out.nodes;
        } else if (std.mem.eql(u8, prev, "bestmove")) {
            const n = @min(tok.len, out.bm_buf.len);
            @memcpy(out.bm_buf[0..n], tok[0..n]);
            out.bm_len = n;
        }
        prev = tok;
    }
}

// Drive an interactive UCI session. The child's stdout pipe is non-blocking (the Io sets it so), so a
// raw File.Reader busy-spins; MultiReader.fill is the Io-aware await that std.process.run
// uses, so this drives the search through it -- accumulate stdout, scan the buffer for a
// marker, keep the search alive (no early quit) until it emits its real bestmove. stderr ->
// null so a single-stream read can't deadlock. Init in place (self-referential buffers).
pub const Interactive = struct {
    io: Io,
    gpa: std.mem.Allocator,
    child: std.process.Child,
    wbuf: [2048]u8,
    fw: Io.File.Writer,
    mrbuf: Io.File.MultiReader.Buffer(1),
    mr: Io.File.MultiReader,
    // Track the offset in the accumulated buffer past the last marker matched by fillUntil, so each
    // call waits for the NEXT (new) occurrence rather than re-finding markers from earlier commands.
    scanned: usize,

    pub fn init(self: *Interactive, io: Io, gpa: std.mem.Allocator, bin: []const u8) !void {
        self.io = io;
        self.gpa = gpa;
        self.scanned = 0;
        self.child = try std.process.spawn(io, .{ .argv = &.{bin}, .stdin = .pipe, .stdout = .pipe, .stderr = .ignore });
        self.fw = self.child.stdin.?.writer(io, &self.wbuf);
        self.mr.init(gpa, io, self.mrbuf.toStreams(), &.{self.child.stdout.?});
    }

    pub fn send(self: *Interactive, bytes: []const u8) void {
        // Report a failed write. Swallowing it makes a DEAD ENGINE look like a gate that
        // timed out reading, which sends the next reader after the wrong bug.
        self.fw.interface.writeAll(bytes) catch fail("session: write to the engine failed (it exited early?)", .{});
        self.fw.interface.flush() catch fail("session: flush to the engine failed (it exited early?)", .{});
    }

    pub fn buffered(self: *Interactive) []const u8 {
        return self.mr.reader(0).buffered();
    }

    // Read more stdout until the NEXT `needle` appears (past prior matches); false at EOF.
    pub fn fillUntil(self: *Interactive, needle: []const u8) bool {
        while (true) {
            if (std.mem.findPos(u8, self.buffered(), self.scanned, needle)) |pos| {
                self.scanned = pos + needle.len;
                return true;
            }
            self.mr.fill(4096, .none) catch {
                if (std.mem.findPos(u8, self.buffered(), self.scanned, needle)) |pos| {
                    self.scanned = pos + needle.len;
                    return true;
                }
                return false;
            };
        }
    }

    // Send quit, drain to EOF, reap. Return whether the process exited with code 0.
    pub fn finish(self: *Interactive) bool {
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
        scanInfo(&out, line); // capture score/nodes from info lines, the move from bestmove
        if (startsWith(line, "bestmove")) {
            out.got_bestmove = true;
            break;
        }
    }
    return out;
}

// Run one interactive search: send `cmds`, read to the real bestmove (no early-quit truncation).
pub fn runSearch(io: Io, gpa: std.mem.Allocator, bin: []const u8, cmds: []const u8) !Outcome {
    var s: Interactive = undefined;
    try s.init(io, gpa, bin);
    s.send(cmds);
    _ = s.fillUntil("\nbestmove");
    var out = parseOutcome(s.buffered());
    out.exited_clean = s.finish();
    return out;
}
