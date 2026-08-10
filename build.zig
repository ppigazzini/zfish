const std = @import("std");
// One import for the whole build package (build/main.zig re-exports it), so the
// package can be reorganised without touching this list.
const buildpkg = @import("build/main.zig");
// Shared by the few test artifacts still wired here and by build/tests.zig.
const addTestRun = buildpkg.tests.addTestRun;
// One definition, in build/gates.zig -- build.zig kept a byte-identical copy after the
// gate table moved, which is how two implementations of one helper start.
const addHarnessRun = buildpkg.gates.addHarnessRun;
const repoPath = buildpkg.config.repoPath;
const graph = buildpkg.modules;
const arch_cfg = buildpkg.arch;
const Macro = arch_cfg.Macro;
const ArchConfig = arch_cfg.ArchConfig;
const applyMacros = arch_cfg.applyMacros;
const resolveArch = arch_cfg.resolveArch;
const archConfigFor = arch_cfg.archConfigFor;
const hasMacro = arch_cfg.hasMacro;
const native_arch = arch_cfg.native_arch;

// Enumerate the owned runtime OSes. Select with -Dos=; each maps to an (os_tag, abi) pair
// in build(). Keep orthogonal to -Darch= (the ISA tier), so any arch tier can target any OS.
const TargetOs = enum { linux, windows, macos };

const GitInfo = struct {
    sha: ?[]const u8,
    date: ?[]const u8,
};

pub fn build(b: *std.Build) void {
    // Resolve every -D option, the ISA tier and the target (build/config.zig) before any
    // module or step exists.
    const cfg = buildpkg.config.resolve(b);
    const optimize = cfg.optimize;
    const target = cfg.target;
    const arch = cfg.arch;
    const os_choice = cfg.os_choice;
    const os_tag = cfg.os_tag;
    const git_info = cfg.git_info;
    const signature_ref = cfg.signature_ref;
    const walk_args = cfg.walk_args;
    const build_options_module = cfg.build_options_module;
    // Coverage bookkeeping stays in build(): every test artifact registered here and in
    // build/tests.zig shares the one counter, so each kcov run gets its own output dir.
    // Run each unit-test binary under kcov when `-Dtest-coverage` is set, merging line coverage
    // into ./kcov-out (one subdir per test artifact -> no parallel-write race). kcov
    // instruments the ELF at runtime, so no coverage rebuild flags are needed; default off
    // (every normal `zig build test` runs the artifact directly, unchanged). CI installs kcov,
    // merges the subdirs, and uploads the report. See addTestRun.
    const test_coverage = b.option(
        bool,
        "test-coverage",
        "Run the unit tests under kcov, merging line coverage into ./kcov-out (needs kcov on PATH)",
    ) orelse false;
    const cov_dir: ?[]const u8 = if (test_coverage) "kcov-out" else null;
    var cov_idx: usize = 0;

    // Model the module graph as data. Both tables -- the {name, path} specs and the import
    // edges -- live in build/modules.zig: they are pure data, they were ~480 lines of this
    // function, and two tools parse them as text (see that file's header before reshaping
    // either literal).
    const module_specs = graph.specs;
    var mods = std.StringHashMap(*std.Build.Module).init(b.allocator);
    for (module_specs) |spec| {
        mods.put(spec.name, b.createModule(.{
            .root_source_file = b.path(spec.path),
            .target = target,
            .optimize = optimize,
        })) catch @panic("OOM building module graph");
    }
    // Publish build_options through the same map the modules live in, so the standalone test
    // roots pick it up from one place. Adding it imperatively to the exe only is what left
    // `move_do` and `nnue_accumulator`'s own test roots without it.
    mods.put("build_options", build_options_module) catch @panic("OOM building module graph");

    const module_edges = graph.edges;
    // Name the edge rather than unwrapping blind: both ends are strings in a 380-row table, so a
    // typo is a panic with no operand unless the message carries one.
    for (module_edges) |e| {
        const from = mods.get(e.from) orelse std.debug.panic("module edge names unknown module '{s}'", .{e.from});
        const to = mods.get(e.to) orelse std.debug.panic("module edge '{s}' names unknown module '{s}'", .{ e.from, e.to });
        from.addImport(e.imp, to);
    }
    mods.get("misc").?.addImport("build_options", build_options_module);
    // search_acc reads build_options.stub_eval to swap the NNUE forward pass for the material
    // stub at comptime (spine isolation, tools/material_eval.sh). Default false, so the shipped
    // build resolves the branch away and is unchanged.
    mods.get("search_acc").?.addImport("build_options", build_options_module);
    // The two accumulator ablations (-Dacc-refresh-only, -Dno-threat-record) are read at
    // comptime by the update core and by do_move's recording, so both modules need the
    // options. Default false on each, so the shipped build resolves the branch away.
    mods.get("nnue_accumulator").?.addImport("build_options", build_options_module);
    mods.get("move_do").?.addImport("build_options", build_options_module);

    // Match upstream's codegen: its Makefile compiles `build` with -flto=full (Makefile:965)
    // while zfish shipped without it, so the two were never compiled alike. Measured on an
    // identical 178,029-node tree, bit-exact (bench stays 2884956): 4,065,662,391 ->
    // 3,922,860,311 instructions, -3.51%, which is 22% of the whole instruction gap against
    // upstream -- from a flag, not code.
    //
    // Default ON for Linux, OFF elsewhere, because the Zig 0.16 toolchain cannot link it
    // on the other owned targets -- not a zfish limit, and not fixable from here:
    //   -Dos=macos            "LTO requires using LLD", and forcing use_lld then gives
    //                         "using LLD to link macho files is unsupported". Both paths refuse.
    //   -Dos=windows          mingw long-double math is unresolved under LTO (frexpl, atanl,
    //                         copysignl, __isnanl ...), 39 undefined symbols.
    // Linux is where every gate and the CI parity lane run, so it gets the win; the
    // cross-targets keep linking. -Dlto=false/true overrides either way.
    const lto_default = os_choice == .linux;
    const want_lto = b.option(bool, "lto", "Link-time optimization (-flto=full, matching upstream). Default on for Linux; the macos/windows toolchain paths cannot link it.") orelse lto_default;
    // Build under ThreadSanitizer. The engine's cross-thread state -- the TT, the shared history
    // tables, the per-Worker counters, the Syzygy table registry -- is raced BY DESIGN, and upstream
    // makes that race defined by typing every such field RelaxedAtomic. A missed atomic is not a
    // crash: it is undefined behaviour the compiler may exploit, invisible to every node-count gate.
    // TSan is the instrument that sees it.
    const want_tsan = b.option(bool, "tsan", "Build with ThreadSanitizer (for the parity-tsan race gate)") orelse false;

    const exe = b.addExecutable(.{
        .name = "stockfish",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/shell/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .sanitize_thread = want_tsan,
            // Omit .link_libcpp: the engine compiles zero C++ TUs (TU=0), so the C++
            // stdlib is dead weight.
        }),
    });
    exe.lto = if (want_tsan) .none else (if (want_lto) .full else .none);

    // Share a thin libc binding with the files that need C stdio etc.
    // Import as `libc` wherever a module says `const c = @import("libc")`.

    // Expose the aligned/large-page allocator as a shared module: consumers call it directly.

    // Provide typed engine-graph views (ThreadPool/Worker/... offset structs), imported
    // by the modules that read the engine graph.

    // Hold the bench positions (Defaults) and benchmark-command games (BenchmarkPositions)
    // as Zig arrays in benchmark.zig. Fetch the only external artifact, the NNUE net,
    // into resources/.
    // Keep StateList in its own module so engine_graph.zig can hold it as a typed member.
    // Own the numaContext member as NumaConfig.
    // Own the `numa_context` member as NumaReplicationContext.
    // Own the `pos` member's 1032B block as PositionStorage.
    // Size the `shared_histories` member as SharedHistories (pure count logic).
    // Provide the `sharedHists` member type as the sharedHists map container, instantiated in
    // position.zig with the real SharedHistories.
    // Hold the `network` member as the network holder (LazyNumaReplicated<Network> shape +
    // replica-count shadow verifier).

    // Compile the engine graph (engine_graph.zig) via the engine module: it
    // binds the ThreadPool and TranspositionTable.
    exe.root_module.addImport("runtime_hooks", mods.get("runtime_hooks").?);
    exe.root_module.addImport("time_source", mods.get("time_source").?);
    exe.root_module.addImport("tb_extend_source", mods.get("tb_extend_source").?);
    exe.root_module.addImport("tb_extend", mods.get("tb_extend").?);
    exe.root_module.addImport("page_alloc", mods.get("page_alloc").?);
    exe.root_module.addImport("option_source", mods.get("option_source").?);
    exe.root_module.addImport("tb_source", mods.get("tb_source").?);
    exe.root_module.addImport("tablebase", mods.get("tablebase").?);
    exe.root_module.addImport("thread_ops", mods.get("thread_ops").?);
    exe.root_module.addImport("output_sink", mods.get("output_sink").?);
    exe.root_module.addImport("search_thread", mods.get("search_thread").?);
    exe.root_module.addImport("thread_vote", mods.get("thread_vote").?);
    exe.root_module.addImport("engine_object", mods.get("engine_object").?);
    // Reach the search-history helpers directly from main.zig and its worker-construction helper.
    exe.root_module.addImport("search_driver", mods.get("search_driver").?);
    exe.root_module.addImport("worker_construct", mods.get("worker_construct").?);
    // Single-source default_eval_file_name in engine.zig from network.zig
    // (network has no engine dep, so this edge is acyclic).

    exe.root_module.addImport("engine", mods.get("engine").?);
    exe.root_module.addImport("misc", mods.get("misc").?);
    exe.root_module.addImport("nnue_accumulator", mods.get("nnue_accumulator").?);
    exe.root_module.addImport("network", mods.get("network").?);
    exe.root_module.addImport("nnue_feature", mods.get("nnue_feature").?);
    exe.root_module.addImport("state_list", mods.get("state_list").?);
    exe.root_module.addImport("option", mods.get("option").?);
    exe.root_module.addImport("position", mods.get("position").?);
    exe.root_module.addImport("position_snapshot", mods.get("position_snapshot").?);
    exe.root_module.addImport("search", mods.get("search").?);
    exe.root_module.addImport("timeman", mods.get("timeman").?);
    exe.root_module.addImport("thread", mods.get("thread").?);
    exe.root_module.addImport("uci", mods.get("uci").?);

    // Import the thin libc binding as `const c = @import("libc")` in main.zig.

    // Wire the direct callers of the aligned/large-page allocator.
    exe.root_module.addImport("memory", mods.get("memory").?);
    exe.root_module.addImport("worker_layout", mods.get("worker_layout").?);
    exe.root_module.addImport("position_types", mods.get("position_types").?);
    exe.root_module.addImport("clock", mods.get("clock").?);
    exe.root_module.addImport("uci_output", mods.get("uci_output").?);

    // Keep these addCMacro calls even though the engine compiles zero C++ TUs (TU=0), so they
    // are dead (no C TU consumes them) but harmless.
    exe.root_module.addCMacro("NDEBUG", "1");
    exe.root_module.addCMacro("DIS_64BIT", "1");
    exe.root_module.addCMacro("USE_PTHREADS", "1");
    exe.root_module.addCMacro("NNUE_EMBEDDING_OFF", "1");
    exe.root_module.addCMacro("ZFISH_ZIG_BUILD", "1");
    exe.root_module.addCMacro("ARCH", arch.name);

    applyMacros(exe.root_module, arch.macros);
    if (git_info.sha) |sha|
        exe.root_module.addCMacro("GIT_SHA", b.fmt("\"{s}\"", .{sha}));
    if (git_info.date) |date|
        exe.root_module.addCMacro("GIT_DATE", b.fmt("\"{s}\"", .{date}));

    // Link pthread + librt on Linux only: on macOS the pthread + realtime-clock symbols live
    // in libSystem (pulled in by link_libc), and on Windows threading/sync is Win32 and
    // there is no librt. link_libc already provides the C runtime (ucrt via mingw) the
    // aligned allocator needs on Windows.
    if (os_tag == .linux) {
        exe.root_module.linkSystemLibrary("pthread", .{});
        exe.root_module.linkSystemLibrary("rt", .{});
    }

    b.installArtifact(exe);

    const install_step = b.getInstallStep();

    // Fetch the runtime inputs (build/fetch.zig): the NNUE net and the 3-man Syzygy set.
    const fetches = buildpkg.fetch.register(b);
    const net_cmd = fetches.net;
    const tb_cmd = fetches.tb;

    // Drive the built engine over UCI with the pure-Zig parity harness and diff the
    // deterministic fingerprints against the committed goldens -- the cross-platform
    // replacement for the bash golden scripts (output_parity/search_parity/search_modes/
    // perft/eval/misc), so `zig build parity` runs identically on Linux/Windows/macOS with
    // no shell/coreutils dependency. Build it for the HOST (it spawns the engine as a
    // subprocess): in CI each lane builds natively so host == the engine's target.
    // ReleaseSafe, not ReleaseFast: this binary DECIDES whether the engine is correct, and its
    // own runtime is one subprocess spawn plus a wait, so optimization buys nothing measurable.
    // With safety off, a bound the harness slips reads garbage and reports a plausible verdict;
    // with it on, the same slip is a panic naming the line. A gate that can be quietly wrong is
    // worse than one that is slow.
    const harness_exe = b.addExecutable(.{
        .name = "parity_harness",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/parity_harness.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });

    const bench_run = b.addRunArtifact(exe);
    bench_run.step.dependOn(install_step);
    bench_run.step.dependOn(&net_cmd.step);
    bench_run.setCwd(b.path("resources"));
    bench_run.addArg("bench");
    bench_run.expectStdErrMatch("Nodes searched  : ");

    const bench_step = b.step(
        "bench",
        "Run stockfish bench from resources/ after fetching the default external NNUE net",
    );
    bench_step.dependOn(&bench_run.step);

    const uci_run = b.addRunArtifact(exe);
    uci_run.step.dependOn(install_step);
    uci_run.step.dependOn(&net_cmd.step);
    uci_run.setCwd(b.path("resources"));
    uci_run.setStdIn(.{ .bytes = "uci\nquit\n" });
    // Check the handshake on stdout: it is protocol, and a conforming GUI reads stdout.
    // This asserted stderr until the handshake was fixed to use the output sink -- the
    // engine really did emit it on stderr, so the gate passed while a GUI got nothing.
    // `bench` output IS on stderr (upstream does that too), but the handshake is not;
    // conflating the two is what let the defect look like a convention.
    uci_run.expectStdOutMatch("id name Stockfish");
    uci_run.expectStdOutMatch("uciok");

    const uci_step = b.step(
        "uci",
        "Run a scripted UCI handshake against the Zig-built Stockfish binary",
    );
    uci_step.dependOn(&uci_run.step);

    // Verify the bench signature with the pure-Zig parity harness (tools/parity_harness.zig
    // `signature` check), not tests/signature.sh -- one cross-OS gate instead of a bash wrapper that
    // only ran on Linux. Default to the 2884956 arch/OS invariant; -Dsignature-ref overrides.
    const signature_reference = signature_ref orelse "2884956";
    const signature_cmd = addHarnessRun(b, harness_exe, exe, install_step, &net_cmd.step, "signature", signature_reference, "check");

    // Interpolate the reference rather than repeating it: a second copy in the help text is a
    // number an upstream sync must remember to move, and the one it forgets is the one a reader
    // trusts.
    const signature_step = b.step(
        "signature",
        b.fmt(
            "Verify the Zig-built Stockfish bench signature (== {s} by default; -Dsignature-ref to override) via the pure-Zig parity harness",
            .{signature_reference},
        ),
    );
    signature_step.dependOn(&signature_cmd.step);

    // Register every golden gate from build/gates.zig's table: 21 rows, each a check+update
    // pair. Each row carries its own rationale as a comment there; this is the single loop
    // that turns the table into steps.
    const gate_runs = buildpkg.gates.register(.{
        .b = b,
        .harness = harness_exe,
        .stockfish = exe,
        .install_step = install_step,
        .net_step = &net_cmd.step,
        .tb_step = &tb_cmd.step,
        .goldenPath = repoPath,
    });

    // The two bespoke gates -- an upstream-oracle bench differential and the ThreadSanitizer
    // race lane -- register from build/structural.zig, which already owns the gates whose argv
    // shape resists the table.
    buildpkg.structural.registerUpstreamParity(b, exe, install_step, &net_cmd.step, repoPath);
    // Register every "run a shell script" gate from build/structural.zig's table.
    const script_runs = buildpkg.structural.register(.{
        .b = b,
        .stockfish = exe,
        .install_step = install_step,
        .net_step = &net_cmd.step,
        .repoPath = repoPath,
    });

    // Register the liveness / metamorphic checks (build/checks.zig): nine gates that assert
    // a property rather than diff a golden.
    const check_runs = buildpkg.checks.register(.{
        .b = b,
        .harness = harness_exe,
        .stockfish = exe,
        .install_step = install_step,
        .net_step = &net_cmd.step,
    });

    // Register the two upstream-differential gates (build/structural.zig): bespoke argv
    // shapes, so a function rather than a table row.
    buildpkg.structural.registerUpstream(b, install_step, &net_cmd.step, walk_args, repoPath);

    buildpkg.structural.registerTsanRace(b, exe, install_step, &net_cmd.step, &tb_cmd.step, repoPath);

    const host_arch_step = b.step("host-arch", "Print the host's best ARCH tier (the -Darch=native resolution)");
    host_arch_step.dependOn(&b.addSystemCommand(&.{ "printf", "%s", native_arch.detectArchFromCpu(b.graph.host.result.cpu) }).step);

    // Register the Zig-written lints (build/structural.zig): hook-lint and arch-report.
    const lint_runs = buildpkg.structural.registerLints(b);

    // Compile the entire engine module graph in isolation as the engine-only build/test target
    // via src/engine/headless.zig, which imports every engine-zone module.
    // By the headless invariant that graph has no platform/ or shell/ module, so this
    // proves at the compiler + linker level (not just structurally) that the engine is
    // a standalone library. link_libc: some engine arenas use the C allocator.
    const engine_root = b.createModule(.{
        .root_source_file = b.path("src/engine/headless.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    for (module_specs) |spec| {
        if (std.mem.startsWith(u8, spec.path, "src/engine/")) {
            engine_root.addImport(spec.name, mods.get(spec.name).?);
        }
    }
    const engine_test = b.addTest(.{ .root_module = engine_root });
    const engine_step = b.step("engine", "Build + test the engine module graph headless (no platform/shell)");
    addTestRun(b, engine_step, engine_test, cov_dir, &cov_idx);

    // Register the test + fuzz artifacts (build/tests.zig): the in-tree `test {}` aggregate,
    // the property tests, the fuzz targets and every standalone test root.
    buildpkg.tests.register(.{
        .b = b,
        .target = target,
        .optimize = optimize,
        .mods = &mods,
        .cov_dir = cov_dir,
        .cov_idx = &cov_idx,
        .engine_step = engine_step,
    });

    const parity_step = b.step(
        "parity",
        "Run the current bench, UCI, and signature checks through the Zig build entry",
    );
    // Assemble the per-push `parity` aggregate: whole-engine regression is caught by `signature`
    // (== 2884956) and the GOLDEN gates (output-golden / perft / eval-trace / misc /
    // search-parity / search-modes), all in-repo. The authoritative
    // differential-vs-real-upstream check is `upstream-parity` (worktree oracle), run at
    // sync time where upstream is already fetched -- per push it would only re-assert the
    // same 2884956 the signature checks.
    // Aggregate membership is a property of the ROW, not of a hand-kept list here: a gate
    // added to build/gates.zig joins the aggregates by its own flags.
    for (buildpkg.gates.golden) |g| {
        if (g.in_parity) parity_step.dependOn(&gate_runs.get(g.check).?.step);
    }
    // No script gate is in the portable subset today (every one is Linux-shaped: bash,
    // valgrind, or a path that loads the net), so only the parity edge is wired here. The
    // row keeps an `in_portable` flag so adding one is a field, not a new loop.
    for (buildpkg.structural.script_gates) |g| {
        if (g.in_parity) parity_step.dependOn(&script_runs.get(g.step).?.step);
    }
    for (buildpkg.structural.lint_tools) |l| {
        if (l.in_parity) parity_step.dependOn(&lint_runs.get(l.step).?.step);
    }
    for (buildpkg.checks.checks) |c| {
        if (c.in_parity) parity_step.dependOn(&check_runs.get(c.check).?.step);
    }
    parity_step.dependOn(&bench_run.step);
    parity_step.dependOn(&uci_run.step);
    parity_step.dependOn(&signature_cmd.step);
    // Join the interactive concurrency/timing gates to the core aggregate: they run in
    // the pure-Zig harness.
    // Gate every push on the permanent src-free structural invariant.

    // Assemble the cross-OS aggregate: the platform-independent subset of `parity` -- bench,
    // the UCI handshake, the bench signature, and all six golden checks, every one driven by
    // the pure-Zig harness (no bash / no nm). This is what the Windows and macOS lanes run;
    // the Linux-only structural gates (src-free via `nm`, arch-determinism) stay in `parity`.
    // Reuse the same harness `signature_cmd` `parity` uses for the bench signature (2884956 invariant).
    const parity_portable_step = b.step(
        "parity-portable",
        "Cross-OS parity via the pure-Zig harness: signature + seven golden gates + mt/stress/time",
    );
    for (buildpkg.gates.golden) |g| {
        if (g.in_portable) parity_portable_step.dependOn(&gate_runs.get(g.check).?.step);
    }
    for (buildpkg.structural.lint_tools) |l| {
        if (l.in_portable) parity_portable_step.dependOn(&lint_runs.get(l.step).?.step);
    }
    for (buildpkg.checks.checks) |c| {
        if (c.in_portable) parity_portable_step.dependOn(&check_runs.get(c.check).?.step);
    }
    parity_portable_step.dependOn(&bench_run.step);
    parity_portable_step.dependOn(&uci_run.step);
    parity_portable_step.dependOn(&signature_cmd.step);
    // Include driver-golden: it is node-deterministic (its depth-limited info/bestmove lines are
    // bit-exact like bench, not wall-clock-gated), so it is OS/arch-invariant like the other
    // golden gates -- its earlier absence here was an oversight.
    // Add the concurrency + timing gates -- the cross-OS payoff: these exercise the
    // sync primitives (futex / RtlWaitOnAddress / __ulock) under real threading and the
    // steady clock (QueryPerformanceCounter on Windows) on every OS, not just Linux.

    const stockfish_step = b.step(
        "stockfish",
        "Build the Zig-owned Stockfish engine for Linux x86_64 / aarch64",
    );
    stockfish_step.dependOn(install_step);

    // Hold every golden FILE to a gate that reads it -- the file-side counterpart of
    // lane-coverage's step side. Pass the declared paths from the SAME table the gates are
    // built from, so the declaration cannot drift from what runs; the tool globs the tree
    // for the other direction rather than reading a second list. Source-only and engine-free,
    // so it joins the portable aggregate too.
    const golden_coverage_tool = b.addExecutable(.{
        .name = "golden_coverage",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/golden_coverage.zig"),
            .target = b.graph.host,
            // .Debug for the checking allocator, as the other lints do (build/structural.zig).
            .optimize = .Debug,
        }),
    });
    const golden_coverage_run = b.addRunArtifact(golden_coverage_tool);
    golden_coverage_run.setCwd(b.path("."));
    for (buildpkg.gates.golden) |g| golden_coverage_run.addArg(g.golden);
    const golden_coverage_step = b.step(
        "golden-coverage",
        "Every golden file in the tree is read by a gate; every declared golden exists",
    );
    golden_coverage_step.dependOn(&golden_coverage_run.step);
    parity_step.dependOn(&golden_coverage_run.step);
    parity_portable_step.dependOn(&golden_coverage_run.step);

    // Hold every step registered above to a lane. Register LAST: it classifies
    // `b.top_level_steps`, so a step declared after this call would not be in the subject.
    const lane_coverage_tool = b.addExecutable(.{
        .name = "lane_coverage",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/lane_coverage.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    // `register` joins `parity` itself, before classifying, so the gate is in its own
    // subject -- see build/lanes.zig.
    _ = buildpkg.lanes.register(b, lane_coverage_tool, &.{ parity_step, parity_portable_step });
}

// Wire a unit-test artifact into `step` for coverage. Without coverage this is the plain
// `b.addRunArtifact`. With `-Dtest-coverage` (cov_dir set) the binary runs under kcov into its
// OWN subdir `kcov-out/cov-N` -- unique per artifact so the parallel test runs never write the
// same directory -- and CI merges the subdirs afterwards. `--include-path=src` scopes coverage
// to the owned source. Verified locally with a stub `kcov` (arg order + every artifact runs);
// CI installs the real kcov.
