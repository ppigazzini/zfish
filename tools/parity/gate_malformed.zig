//! Assert that a KNOWN-BAD tablebase file is still refused, and that refusing it costs the
//! engine nothing.
//!
//! EVERY OTHER GATE IN THIS TREE MEASURES THE ENGINE COMPUTING THE RIGHT ANSWER FROM
//! WELL-FORMED INPUT. `signature` is the anchor and it stays green with every parser bound in
//! this file reverted, because the bench reads no file the engine did not ship with. The fuzz
//! targets (src/platform/syzygy/fuzz_targets.zig) look for input that is bad in a way nobody
//! has described yet -- a different job, on a nightly budget, and explicitly not a merge gate.
//! Neither asks whether a file that was refused yesterday is refused today, so nothing did:
//! the whole of decode_header.zig's refusal set, table_load.zig's region carving and
//! decode.zig's two probe-time bounds were pinned by unit tests on the DECODER and by nothing
//! at all on the shipped loader. A unit test that calls setSizes directly cannot see a loader
//! that stopped calling it.
//!
//! WHAT A REFUSAL MEANS HERE, and all three parts are checked on every fixture:
//!
//!   * the process exits 0 -- not a signal, not an abort, not a Zig panic;
//!   * it still ANSWERS. A parser that takes the engine down with it has not refused the file,
//!     it has been defeated by it. So every fixture ends in a real search and requires a
//!     well-formed bestmove;
//!   * it does not hang. A cyclic btree is a HANG rather than a crash, which is the one failure
//!     class a crash-oriented fuzzer reports as a timeout instead of a bug -- so the search is
//!     depth-limited and a wedge fails the run through the aggregate's own timeout.
//!
//! THE BATTERY IS A MUTATION OF A REAL TABLE, NOT A CRAFTED BLOB, and that is what keeps it
//! from rotting. An 80-byte hand-built file reaches the header parse and stops; a real table
//! mutated in one byte reaches the block walk, the symbol decode and the btree descent, which
//! is where the bounds that matter live. The edits are a committed LIST rather than a seed,
//! because a seed reproduces the harness and a byte list reproduces the defect.
//!
//! MOST OF THESE ARE NOT DETECTABLE AS CORRUPTION, and the bar is survival rather than a
//! diagnostic for exactly that reason. The Syzygy format records nothing that says which value
//! was meant, so a reader cannot tell a mutated `lowestSym` from an intended one and must not
//! pretend to. What it must do is stay inside its arrays and keep answering.

const std = @import("std");
const Io = std.Io;
const run = @import("run.zig");
const session = @import("session.zig");

const runSearch = session.runSearch;
const wellFormedMove = session.wellFormedMove;
const fail = run.fail;

// Name the working directory the fixtures are written into, relative to the harness cwd
// (resources/). Kept out of syzygy/ so a mutated table can never be mistaken for a fetched one.
const fixture_dir = "malformed-fixtures";

// Probe one 3-man position per stem, so the mutated table is the one the search actually reads.
const Stem = struct {
    name: []const u8,
    fen: []const u8,
};

const stems = [_]Stem{
    .{ .name = "KQvK", .fen = "4k3/8/8/8/8/8/8/3QK3 w - - 0 1" },
    .{ .name = "KRvK", .fen = "4k3/8/8/8/8/8/8/3RK3 w - - 0 1" },
};

// One fixture: a stem, a name, and the byte edits to apply to a copy of its .rtbw.
//
// Offsets are into the REAL table, so they land on whatever field lives there -- which is the
// point. Naming a field would make this a claim about the format that the next format change
// falsifies silently; naming an offset makes it a claim about the engine, which is what is
// being gated. The `why` text records what the edit was AIMED at when it was written.
const Fixture = struct {
    name: []const u8,
    stem: []const u8,
    edits: []const [2]u32, // {offset, value}
    why: []const u8,
};

// Both 3-man stems are pawnless split WDL tables and share one header layout, DERIVED by
// walking table_load.set() rather than assumed -- the first version of this file guessed and
// negative_control.sh caught every header fixture landing on the piece list instead, green:
//
//   0..3   magic 71 E8 23 5D          4      flags: Split=1, HasPawns=0
//   5      order nibbles              6..8   the three piece nibbles
//   9      -> 10 after `pos += pos & 1`
//   10     side 0 PairsData flags = 0x80, SINGLE VALUE -- two bytes and done
//   12     side 1 PairsData flags = 0    13   sizeof_block log    14  span log
//   15     padding                       16..19  blocks_num (u32)
//   20     max_sym_len                   21   min_sym_len
//
// So the compressed PairsData -- the one with every bound worth gating -- is side 1, at 12.
// Re-derive these if the corpus or the format changes; the `why` text says what each aims at,
// and negative_control.sh's `parity-malformed` row is what proves they still land.
const fixtures = [_]Fixture{
    .{
        .name = "block-shift",
        .stem = "KQvK",
        .edits = &.{.{ 13, 200 }},
        .why = "sizeof_block log >= 64 -- a raw file byte used as a shift width",
    },
    .{
        .name = "span-shift",
        .stem = "KQvK",
        .edits = &.{.{ 14, 255 }},
        .why = "span log >= 64 -- the same shift width, one field along",
    },
    .{
        .name = "symlen-inverted",
        .stem = "KQvK",
        .edits = &.{ .{ 20, 1 }, .{ 21, 9 } },
        .why = "max_sym_len < min_sym_len -- underflows the u8 subtraction sizing base64",
    },
    .{
        .name = "symlen-zero",
        .stem = "KQvK",
        .edits = &.{.{ 21, 0 }},
        .why = "min_sym_len == 0 -- makes the k == 0 right-pad shift exactly 64",
    },
    .{
        .name = "symlen-oversized",
        .stem = "KQvK",
        .edits = &.{.{ 20, 70 }},
        .why = "max_sym_len >= 64 -- drives the right-pad shift width negative",
    },
    .{
        .name = "blocks-overflow",
        .stem = "KQvK",
        .edits = &.{ .{ 15, 1 }, .{ 16, 0xFF }, .{ 17, 0xFF }, .{ 18, 0xFF }, .{ 19, 0xFF } },
        .why = "blocks_num = u32 max, padding = 1 -- blocks_num + padding must not wrap",
    },
    // Deep mutations. These reach past the header into the btree and the compressed payload,
    // where the bound is decode.zig's probe-time symbol test and its btree-descent variant.
    .{
        .name = "btree-and-payload",
        .stem = "KQvK",
        .edits = &.{ .{ 35, 189 }, .{ 66, 15 }, .{ 108, 212 }, .{ 144, 1 } },
        .why = "btree children and stream bytes -- the decoded symbol must stay in the alphabet",
    },
    .{
        .name = "cyclic-btree",
        .stem = "KRvK",
        .edits = &.{ .{ 53, 183 }, .{ 100, 132 }, .{ 119, 76 }, .{ 183, 198 } },
        .why = "a btree that closes a loop -- a HANG, not a crash, unless symlen must shrink",
    },
    .{
        .name = "sparse-block",
        .stem = "KRvK",
        .edits = &.{ .{ 29, 250 }, .{ 32, 220 }, .{ 65, 158 }, .{ 109, 40 } },
        .why = "sparse-index block field -- the walk must not leave blockLength[]",
    },
    // Whole-file shapes the outer loader owns rather than the header parse.
    .{
        .name = "bad-magic",
        .stem = "KQvK",
        .edits = &.{ .{ 0, 0 }, .{ 1, 0 }, .{ 2, 0 }, .{ 3, 0 } },
        .why = "the one field the format DOES let a reader check; a control on the harness",
    },
};

// Copy `stem`.rtbw out of syzygy/, apply the edits, and write it into the fixture directory.
// Return false when the source table is absent, which is a SKIP rather than a pass.
fn writeFixture(gpa: std.mem.Allocator, io: Io, dir: Io.Dir, f: Fixture) !bool {
    var src_buf: [64]u8 = undefined;
    const src = try std.fmt.bufPrint(&src_buf, "syzygy/{s}.rtbw", .{f.stem});
    const bytes = Io.Dir.cwd().readFileAlloc(io, src, gpa, .unlimited) catch return false;
    defer gpa.free(bytes);

    for (f.edits) |e| {
        const off: usize = e[0];
        // An offset past this table is a rig fault, not a finding: the fixture would then test
        // nothing while reporting a pass.
        if (off >= bytes.len)
            fail("malformed: fixture '{s}' edits offset {d} of a {d}-byte {s}.rtbw", .{ f.name, off, bytes.len, f.stem });
        bytes[off] = @intCast(e[1]);
    }

    var dst_buf: [64]u8 = undefined;
    const dst = try std.fmt.bufPrint(&dst_buf, "{s}.rtbw", .{f.stem});
    try dir.writeFile(io, .{ .sub_path = dst, .data = bytes });
    return true;
}

// Drive one fixture: point SyzygyPath at the fixture directory, probe the matching position at a
// shallow depth, and require a well-formed bestmove and a clean exit.
//
// Single-threaded and depth-limited on purpose. This gate exists to prove a PARSER stays inside
// its arrays; giving it threads or a deep search would trade that signal for wall clock and for
// memory this box has no reason to spend.
fn driveFixture(gpa: std.mem.Allocator, io: Io, bin: []const u8, f: Fixture, fen: []const u8) !void {
    const script = try std.fmt.allocPrint(gpa,
        \\setoption name Threads value 1
        \\setoption name SyzygyPath value {s}
        \\position fen {s}
        \\go depth 6
        \\
    , .{ fixture_dir, fen });
    defer gpa.free(script);

    // runSearch reads to the bestmove BEFORE sending quit, so a search cut short by EOF cannot
    // be mistaken for one the parser survived, and it reports the exit status the other two
    // properties are checked alongside.
    const o = runSearch(io, gpa, bin, script) catch
        fail("malformed: fixture '{s}' ({s}) -- the engine could not be run", .{ f.name, f.why });

    if (!o.got_bestmove)
        fail("malformed: fixture '{s}' ({s}) produced no bestmove -- the parser took the search with it", .{ f.name, f.why });
    if (!wellFormedMove(o.bestmove()))
        fail("malformed: fixture '{s}' ({s}) answered with a malformed move '{s}'", .{ f.name, f.why, o.bestmove() });
    if (!o.exited_clean)
        fail("malformed: fixture '{s}' ({s}) did not exit cleanly -- signal, abort or panic", .{ f.name, f.why });
}

pub fn runMalformed(gpa: std.mem.Allocator, io: Io, bin: []const u8) noreturn {
    const cwd = Io.Dir.cwd();

    // A missing corpus SKIPs loudly and never passes: a gate that reports OK on nothing checked
    // is worse than no gate, because it retires the question.
    cwd.access(io, "syzygy/KQvK.rtbw", .{}) catch {
        std.debug.print("malformed: SKIPPED -- no 3-man corpus in syzygy/ (run `zig build fetch-tb`)\n", .{});
        std.process.exit(0);
    };

    cwd.deleteTree(io, fixture_dir) catch {};
    cwd.createDirPath(io, fixture_dir) catch
        fail("malformed: could not create {s}/", .{fixture_dir});
    defer cwd.deleteTree(io, fixture_dir) catch {};

    var dir = cwd.openDir(io, fixture_dir, .{}) catch
        fail("malformed: could not open {s}/", .{fixture_dir});
    defer dir.close(io);

    var done: usize = 0;
    for (fixtures) |f| {
        // Start each fixture from an empty directory: a table left behind by the previous one
        // would let a REFUSED file pass on its neighbour's answer.
        for (stems) |s| {
            var buf: [64]u8 = undefined;
            const p = std.fmt.bufPrint(&buf, "{s}.rtbw", .{s.name}) catch unreachable;
            dir.deleteFile(io, p) catch {};
        }
        if (!(writeFixture(gpa, io, dir, f) catch
            fail("malformed: fixture '{s}' could not be written", .{f.name})))
        {
            std.debug.print("malformed: SKIPPED -- {s}.rtbw absent from syzygy/\n", .{f.stem});
            std.process.exit(0);
        }
        var fen: []const u8 = "";
        for (stems) |s| if (std.mem.eql(u8, s.name, f.stem)) {
            fen = s.fen;
        };
        if (fen.len == 0) fail("malformed: fixture '{s}' names an unknown stem '{s}'", .{ f.name, f.stem });
        driveFixture(gpa, io, bin, f, fen) catch
            fail("malformed: fixture '{s}' ({s}) -- the harness could not drive it", .{ f.name, f.why });
        done += 1;
    }

    std.debug.print("malformed: OK ({d} mutated tables, every one survived: clean exit + a legal bestmove)\n", .{done});
    std.process.exit(0);
}
