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

// Require the parse-then-probe chain to refuse or answer, never to trap. The verdict is
// unconstrained -- a table built out of fuzzer bytes decodes to nonsense -- so the property is
// only that every index the chain takes stays inside what the file provided.
// Parse one image into a registered table, publish it, and probe -- the body both the fuzz target
// and the coverage test below run. `image` must be 64-aligned: loadFile hands `set` a 64-aligned
// base and the data-section rounding in `set` is written against that.
fn runOne(image: *const [1024]u8) ProbeResult {
    const cfg = configs[image[0] % configs.len];
    const len = 16 + (@as(usize, image[1]) % (image.len - 16));

    registry.reset(""); // fresh arena and table map; no path, so nothing is ever opened
    registry.register(cfg.pieces);
    const t = registry.hashGet(materialKey(cfg.pieces)) orelse
        return .{ .available = 0, .wdl = 0, .wdl_state = 0, .dtz = 0, .dtz_state = 0 };

    // Keep the magic: the probe never reaches a decoder without it, and a fuzzer that has to
    // rediscover four constant bytes spends its whole budget there.
    var wdl_image align(64) = image.*;
    @memcpy(wdl_image[0..4], &registry.wdl_magic);
    var dtz_image align(64) = image.*;
    @memcpy(dtz_image[0..4], &registry.dtz_magic);

    // Publish exactly as mapped()/mappedDtz() do: base only when the parse accepted the file, and
    // `ready` either way, so the probe treats a refused table as a missing one.
    if (table_load.set(t, false, wdl_image[0..len])) t.base = wdl_image[0..len];
    t.ready = true;
    if (table_load.set(t, true, dtz_image[0..len])) t.dtz_base = dtz_image[0..len];
    t.dtz_ready = true;

    return wdl.probeFen(cfg.fen.ptr, cfg.fen.len, 0);
}

// Require the parse-then-probe chain to refuse or answer, never to trap. The verdict is
// unconstrained -- a table built out of fuzzer bytes decodes to nonsense -- so the property is
// only that every index the chain takes stays inside what the file provided.
fn fuzzProbeTable(_: void, smith: *std.testing.Smith) anyerror!void {
    var image: [1024]u8 align(64) = undefined;
    smith.bytesWithHash(&image, 2);

    // The probe generates moves, so the slider magics and leaper tables have to exist. The shipped
    // binary builds them at startup; a test root has no startup, and without this the first
    // generateLegal reads an unbuilt table and segfaults rather than reporting anything.
    position.initRuntime();

    _ = runOne(&image);
}

test "fuzz: a table built from arbitrary bytes probes without trapping" {
    try std.testing.fuzz({}, fuzzProbeTable, .{});
}

// Assert the accepted path RUNS, not only that nothing trapped.
//
// A fuzz target whose every input is REFUSED at the header still exits 0, and reads exactly like
// one that exercised the decoder -- the failure mode this repository has already paid for once. So
// sweep a fixed pseudo-random batch through the same body and require that a good fraction of it
// parses AND probes: that is the half where an accepted-but-inconsistent header meets
// doProbeTable, which is the whole reason this target exists.
test "the parse-then-probe path is reached, not just the refusals" {
    position.initRuntime();
    var prng = std.Random.DefaultPrng.init(0x5F17_D622);
    const rand = prng.random();
    var probed: usize = 0;
    const rounds = 4000;
    for (0..rounds) |_| {
        var image: [1024]u8 align(64) = undefined;
        rand.bytes(&image);
        if (runOne(&image).available != 0) probed += 1;
    }
    // Random bytes clear the header's own length checks about 4% of the time; require a tenth of
    // that, so the assertion pins "the path runs" without pinning a rate the parse may move.
    try std.testing.expect(probed > rounds / 250);
}
