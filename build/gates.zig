//! Own the golden gates: the check/update step pair each one registers.
//!
//! Twenty-one gates shared one 20-line shape -- declare the golden path, add a harness run
//! in `check` mode, register a step, repeat in `update` mode -- copied out longhand, ~420
//! lines of `build()`. They are a TABLE plus one loop. zig.guide's framing of the build
//! system is the licence for that: build.zig is just Zig, so ordinary language constructs
//! (a table, a for loop) are the idiomatic answer to repetition, and Ghostty's build package
//! is the shape for where such a unit lives.
//!
//! WHAT A ROW MUST GET RIGHT. `check` is the name the parity harness dispatches on; `step`
//! is what a human types after `zig build`, and the two DIFFER for two gates (`eval` ->
//! `eval-trace`, `mt-sanity` -> `parity-mt`). `in_parity` / `in_portable` decide aggregate
//! membership; a row that silently loses a flag drops a gate from the aggregate while every
//! remaining gate stays green, which is the one failure this file can cause and the reason
//! the commit that introduced it diffed the whole 36-line gate list before and after.
//!
//! `docs_lint.sh` reads the step names from HERE, not from build.zig, and its extraction is
//! guarded against a shape change -- see that script.

const std = @import("std");

pub const GoldenGate = struct {
    /// Name the parity harness dispatches on.
    check: []const u8,
    /// Build step a human types; usually == check, deliberately not always.
    step: []const u8,
    /// Regeneration step, always `<step>-update`.
    update_step: []const u8,
    golden: []const u8,
    check_desc: []const u8,
    update_desc: []const u8,
    /// Needs the fetched 3-man Syzygy set.
    needs_tb: bool = false,
    in_parity: bool = true,
    /// Also in the OS-portable subset (no tablebases, no Linux-only fetch).
    in_portable: bool = false,
};

pub const golden = [_]GoldenGate{
    // Pin bench node counts for non-default configs (bench-matrix golden; hash size / shallow
    // depth / node limit / bench-perft) -- distinct deterministic code paths the default
    // signature (2516158) never exercises, each verified equal to the upstream oracle.
    // Keep Linux-only (`parity`, not `parity-portable`): verified bit-exact on x86 in both build
    // modes, but the node-limited config's cross-arch equality is not locally verifiable, and
    // the default bench already gates cross-OS signature. Regenerate on an upstream bump.
    .{ .check = "bench-matrix", .step = "bench-matrix", .update_step = "bench-matrix-update", .golden = "tools/bench_matrix.golden", .check_desc = "Diff non-default bench node counts (hash/depth/nodes/perft configs) against the golden", .update_desc = "Regenerate tools/bench_matrix.golden from the current binary" },
    // Pin UCI_Chess960 search + castling encoding + eval (chess960 golden). perft covers FRC
    // movegen counts; this pins FRC castling made/unmade in a real search, the played
    // king-to-rook-square castling move (f1g1 = O-O) via `d`, and the NNUE eval on FRC king
    // placements. Single-thread + node budget -> arch/OS-invariant, so the golden is portable.
    .{ .check = "chess960", .step = "chess960", .update_step = "chess960-update", .golden = "tools/chess960.golden", .check_desc = "Diff UCI_Chess960 search + castling + eval against the committed golden", .update_desc = "Regenerate tools/chess960.golden from the current binary", .in_portable = true },
    // Pin the search-manager driver + its emit callbacks bit-exact (driver-golden;
    // multipv/wdl/ponder/no-moves).
    .{ .check = "driver-golden", .step = "driver-golden", .update_step = "driver-golden-update", .golden = "tools/driver.golden", .check_desc = "Assert the search-driver + emit-callback UCI output matches the committed golden", .update_desc = "Regenerate tools/driver.golden from the current binary", .in_portable = true },
    // Pin the NNUE `eval` trace block against a golden
    // (buildNnueTrace + the network-ptr / accumulator-cache trace path) — bench covers the eval
    // value but not this formatting path.
    .{ .check = "eval", .step = "eval-trace", .update_step = "eval-trace-update", .golden = "tools/eval.golden", .check_desc = "Diff the NNUE eval trace block against the committed golden (buildNnueTrace path)", .update_desc = "Regenerate tools/eval.golden from the current binary", .in_portable = true },
    // Pin the length + FNV-1a of the net produced by `export_net` (export-net golden). The
    // serializer (write_parameters) must reproduce the canonical .nnue byte-for-byte;
    // upstream round-trips to the input net exactly, so a matching hash is a
    // differential-vs-upstream check (zfish export == oracle export == distributed net).
    // The net bytes are arch/OS-invariant, so the golden is portable. Regenerate on a net
    // bump alongside the other goldens.
    .{ .check = "export-net", .step = "export-net", .update_step = "export-net-update", .golden = "tools/export_net.golden", .check_desc = "Diff the export_net (write_parameters) net fingerprint against the committed golden", .update_desc = "Regenerate tools/export_net.golden from the current binary", .in_portable = true },
    // Pin the FEN-validation diagnostics (piece/pawn/king counts, side-to-move, castling,
    // en-passant, board length) and the terminate-on-critical-error behaviour -- byte-exact
    // with upstream's position.cpp messages. Regenerate on an upstream sync.
    .{ .check = "fen-errors", .step = "fen-errors", .update_step = "fen-errors-update", .golden = "tools/fen_errors.golden", .check_desc = "Diff the FEN-validation error diagnostics against the committed golden", .update_desc = "Regenerate tools/fen_errors.golden from the current binary", .in_portable = true },
    // Pin `go mate N` (mate golden; mate-distance search mode). Pin the reported mate DISTANCE
    // (score mate N) and the mating move+ponder across three verified forced mates (mate in
    // 1/2/3) -- a bestmove-only check would miss a wrong-distance regression. Single-thread and
    // mate-distance-deterministic, so arch/OS-invariant and portable.
    .{ .check = "mate", .step = "mate", .update_step = "mate-update", .golden = "tools/mate.golden", .check_desc = "Diff `go mate N` (mate distance + move) against the committed golden", .update_desc = "Regenerate tools/mate.golden from the current binary", .in_portable = true },
    // Gate the UCI misc commands (coverage tail): d/flip Fen+Key+Checkers — the
    // Position fen/flip/zobrist/gives_check read paths no other gate touches.
    .{ .check = "misc", .step = "misc", .update_step = "misc-update", .golden = "tools/misc.golden", .check_desc = "Diff d/flip (Fen/Key/Checkers) against the committed golden (fen/flip/zobrist/gives_check)", .update_desc = "Regenerate tools/misc.golden from the current binary", .in_portable = true },
    // Check multi-thread search sanity. Multi-threaded
    // search is non-deterministic (Lazy SMP), so this is a tolerance gate, not a
    // bit-exact golden: at fixed depth on calm positions, Threads {2,4} must emit
    // a well-formed bestmove and a score of the same kind/sign within a generous
    // cp band of the deterministic single-thread reference. Catch a runtime that
    // runs but corrupts result aggregation. Keep out of the core `parity` aggregate
    // (non-deterministic, sleep-paced).
    .{ .check = "mt-sanity", .step = "parity-mt", .update_step = "parity-mt-update", .golden = "tools/mt_sanity.golden", .check_desc = "Multi-thread search sanity: Threads {2,4} score-band vs single-thread golden", .update_desc = "Regenerate tools/mt_sanity.golden (single-thread reference)", .in_portable = true },
    // Pin the nodestime allocation (nodestime golden): `nodestime` converts wall-clock budgets into a NODE budget, so the
    // time-management allocation path is deterministic (bit-exact) rather than the reported-ms
    // band the `parity-time` gate checks. Pin depth/score/nodes/bestmove across the allocation
    // branches (sudden-death / movestogo / increment / movetime). Node budgets are
    // arch/OS-invariant, so the golden is portable.
    .{ .check = "nodestime", .step = "nodestime", .update_step = "nodestime-update", .golden = "tools/nodestime.golden", .check_desc = "Diff the nodestime time-management allocation (node budget) against the committed golden", .update_desc = "Regenerate tools/nodestime.golden from the current binary", .in_portable = true },
    // Pin the stripped bench info+bestmove text against a committed golden (the full-output
    // GOLDEN gate).
    .{ .check = "output-golden", .step = "output-golden", .update_step = "output-golden-update", .golden = "tools/output_parity.golden", .check_desc = "Assert the default (Zig) bench info-line output matches the committed golden", .update_desc = "Regenerate tools/output_parity.golden from the current binary", .in_portable = true },
    // Diff perft against a golden -- the ONLY gate over
    // do_move/undo_move + the legal movegen + the UCI move formatter (bench never runs
    // perft; search-modes only checks bestmoves), pinned against the committed golden.
    .{ .check = "perft", .step = "perft", .update_step = "perft-update", .golden = "tools/perft.golden", .check_desc = "Diff perft divide counts + totals against the committed golden (do_move/undo_move/movegen)", .update_desc = "Regenerate tools/perft.golden from the current binary", .in_portable = true },
    // Run the deterministic non-bench search-mode harness (node-limit / MultiPV /
    // searchmoves) -- validate iterative_deepening control flow beyond bench.
    .{ .check = "search-modes", .step = "search-modes", .update_step = "search-modes-update", .golden = "tools/search_modes.golden", .check_desc = "Diff deterministic non-bench search modes against the committed golden", .update_desc = "Regenerate tools/search_modes.golden from the current binary", .in_portable = true },
    // Run the per-position search-fingerprint differential harness. Localize a
    // bench-signature mismatch to a single position + drifted field.
    .{ .check = "search-parity", .step = "search-parity", .update_step = "search-parity-update", .golden = "tools/search_parity.golden", .check_desc = "Diff per-position bench search fingerprints against the committed golden", .update_desc = "Regenerate tools/search_parity.golden from the current binary", .in_portable = true },
    // Pin cursed-win / blessed-loss / 50-move (tb-cursed golden; M-SZ-5). Run LOCAL ONLY -- needs ~40 MB of
    // 5-man tables staged into resources/syzygy5/ (see buildTbCursed's comment), which the 3-man CI set
    // never contains, so this is NOT wired into `parity`. Pin WDL+DTZ of a KNNvKP cursed win
    // (+1/122) and its blessed-loss mirror (-1/-115) == the upstream oracle.
    .{ .check = "tb-cursed", .step = "tb-cursed", .update_step = "tb-cursed-update", .golden = "tools/tb_cursed.golden", .check_desc = "LOCAL: diff cursed-win/blessed-loss WDL+DTZ (needs resources/syzygy5/ 5-man tables) vs golden", .update_desc = "LOCAL: regenerate tools/tb_cursed.golden from the current binary", .in_parity = false },
    // Pin the Syzygy DTZ probe (tb-dtz golden; M-SZ-3a). Reuse the tb-wdl 3-man battery but pin the
    // `d`-command `Tablebases DTZ: N (state)` line == upstream oracle -- exercising do_probe_table
    // <DTZ>, the DTZ value map, and the CHANGE_STM 1-ply search (KQvK-btm). Keep Linux-only; needs `tb`.
    .{ .check = "tb-dtz", .step = "tb-dtz", .update_step = "tb-dtz-update", .golden = "tools/tb_dtz.golden", .check_desc = "Diff the Syzygy DTZ probe (KQvK/KPvK/... == oracle) against the golden", .update_desc = "Regenerate tools/tb_dtz.golden from the current binary", .needs_tb = true },
    // Pin the Syzygy load report (tb-init golden; M-SZ-1). Set SyzygyPath to the fetched 3-man set
    // (resources/syzygy/) and pin the `info string Found N WDL and N DTZ ... (up to M-man)` line ==
    // upstream oracle. Depend on the `tb` fetch too. Keep Linux-only (`parity`, not portable): the
    // fetched tables + libc file-check are verified on Linux; cross-OS Syzygy comes with M-SZ-4.
    .{ .check = "tb-init", .step = "tb-init", .update_step = "tb-init-update", .golden = "tools/tb_init.golden", .check_desc = "Diff the Syzygy load report (Found N WDL/DTZ, up to M-man) against the golden", .update_desc = "Regenerate tools/tb_init.golden from the current binary", .needs_tb = true },
    // Pin the Syzygy root DTZ ranking (tb-root golden; M-SZ-3b). Run `go` on TB wins and pin
    // bestmove + tbScore + tbHits == upstream oracle, first-validating rankRootMovesDtz end to end.
    .{ .check = "tb-root", .step = "tb-root", .update_step = "tb-root-update", .golden = "tools/tb_root.golden", .check_desc = "Diff the Syzygy root DTZ ranking (bestmove/score/tbhits == oracle) against the golden", .update_desc = "Regenerate tools/tb_root.golden from the current binary", .needs_tb = true },
    // Pin the in-search Step 6 WDL probe (tb-search golden; M-SZ-4). Bench a 4-man EPD; the node
    // count with Step 6 on (SyzygyPath set) and off both pin == upstream oracle -- bit-exact
    // node-count parity that the in-tree probe shapes. Keep Linux-only; depend on the `tb` fetch.
    .{ .check = "tb-search", .step = "tb-search", .update_step = "tb-search-update", .golden = "tools/tb_search.golden", .check_desc = "Diff the in-search Step 6 node count (with/without TB == oracle) against the golden", .update_desc = "Regenerate tools/tb_search.golden from the current binary", .needs_tb = true },
    // Pin the Syzygy WDL probe (tb-wdl golden; M-SZ-2c). Set SyzygyPath to resources/syzygy and pin the
    // `d`-command `Tablebases WDL: N (state)` line == upstream oracle for a curated 3-man battery
    // (all five piece types, win/loss/draw, wtm/btm, pawn + blackStronger flips, and the
    // search<false> capture recursion). Keep Linux-only (like tb-init); depend on the `tb` fetch.
    .{ .check = "tb-wdl", .step = "tb-wdl", .update_step = "tb-wdl-update", .golden = "tools/tb_wdl.golden", .check_desc = "Diff the Syzygy WDL probe (KQvK/KPvK/... == oracle) against the golden", .update_desc = "Regenerate tools/tb_wdl.golden from the current binary", .needs_tb = true },
    // Pin the `uci` handshake `option name ...` lines (uci-options golden; the GUI compatibility
    // surface). Pin only the option lines -- the id name / author + banner carry the
    // git sha/date and are volatile. Defaults/min/max are static constants (machine-invariant),
    // so the golden is portable; EvalFile's default is the net name, regenerated on a net bump.
    .{ .check = "uci-options", .step = "uci-options", .update_step = "uci-options-update", .golden = "tools/uci_options.golden", .check_desc = "Diff the `uci` option-list handshake against the committed golden", .update_desc = "Regenerate tools/uci_options.golden from the current binary", .in_portable = true },
};

/// Build the harness argv as `<check> <engine binary> <golden-or-expected> <mode>`, run from
/// resources/ (the net and the fetched tablebases resolve from there and nowhere else).
/// Public because `signature` uses it too, and it is not a golden-gate row: it has no update
/// mode -- the anchor is a number in build.zig, not a file to regenerate.
pub fn addHarnessRun(
    b: *std.Build,
    harness: *std.Build.Step.Compile,
    stockfish: *std.Build.Step.Compile,
    install_step: *std.Build.Step,
    net_step: *std.Build.Step,
    check_name: []const u8,
    golden_or_expected: []const u8,
    mode: []const u8,
) *std.Build.Step.Run {
    const run = b.addRunArtifact(harness);
    run.addArg(check_name);
    run.addArtifactArg(stockfish);
    run.addArgs(&.{ golden_or_expected, mode });
    run.setCwd(b.path("resources"));
    run.step.dependOn(install_step);
    run.step.dependOn(net_step);
    return run;
}

pub const Context = struct {
    b: *std.Build,
    harness: *std.Build.Step.Compile,
    stockfish: *std.Build.Step.Compile,
    install_step: *std.Build.Step,
    net_step: *std.Build.Step,
    /// The 3-man Syzygy fetch, depended on only by rows that set `needs_tb`.
    tb_step: *std.Build.Step,
    /// Absolute path for `tools/<x>.golden`, supplied by build.zig's repoPath.
    goldenPath: *const fn (*std.Build, []const u8) []const u8,
};

/// Register both steps for every row and return check-name -> the CHECK run, which is what
/// the aggregates wire themselves onto.
pub fn register(ctx: Context) std.StringHashMap(*std.Build.Step.Run) {
    var runs = std.StringHashMap(*std.Build.Step.Run).init(ctx.b.allocator);
    for (golden) |g| {
        const path = ctx.goldenPath(ctx.b, g.golden);

        const check_cmd = addHarnessRun(ctx.b, ctx.harness, ctx.stockfish, ctx.install_step, ctx.net_step, g.check, path, "check");
        if (g.needs_tb) check_cmd.step.dependOn(ctx.tb_step);
        const check_step = ctx.b.step(g.step, g.check_desc);
        check_step.dependOn(&check_cmd.step);

        const update_cmd = addHarnessRun(ctx.b, ctx.harness, ctx.stockfish, ctx.install_step, ctx.net_step, g.check, path, "update");
        if (g.needs_tb) update_cmd.step.dependOn(ctx.tb_step);
        const update_step = ctx.b.step(g.update_step, g.update_desc);
        update_step.dependOn(&update_cmd.step);

        runs.put(g.check, check_cmd) catch @panic("OOM registering golden gates");
    }
    return runs;
}
