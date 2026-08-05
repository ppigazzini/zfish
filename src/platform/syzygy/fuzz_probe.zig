// Fuzz the Syzygy table parse END TO END: the header, the group set-up, the index arithmetic
// and both decoders, driven the way a probe drives them.
//
// fuzz_targets.zig fuzzes setSizes and decompressPairs as units, and that is the wrong shape for
// half the bugs: an accepted header can still leave an invariant the PROBE relies on unmet, and no
// unit-level target can see it. The lead-pawn refusal in table_load.set is exactly that -- a header
// every unit target accepts, and a probe that then sorts an inverted range and indexes the pawn
// geometry with a square nobody wrote. ../rfish found the same bug from the same direction
// (afd72af) and neither port's unit targets had.
//
// Reach the probe WITHOUT touching a filesystem: registry.register builds the TBTable the material
// configuration implies, table_load.set parses a fuzzer-built image into it, and publishing
// `base`/`ready` by hand makes `mapped` a no-op -- so `probeFen` runs the real doProbeTable over a
// real parsed table without a `.rtbw` anywhere. That also keeps the target fixture-free, which
// matters: a fuzz target guarded on resources/ that are not there SKIPS silently, and a silent skip
// reads exactly like a clean run.
//
// Build under ReleaseSafe (the `fuzz` step does) so an index the shipped ReleaseFast build would
// simply follow trips a safety check here instead.

const std = @import("std");

const decode = @import("decode.zig");
const registry = @import("registry.zig");
const table_load = @import("table_load.zig");
const wdl = @import("wdl.zig");
const board_core = @import("board_core");
const position = @import("position");
const ProbeResult = @import("tb_source").ProbeResult;

const pawn_pt = board_core.pawn_pt;
const knight_pt = board_core.knight_pt;
const queen_pt = board_core.queen_pt;
const king_pt = board_core.king_pt;

// Pair each material configuration with a position OF that material: the probe looks the key up,
// and a position that misses returns before reading a byte. Cover the four shapes the parse
// branches on -- pieces only, one leading pawn, several leading pawns, and pawns on BOTH sides
// (`pp`, which is what routes a second group through the `order[1]` arm and reads a second order
// nibble per file).
const configs = [_]struct { pieces: []const u8, fen: []const u8 }{
    .{ .pieces = &.{ king_pt, queen_pt, king_pt }, .fen = "8/8/8/4k3/8/8/8/K5Q1 w - - 0 1" },
    .{ .pieces = &.{ king_pt, pawn_pt, king_pt }, .fen = "8/8/8/4k3/8/8/4P3/K7 w - - 0 1" },
    .{ .pieces = &.{ king_pt, pawn_pt, pawn_pt, king_pt }, .fen = "8/8/8/4k3/8/8/3PP3/K7 w - - 0 1" },
    .{ .pieces = &.{ king_pt, pawn_pt, king_pt, pawn_pt }, .fen = "8/4p3/8/4k3/8/8/4P3/K7 w - - 0 1" },
    .{ .pieces = &.{ king_pt, knight_pt, king_pt, pawn_pt }, .fen = "8/4p3/8/4k3/8/2N5/8/K7 w - - 0 1" },
};

// Compute the material key registry.register files the table under, from the same per-color counts.
fn materialKey(pieces: []const u8) u64 {
    var k2: usize = 1;
    while (k2 < pieces.len and pieces[k2] != king_pt) k2 += 1;
    var counts: [16]i32 = @splat(0);
    for (pieces[0..k2]) |pt| counts[pt] += 1;
    for (pieces[k2..]) |pt| counts[@as(usize, pt) | 8] += 1;
    return position.computeMaterialKey(&counts, 16);
}

// Report the PARSE's verdict beside the probe's. A test that counts only answers cannot tell "the
// parse refused every image" from "the parse accepted and the probe then refused the value it
// decoded" -- and since a table built from arbitrary bytes decodes a legitimate WDL score only
// rarely, those two want different assertions below.
const Run = struct { result: ProbeResult, parsed: bool };

// Parse one image into a registered table, publish it, and probe -- the body both the fuzz target
// and the coverage test below run. `image` must be 64-aligned: loadFile hands `set` a 64-aligned
// base and the data-section rounding in `set` is written against that.
fn runOne(image: *const [1024]u8) Run {
    const cfg = configs[image[0] % configs.len];
    const len = 16 + (@as(usize, image[1]) % (image.len - 16));

    registry.reset(""); // fresh arena and table map; no path, so nothing is ever opened
    registry.register(cfg.pieces);
    const t = registry.hashGet(materialKey(cfg.pieces)) orelse
        return .{ .result = .{ .available = 0, .wdl = 0, .wdl_state = 0, .dtz = 0, .dtz_state = 0 }, .parsed = false };

    // Keep the magic: the probe never reaches a decoder without it, and a fuzzer that has to
    // rediscover four constant bytes spends its whole budget there.
    var wdl_image align(64) = image.*;
    @memcpy(wdl_image[0..4], &registry.wdl_magic);
    var dtz_image align(64) = image.*;
    @memcpy(dtz_image[0..4], &registry.dtz_magic);

    // Publish exactly as mapped()/mappedDtz() do: base only when the parse accepted the file, and
    // `ready` either way, so the probe treats a refused table as a missing one.
    const parsed = table_load.set(t, false, wdl_image[0..len]);
    if (parsed) t.base = wdl_image[0..len];
    t.ready = true;
    if (table_load.set(t, true, dtz_image[0..len])) t.dtz_base = dtz_image[0..len];
    t.dtz_ready = true;

    return .{ .result = wdl.probeFen(cfg.fen.ptr, cfg.fen.len, 0), .parsed = parsed };
}

// Require the parse-then-probe chain to refuse or answer, never to trap. The verdict is
// unconstrained -- a table built out of fuzzer bytes decodes to nonsense -- so the property is
// only that every index the chain takes stays inside what the file provided.
fn fuzzProbeTable(_: void, smith: *std.testing.Smith) anyerror!void {
    var image: [1024]u8 align(64) = undefined;
    smith.bytesWithHash(&image, 2);

    _ = runOne(&image);
}

test "fuzz: a table built from arbitrary bytes probes without trapping" {
    // The probe generates moves, so the slider magics and leaper tables have to exist. The shipped
    // binary builds them at startup; a test root has no startup, and without this the first
    // generateLegal reads an unbuilt table and segfaults rather than reporting anything.
    //
    // Build them ONCE, here, not per input. They are read-only afterwards, so a per-input
    // rebuild costs three orders of magnitude -- 91 inputs/sec against 220k/sec -- which puts
    // this target under the nightly's per-artifact execution floor and stops it fuzzing in any
    // sense the gate can use. Every fuzz root in this tree hoists it the same way.
    position.initRuntime();
    try std.testing.fuzz({}, fuzzProbeTable, .{});
}

// Assert the accepted path RUNS, not only that nothing trapped.
//
// A fuzz target whose every input is REFUSED at the header still exits 0, and reads exactly like
// one that exercised the decoder -- the failure mode this repository has already paid for once. So
// sweep a fixed pseudo-random batch through the same body and require that a good fraction of it
// PARSES, which is where an accepted-but-inconsistent header meets doProbeTable and the whole
// reason this target exists, and that the probe still ANSWERS at least once. Count those two
// separately: they differ by two orders of magnitude, so one number cannot gate both.
test "the parse-then-probe path is reached, not just the refusals" {
    position.initRuntime();
    var prng = std.Random.DefaultPrng.init(0x5F17_D622);
    const rand = prng.random();
    var parsed: usize = 0;
    var probed: usize = 0;
    const rounds = 4000;
    for (0..rounds) |_| {
        var image: [1024]u8 align(64) = undefined;
        rand.bytes(&image);
        const r = runOne(&image);
        if (r.parsed) parsed += 1;
        if (r.result.available != 0) {
            probed += 1;
            // Hold the answered score to the five outcomes a WDL file can hold. The probe reports
            // this value AND indexes with it, so a table that invents one is a trap downstream,
            // not merely a wrong answer -- see the regression below.
            try std.testing.expect(r.result.wdl >= -2 and r.result.wdl <= 2);
        }
    }
    // Random bytes clear the header's own length checks about 4% of the time (172 of 4000 here);
    // require a tenth of that, so the assertion pins "the path runs" without pinning a rate the
    // parse may move.
    try std.testing.expect(parsed > rounds / 250);
    // ANSWERING is far rarer than parsing, and deliberately so: an accepted header still has to
    // decode a value inside the five a WDL file can hold, which arbitrary bytes rarely do (3 of
    // 4000 here). Require only that it still happens -- a floor near the measured count would
    // pin a rate the decoder is free to move, while zero would mean the probe's answering half
    // had gone dark behind a green sweep.
    try std.testing.expect(probed > 0);
}

// Pin the one bound the sweep above cannot reach on purpose: the WDL score's DOMAIN.
//
// do_probe_table<WDL> returns "the decoded value minus 2", and setSizes' SingleValue branch
// returns a raw header byte AS that value -- so a corrupt file could hand the probe a "WDL score"
// of 253, which probeDtz then fed to wdl_map[wdl + 2], five entries wide. The fuzz target above
// found it on the nightly lane; drive the same shape deterministically here rather than wait for
// a mutation to rediscover it. Reach it without a file: register the table, publish a WDL
// PairsData that is SingleValue over an impossible byte, and probe.
test "a WDL value no file can hold is refused, not handed on as a score" {
    position.initRuntime();
    const cfg = configs[0]; // KQvK -- pawnless, so the index walk reaches the decoder off a bare table

    registry.reset("");
    registry.register(cfg.pieces);
    const t = registry.hashGet(materialKey(cfg.pieces)) orelse return error.TableNotRegistered;

    for (0..t.sides) |side| {
        const d = t.get(false, side, .ah);
        d.flags = decode.flag_single_value;
        d.min_sym_len = 200; // decompressPairs returns this verbatim, as the stored value
    }
    // Publish the WDL half only. Leaving dtz_base null keeps the DTZ probe out of it, so the
    // refusal under test has to be the WDL one.
    var image: [64]u8 align(64) = @splat(0);
    t.base = image[0..];
    t.ready = true;
    t.dtz_ready = true;

    const r = wdl.probeFen(cfg.fen.ptr, cfg.fen.len, 0);
    try std.testing.expectEqual(@as(u8, 0), r.available);
}
