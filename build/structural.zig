//! Own the gates that are "run a shell script and check its exit code".
//!
//! Six of them shared one shape -- addSystemCommand(bash, tools/x.sh), optionally hand it
//! the engine binary, optionally set a cwd or one env var, register a step -- written out
//! longhand in `build()`. Same reasoning as build/gates.zig: a table plus one loop, because
//! build.zig is just Zig and twenty lines repeated seven times is data wearing code.
//!
//! The four axes are exactly what the seven differ by, and nothing more: whether the script
//! needs the built engine (artifact arg + install + net dependency), whether it must run from
//! resources/ (where the net and the fetched tablebases resolve), and whether it takes one
//! ratchet baseline through the environment. A gate needing a fifth axis does not belong in
//! this table -- add it to build.zig longhand rather than growing an option nobody reads.
//!
//! `upstream-parity` is the worked example of that rule and the reason it is written down.
//! It looked like a seventh row and is not: it passes the upstream base sha as a SECOND
//! argument, which no other gate does. Table-driving it silently dropped that argument --
//! the script would still have run, and still exited 0, against the wrong base. It stays
//! longhand in build.zig.

const std = @import("std");

pub const ScriptGate = struct {
    step: []const u8,
    script: []const u8,
    desc: []const u8,
    /// Pass the engine binary and depend on install + the net fetch.
    needs_engine: bool = false,
    /// Run from resources/ -- required for anything that loads the net.
    cwd_resources: bool = false,
    env_name: ?[]const u8 = null,
    env_value: ?[]const u8 = null,
    in_parity: bool = false,
    in_portable: bool = false,
};

pub const script_gates = [_]ScriptGate{
    // Gate memory errors / leaks: run Valgrind memcheck
    // over short multi-thread sessions, asserting no invalid access / bad free /
    // definite leak (uninit-value checking off -- NNUE SIMD makes it false-noisy).
    // Provide the ASan/LSan-equivalent net for the Worker/large-page lifecycle. Keep out of the
    // core `parity` aggregate (slow).
    .{ .step = "parity-valgrind", .script = "tools/valgrind.sh", .desc = "Valgrind memcheck (leak / invalid-access / bad-free) across thread counts", .needs_engine = true, .cwd_resources = true },
    // Gate leaks for the searchmoves / rootMoves vector lifecycle:
    // run Valgrind memcheck over a `go searchmoves` + ucinewgame churn, asserting no
    // definite leak / bad free of limits.searchmoves and worker.rootMoves -- the
    // path bench never exercises. Read the verdict from valgrind's summary and
    // tolerate the known post-exit thread-join hang under memcheck. Keep out of the
    // core `parity` aggregate (slow).
    .{ .step = "parity-teardown", .script = "tools/teardown.sh", .desc = "Valgrind leak gate for searchmoves/rootMoves vector lifecycle + Worker clear", .needs_engine = true, .cwd_resources = true },
    // Assert via the src-free / TU=0 structural gate that the
    // shipped binary contains zero C++ TUs (no Stockfish:: / libc++ runtime symbols) and still
    // benches 2508687. Keep it a permanent invariant in the `parity` aggregate below, guarding
    // against any C++ TU being reintroduced into the default binary.
    .{ .step = "src-free", .script = "tools/src_free.sh", .desc = "src-free structural gate: zero C++ Stockfish/libc++ symbols in the shipped binary", .needs_engine = true, .cwd_resources = true, .in_parity = true },
    // Gate the headless engine structurally: src/engine/ must import only engine/ modules,
    // never platform/ or shell/. The seams are injected one at a time, so the up-edge
    // count only ratchets down; the baseline is the currently-allowed maximum and the
    // gate fails if the real count exceeds it. Lower it as each seam is severed; at 0
    // the engine is a standalone search+eval library.
    .{ .step = "headless", .script = "tools/headless_lint.sh", .desc = "headless-engine structural gate: engine/ imports only engine/ (ratchets to 0)", .env_name = "HEADLESS_BASELINE", .env_value = "0", .in_parity = true },
    // Gate god-files structurally: ratchet on the count of .zig files >= 500 lines across ALL
    // repo-owned code (src/ + build.zig + tools/), so the "no god-files" property is enforced
    // repo-wide, not just claimed. An earlier src/-only scan was blind to the two largest files,
    // build.zig and tools/parity_harness.zig -- the build script and the gate driver. build.zig
    // has since come under the line: its module graph, ISA table, gate tables, checks and test
    // artifacts moved into the build/ package, and the baseline ratcheted 2 -> 1 rather than
    // being waived. tools/parity_harness.zig is the one left, waived at
    // baseline 2 -- but a THIRD (or growth of a smaller file past the line) fails the gate. Two
    // earlier splits ratcheted this down: syzygy/wdl.zig 832 -> wdl 490 + registry 371, and
    // shell/engine.zig 505 -> the engine.zig face (116) + engine/session.zig driver (413).
    .{ .step = "loc", .script = "tools/loc_lint.sh", .desc = "god-file structural gate: no new .zig file >= 500 lines (ratchets down)", .env_name = "LOC_BASELINE", .env_value = "1", .in_parity = true },
    // Gate docs/ against the tree it describes. Docs are accurate when written and rot where
    // the code moves under them: a hostile audit found a path pointing at a split-away module,
    // the bench anchor quoted as 2067208 in five places while build.zig said otherwise, and link
    // targets that broke on a renumber. All three are mechanical, and all three shipped because
    // nothing checked. This does NOT check whether a sentence is true -- "numa_context is a
    // never-dereferenced stub handle" parsed, linked, and was false for weeks; only reading the
    // code finds that. It buys the cheap half so review can spend attention on the expensive half.
    .{ .step = "docs-lint", .script = "tools/docs_lint.sh", .desc = "docs rot gate: every link resolves, every named src/tools path exists, the bench anchor matches build.zig", .in_parity = true },
};

pub const Context = struct {
    b: *std.Build,
    stockfish: *std.Build.Step.Compile,
    install_step: *std.Build.Step,
    net_step: *std.Build.Step,
    repoPath: *const fn (*std.Build, []const u8) []const u8,
};

/// Register every script gate; return step-name -> its run, for the aggregates to wire.
pub fn register(ctx: Context) std.StringHashMap(*std.Build.Step.Run) {
    var runs = std.StringHashMap(*std.Build.Step.Run).init(ctx.b.allocator);
    for (script_gates) |g| {
        const cmd = ctx.b.addSystemCommand(&.{ "bash", ctx.repoPath(ctx.b, g.script) });
        if (g.needs_engine) {
            cmd.addArtifactArg(ctx.stockfish);
            cmd.step.dependOn(ctx.install_step);
            cmd.step.dependOn(ctx.net_step);
        }
        if (g.cwd_resources) cmd.setCwd(ctx.b.path("resources"));
        if (g.env_name) |n| cmd.setEnvironmentVariable(n, g.env_value.?);
        const step = ctx.b.step(g.step, g.desc);
        step.dependOn(&cmd.step);
        runs.put(g.step, cmd) catch @panic("OOM registering script gates");
    }
    return runs;
}

/// A lint written in Zig rather than bash: build it for the HOST and run it from the repo
/// root. Both are built .Debug on purpose -- they run in ~0.03s so the optimizer buys
/// nothing, while Debug's checking allocator catches allocator misuse in every lane. Built
/// ReleaseFast, arch_report once shipped a size-mismatched double free that Linux and
/// Windows tolerated silently and macOS trapped on, AFTER printing "OK".
pub const LintTool = struct {
    step: []const u8,
    source: []const u8,
    desc: []const u8,
    in_parity: bool = true,
    in_portable: bool = false,
};

pub const lint_tools = [_]LintTool{
    // Run the cycle-break mechanism's ratchet + classifier (hook-lint; G2).
    // The module DAG is a DESIGN outcome, not a language guarantee -- Zig compiles and
    // runs import cycles at both granularities -- and it is bought with 30 function-
    // pointer hooks. Nothing counted them, recorded which fail loud vs answer silently,
    // or noticed a hook the composition root forgot to register. The last is the one
    // that matters: an unregistered hook does not crash, it ANSWERS, so a wiring bug
    // ships as a wrong bench rather than a signal. Run it as a source lint (no engine needed), so
    // it runs on the host and joins the portable aggregate.
    // Choose .Debug on purpose: these lints run in ~0.03s, so the optimizer buys nothing --
    // but Debug's checking allocator catches allocator misuse in EVERY lane. Built
    // ReleaseFast, arch_report shipped a size-mismatched double free that Linux and
    // Windows tolerated silently and macOS trapped on, AFTER printing "OK". A lint that
    // corrupts the heap while reporting success is worse than no lint.
    .{ .step = "hook-lint", .source = "tools/hook_lint.zig", .desc = "Cycle-break hooks: ratcheted, each declaring a failure mode + class, all registered", .in_portable = true },
    // Report Lakos coupling at BOTH granularities + the two tripwires the
    // compiler will not give (arch-report; G1). REPORT the numbers, never gate them -- Lakos's
    // NCCD ~1.0 assumes cycles cost compile time, and zfish compiles as one LLVM
    // module where they cost nothing measurable. The GATEABLE properties are binary:
    // the module graph is a DAG (Zig permits cycles -- spike), and every file SCC is
    // a declared component. Report unused declared edges, do not gate them.
    // Choose .Debug: see hook_lint_exe above -- the checking allocator is the point.
    .{ .step = "arch-report", .source = "tools/arch_report.zig", .desc = "Coupling report (module + file graphs) + DAG / undeclared-SCC tripwires", .in_portable = true },
};

/// Register the Zig lint tools; return step-name -> run.
pub fn registerLints(b: *std.Build) std.StringHashMap(*std.Build.Step.Run) {
    var runs = std.StringHashMap(*std.Build.Step.Run).init(b.allocator);
    for (lint_tools) |t| {
        const exe = b.addExecutable(.{
            .name = std.fs.path.stem(t.source),
            .root_module = b.createModule(.{
                .root_source_file = b.path(t.source),
                .target = b.graph.host,
                .optimize = .Debug,
            }),
        });
        const cmd = b.addRunArtifact(exe);
        cmd.setCwd(b.path("."));
        const step = b.step(t.step, t.desc);
        step.dependOn(&cmd.step);
        runs.put(t.step, cmd) catch @panic("OOM registering lint tools");
    }
    return runs;
}

/// Register the two upstream-differential gates. NOT rows in either table above: the map
/// audit takes a ratchet baseline path AND an exceptions file, and the walk builds its
/// argv from a caller-supplied option string in a loop. Both are bespoke argument shapes,
/// which is exactly the case the ScriptGate header says to keep longhand rather than grow
/// an axis for -- so they are a function, not data.
pub fn registerUpstream(
    b: *std.Build,
    install_step: *std.Build.Step,
    net_step: *std.Build.Step,
    walk_args: ?[]const u8,
    repoPath: *const fn (*std.Build, []const u8) []const u8,
) void {
    // Audit the upstream blast-radius map against the comment-derived correspondence
    // (rot = declared owner missing from the tree; drift is advisory) and ratchet the
    // uncovered-surface count (baseline in tools/upstream/upstream_map.baseline --
    // lower it as citations are added, never raise it). Not in the parity aggregate:
    // it reads the pinned upstream tree from git objects a plain CI checkout of
    // origin does not carry. The weekly upstream-check workflow runs it after
    // fetching the upstream remote, which brings those objects in.
    const upstream_map_cmd = b.addSystemCommand(&.{
        "python3",
        repoPath(b, "tools/upstream_map_derive.py"),
        "--audit",
    });
    const upstream_map_step = b.step(
        "upstream-map",
        "upstream map gate: declared-map rot fails, uncovered surface ratcheted",
    );
    upstream_map_step.dependOn(&upstream_map_cmd.step);

    // Diff node counts against the pristine oracle over a RANDOM WALK from the start
    // position, per depth. The bench anchor covers a fixed position list, so a port can
    // be nudged toward that number without becoming faithful; `upstream_nodes.sh` narrows
    // that hole but only over a FEN suite it is handed. This closes it by reaching
    // positions that appear in no bench list, no golden and no test. Outside the parity
    // aggregate for the same reason as upstream-map -- it needs the pinned upstream tree,
    // and it builds the oracle. Depend on the exe and the net: it drives the built binary
    // from resources/.
    // Take the tool's flags through a -D option rather than `zig build ... -- args`:
    // `b.args` is a 0.16 field that Zig master removed, and the passthrough has no
    // cross-version spelling. A -D option behaves identically on both compilers and
    // `zig build --help` lists it, where `--` args are invisible.
    const upstream_walk_cmd = b.addSystemCommand(&.{
        "python3",
        repoPath(b, "tools/upstream_walk.py"),
    });
    if (walk_args) |wa| {
        var it = std.mem.tokenizeScalar(u8, wa, ' ');
        while (it.next()) |tok| upstream_walk_cmd.addArg(tok);
    }
    upstream_walk_cmd.step.dependOn(install_step);
    upstream_walk_cmd.step.dependOn(net_step);
    const upstream_walk_step = b.step(
        "upstream-walk",
        "upstream random-walk gate: node counts == pristine oracle, per depth, on unchosen positions",
    );
    upstream_walk_step.dependOn(&upstream_walk_cmd.step);
}
