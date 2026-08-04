//! Drive the engine and read its lines -- the primitives every gate in this package uses.
//!
//! Own the process seam (spawn, feed a UCI script, capture both streams CR-stripped), the
//! line helpers that replaced the bash gates' sed/grep, and `fail`. Import nothing but std,
//! so the dependency runs run -> everything else and never back: the leaf gates need these,
//! and the ROOT imports the leaves, so a helper left in the root would close a cycle.

const std = @import("std");
const Io = std.Io;

pub const Captured = struct {
    stdout: []u8,
    stderr: []u8,
    pub fn deinit(self: Captured, gpa: std.mem.Allocator) void {
        gpa.free(self.stdout);
        gpa.free(self.stderr);
    }
};

// Spawn the engine, optionally feed it a UCI script on stdin, and capture stdout+stderr
// (CR-stripped so Windows text-mode CRLF matches the LF goldens). Mirror std.process.run's
// deadlock-free MultiReader drain, adding the stdin write run() lacks.
pub fn runEngine(
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

pub fn stripCR(gpa: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (bytes) |ch| if (ch != '\r') try out.append(gpa, ch);
    return out.toOwnedSlice(gpa);
}

// ---- small text helpers (POSIX-tool replacements) ---------------------------

pub const LineIter = struct {
    it: std.mem.SplitIterator(u8, .scalar),
    pub fn next(self: *LineIter) ?[]const u8 {
        while (self.it.next()) |l| {
            // Skip the trailing empty slice splitScalar yields after the final '\n', so
            // callers see only real lines (bash pipelines never see that phantom line).
            if (self.it.index == null and l.len == 0) return null;
            return l;
        }
        return null;
    }
};
pub fn lines(text: []const u8) LineIter {
    return .{ .it = std.mem.splitScalar(u8, text, '\n') };
}

pub fn startsWith(line: []const u8, prefix: []const u8) bool {
    return std.mem.startsWith(u8, line, prefix);
}

pub fn startsWithIgnoreCase(line: []const u8, prefix: []const u8) bool {
    if (line.len < prefix.len) return false;
    return std.ascii.eqlIgnoreCase(line[0..prefix.len], prefix);
}

// Remove the first " <field> <digits>" run from a line (sed 's/ field [0-9]+//').
pub fn removeField(gpa: std.mem.Allocator, line: []const u8, field: []const u8) ![]u8 {
    const idx = std.mem.find(u8, line, field) orelse return gpa.dupe(u8, line);
    var end = idx + field.len;
    while (end < line.len and std.ascii.isDigit(line[end])) end += 1;
    if (end == idx + field.len) return gpa.dupe(u8, line); // no digits -> not the field
    var out = try gpa.alloc(u8, line.len - (end - idx));
    @memcpy(out[0..idx], line[0..idx]);
    @memcpy(out[idx..], line[end..]);
    return out;
}

// Report the CR-trimmed line. The interactive reads split on '\n' alone, so a Windows
// text-mode stream leaves the '\r' attached to every line a comparison then misses.
pub fn trimCR(line: []const u8) []const u8 {
    return if (line.len > 0 and line[line.len - 1] == '\r') line[0 .. line.len - 1] else line;
}

// Report whether the line is one `go perft` divide row (`e2e4: 20`) rather than a total or
// a blank -- the perft golden sorts these, and the ponder gate counts them.
pub fn isDivideLine(line: []const u8) bool {
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
    if (i < line.len and std.mem.findScalar(u8, "qrbnQRBN", line[i]) != null) i += 1;
    if (i + 1 >= line.len or line[i] != ':' or line[i + 1] != ' ') return false;
    i += 2;
    if (i >= line.len or !std.ascii.isDigit(line[i])) return false;
    return true;
}

// Print the message and exit 2, the harness's "crash / usage" status. Live here rather than
// beside `main` so a leaf can call it without importing the root.
pub fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print(fmt ++ "\n", args);
    std.process.exit(2);
}

/// Name the env var that lets `<gate>-update` write a golden from THIS binary.
pub const golden_update_override = "ZFISH_GOLDEN_UPDATE_FROM_ZFISH";

/// Refuse to photograph the engine under test, unless the caller says that is the intent.
///
/// Every `-update` step drives zfish, so the golden it writes records whatever this binary
/// does -- a defect exactly as faithfully as correct behaviour, after which the gate passes
/// BECAUSE the engine is wrong. AGENTS.md states the rule ("drive the oracle, match its
/// bytes") and `tools/upstream_golden_audit.sh --write` implements it, one keystroke away
/// and producing a diff that looks identical. Make the wrong one harder to run than the
/// right one rather than leaving the distinction to whoever is typing.
///
/// The override stays because a gate whose golden the oracle CANNOT adjudicate needs some
/// way through (mt-sanity's thread-count banner is not upstream-observable), and a gate with
/// no escape hatch gets worked around instead of argued with. It announces itself on every
/// run so an override in a script is visible in that script's log.
/// Query the override cross-platform: `getPosix` would answer `false` on Windows, which is
/// the wrong direction for an escape hatch (it would make the gate unopenable there rather
/// than merely unset). Treat an unreadable environment as "not set" -- refusing is the safe
/// arm, and the message says how to proceed.
pub fn refuseSelfMadeGolden(
    gpa: std.mem.Allocator,
    environ: std.process.Environ,
    check_name: []const u8,
    golden: []const u8,
) void {
    const overridden = environ.containsUnempty(gpa, golden_update_override) catch false;
    if (overridden) {
        std.debug.print(
            "{s}: {s} is set -- writing a golden PHOTOGRAPHED FROM THIS BINARY, not adjudicated\n" ++
                "{s}: by the oracle. It pins whatever this binary does, including a defect.\n",
            .{ check_name, golden_update_override, check_name },
        );
        return;
    }
    std.debug.print(
        \\{s}: REFUSING to write {s} from this binary.
        \\
        \\A golden written by the engine under test is a photograph of the engine: it pins a
        \\defect as faithfully as correct behaviour, and the gate then passes BECAUSE the
        \\engine is wrong. Drive the oracle and match its bytes instead:
        \\
        \\    tools/upstream_golden_audit.sh {s}
        \\
        \\If this golden genuinely cannot be adjudicated upstream, say so explicitly:
        \\
        \\    {s}=1 zig build <this gate>-update
        \\
    , .{ check_name, golden, check_name, golden_update_override });
    std.process.exit(2);
}
