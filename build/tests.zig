//! Own the test and fuzz artifacts.
//!
//! Every `zig build test` / `zig build fuzz` artifact: the in-tree `test {}` aggregate, the
//! libc-linked property tests, the coverage-guided fuzz targets, and the standalone builds
//! for sub-files and named modules whose tests need their own root. ~290 lines of `build()`.
//!
//! NOT A TABLE, deliberately. The golden and script gates were twenty copies of one shape;
//! these are not -- each artifact wires a different root, a different import set, sometimes
//! its own libc link. Data-driving them would need an option per artifact, which is a table
//! with one row per row. This is a straight relocation instead: `register` destructures the
//! context back into the locals the body already used, so the body moved VERBATIM and the
//! diff is a move rather than a rewrite.
//!
//! `docs_lint.sh` reads step names from here too (`test`, `fuzz`, and friends live in this
//! file now, not build.zig) -- it scans build/ for that reason.

const std = @import("std");
// The module table, for the standalone roots that enumerate engine modules.
const graph = @import("modules.zig");
const module_specs = graph.specs;
const module_edges = graph.edges;

pub const Context = struct {
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    /// The wired module graph, so a test root resolves the same imports the engine does.
    mods: *std.StringHashMap(*std.Build.Module),
    /// kcov output dir when -Dtest-coverage is on, else null.
    cov_dir: ?[]const u8,
    /// Shared counter so every coverage run gets a distinct output directory.
    cov_idx: *usize,
    engine_step: *std.Build.Step,
};

pub fn register(ctx: Context) void {
    const b = ctx.b;
    const target = ctx.target;
    const optimize = ctx.optimize;
    const mods = ctx.mods;
    const cov_dir = ctx.cov_dir;
    const cov_idx = ctx.cov_idx;
    const engine_step = ctx.engine_step;

    // Run the EngineGraph + member-module unit tests (construction,
    // lifetime, SharedState binding) with their module deps. `zig build test-graph`.
    const graph_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/shell/engine/graph.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    graph_test.root_module.addImport("thread", mods.get("thread").?);
    graph_test.root_module.addImport("tt", mods.get("tt").?);
    graph_test.root_module.addImport("shared_state", mods.get("shared_state").?);
    graph_test.root_module.addImport("state_list", mods.get("state_list").?);
    graph_test.root_module.addImport("numa", mods.get("numa").?);
    graph_test.root_module.addImport("position_storage", mods.get("position_storage").?);
    // Add the search_manager dependency explicitly: engine_graph.zig imports it by name, but this
    // standalone test builds it as a fresh root module (outside the module-edge table).
    graph_test.root_module.addImport("search_manager", mods.get("search_manager").?);
    // Same reason: graph.zig names the concrete types of its options / network /
    // shared_histories members, so this root needs their modules too.
    graph_test.root_module.addImport("option", mods.get("option").?);
    graph_test.root_module.addImport("network", mods.get("network").?);
    graph_test.root_module.addImport("shared_history", mods.get("shared_history").?);
    const graph_test_step = b.step("test-graph", "Run the native-graph (cut) unit tests");
    addTestRun(b, graph_test_step, graph_test, cov_dir, cov_idx);
    // Test the sharedHists map container (std-only generic) with a mock
    // entry. board/position.zig instantiates it with the real SharedHistories.
    const sh_map_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/engine/search/shared_histories_map.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    addTestRun(b, graph_test_step, sh_map_test, cov_dir, cov_idx);

    // Keep network free of a position import: its two Position field reads go through the
    // leaf worker_layout, which frees position -> network for the direct eval call below.

    // Run the in-tree `test {}` blocks of every named module that has them as the
    // aggregate unit-test step, reusing the already-wired modules so their
    // imports resolve, plus the engine-graph tests. Mind the reachability
    // caveat: tests in a path-imported sub-file run only when a module built here
    // imports it; a file with no test-reachable importer is not yet covered.
    const test_step = b.step("test", "Run the Zig unit tests");
    test_step.dependOn(graph_test_step);
    // Compile + test the engine graph standalone too (the headless invariant).
    test_step.dependOn(engine_step);
    inline for (.{
        mods.get("position_storage").?,
        mods.get("state_list").?,
        mods.get("time_source").?,
        mods.get("search_timing").?,
        mods.get("page_alloc").?,
        mods.get("option_source").?,
        mods.get("tb_source").?,
        mods.get("thread_ops").?,
        mods.get("output_sink").?,
        mods.get("tt").?,
        mods.get("shared_histories").?,
        mods.get("search_thread").?,
        mods.get("thread_runtime").?,
    }) |unit_module| {
        const unit_test = b.addTest(.{ .root_module = unit_module });
        addTestRun(b, test_step, unit_test, cov_dir, cov_idx);
    }
    // Cover the NUMA surface: numa.zig (configString uses c_allocator -> needs libc) plus the
    // config + replication types it owns via platform/numa/ (path-imported, same module),
    // so this one test covers the whole numa cluster.
    const numa_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/platform/numa.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    addTestRun(b, test_step, numa_test, cov_dir, cov_idx);

    // Link libc for option.zig's standalone test build: it uses std.heap.c_allocator
    // (in the exe the libc linkage comes from the root module). It has no module deps.
    const option_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/shell/option.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    addTestRun(b, test_step, option_test, cov_dir, cov_idx);

    // Run the board property tests (perft to known node counts) -- needs libc
    // (position uses c_allocator) + the board module graph.
    const board_props_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/engine/board/board_props.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    board_props_test.root_module.addImport("position", mods.get("position").?);
    board_props_test.root_module.addImport("movegen", mods.get("movegen").?);
    board_props_test.root_module.addImport("worker_layout", mods.get("worker_layout").?);
    addTestRun(b, test_step, board_props_test, cov_dir, cov_idx);

    // Run the uci_parse property + fuzz tests (needs libc for c_allocator + the
    // uci_strings base leaf).
    const uci_parse_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/shell/uci_parse.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    uci_parse_test.root_module.addImport("uci_strings", mods.get("uci_strings").?);
    addTestRun(b, test_step, uci_parse_test, cov_dir, cov_idx);

    // Build the coverage-guided fuzz targets (std.testing.fuzz). Wire them to their OWN
    // `zig build fuzz` step, deliberately NOT test_step -- these are meant to be run
    // with `zig build fuzz --fuzz` (the fuzzer), and run once as a smoke otherwise.
    //
    // FORCE ReleaseSafe, never the build's `optimize`. The whole value of these targets is
    // that a bad index or cast TRAPS instead of reading garbage, and inheriting the default
    // made `zig build fuzz` a ReleaseFast run locally while CI passed -Doptimize=ReleaseSafe --
    // a local gate weaker than the blocking lane, which is how a real `@intCast` overflow in
    // the tablebase group walk reached main green.
    const fuzz_optimize: std.builtin.OptimizeMode = .ReleaseSafe;

    // Give every artifact a PER-TARGET step as well as a place on the aggregate, because
    // `zig build fuzz --fuzz` cannot actually fuzz them all at once. `Fuzz.start` spawns one
    // worker per artifact through `Io.Group.async`, and the build runner's `Io.Threaded`
    // defaults `async_limit` to `cpu_count - 1`, one slot of which the coverage task already
    // holds. A fuzz worker never returns, so on an N-core box only N-2 artifacts EVER start:
    // three artifacts on a 4-core runner means one is silently never fuzzed, and which one is
    // scheduling order. Fuzz them one step at a time and each gets its own session.
    const fuzz_step = b.step("fuzz", "Run the coverage-guided fuzz targets (add --fuzz to fuzz)");

    // Build under -Doptimize=ReleaseSafe so a found crash trips a safety check.
    const fuzz_targets_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/engine/board/fuzz_targets.zig"),
            .target = target,
            .optimize = fuzz_optimize,
            .link_libc = true,
        }),
    });
    fuzz_targets_test.root_module.addImport("position", mods.get("position").?);
    fuzz_targets_test.root_module.addImport("movegen", mods.get("movegen").?);
    fuzz_targets_test.root_module.addImport("worker_layout", mods.get("worker_layout").?);
    fuzz_targets_test.root_module.addImport("position_snapshot", mods.get("position_snapshot").?);
    fuzz_targets_test.root_module.addImport("network", mods.get("network").?);
    fuzz_targets_test.root_module.addImport("nnue_accumulator", mods.get("nnue_accumulator").?);
    fuzz_targets_test.root_module.addImport("headless_search", mods.get("headless_search").?);
    const fuzz_board_step = b.step("fuzz-board", "Fuzz the board/eval/search targets alone");
    fuzz_board_step.dependOn(&b.addRunArtifact(fuzz_targets_test).step);
    fuzz_step.dependOn(&b.addRunArtifact(fuzz_targets_test).step);

    // Fuzz the Syzygy file parse on the same step. A .rtbw/.rtbz is the only attacker-supplyable
    // BINARY input the engine parses, and decode/probe/encode depend on std alone, so this root
    // needs no module imports -- it path-imports the decoder cluster directly.
    const tb_fuzz_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/platform/syzygy/fuzz_targets.zig"),
            .target = target,
            .optimize = fuzz_optimize,
            .link_libc = true,
        }),
    });
    const fuzz_tb_step = b.step("fuzz-tb", "Fuzz the Syzygy file parse as units, alone");
    fuzz_tb_step.dependOn(&b.addRunArtifact(tb_fuzz_test).step);
    fuzz_step.dependOn(&b.addRunArtifact(tb_fuzz_test).step);

    // Fuzz the same file END TO END: parse an image into a registered TBTable and probe it, which
    // is the only way to reach an invariant the header parse accepts and the PROBE relies on. This
    // root DOES need the module graph -- the same imports `tablebase` carries, since it drives
    // registry/table_load/wdl rather than the decoder cluster alone.
    const tb_probe_fuzz_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/platform/syzygy/fuzz_probe.zig"),
            .target = target,
            .optimize = fuzz_optimize,
            .link_libc = true,
        }),
    });
    for ([_][]const u8{ "tb_source", "position", "state_list", "movegen", "board_core", "thread_runtime" }) |name|
        tb_probe_fuzz_test.root_module.addImport(name, mods.get(name).?);
    const fuzz_tb_probe_step = b.step("fuzz-tb-probe", "Fuzz the Syzygy parse-then-probe path alone");
    fuzz_tb_probe_step.dependOn(&b.addRunArtifact(tb_probe_fuzz_test).step);
    fuzz_step.dependOn(&b.addRunArtifact(tb_probe_fuzz_test).step);

    // Report what the fuzzer actually EXECUTED. `zig build fuzz --fuzz` exits 0 whether it ran
    // half a billion inputs or three, and prints no total, so a lane that stopped fuzzing reads
    // exactly like one that found nothing. This reads the per-artifact execution counters the
    // Zig fuzzer keeps in `<cache>/v` and prints them; the nightly workflow runs the same tool
    // in `check` mode against a pre-run snapshot to gate on them. Local, read-only, no build
    // dependency -- run it right after a `--fuzz` session to see the budget you actually got.
    const fuzz_report_exe = b.addExecutable(.{
        .name = "fuzz_report",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/fuzz_report.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const fuzz_report_cmd = b.addRunArtifact(fuzz_report_exe);
    fuzz_report_cmd.setCwd(b.path("."));
    fuzz_report_cmd.addArgs(&.{ ".zig-cache", "report" });
    const fuzz_report_step = b.step(
        "fuzz-report",
        "Print how many inputs each fuzz artifact has executed (reads the fuzzer's counters)",
    );
    fuzz_report_step.dependOn(&fuzz_report_cmd.step);

    // Build standalone test artifacts for the tested sub-files that were
    // path-imported into larger modules (so their `test {}` blocks never ran in
    // the aggregate). These depend only on std (+ libc for c_allocator) or on a
    // sibling path import, so they build in isolation.
    inline for (.{
        "src/engine/board/position_types.zig",
        "src/engine/board/fen.zig",
        "src/engine/board/board_core.zig",
        "src/engine/state/root_move.zig",
        "src/engine/search/search_manager.zig",
        "src/engine/state/shared_state.zig",
        "src/engine/eval/nnue_parse.zig",
        "src/engine/eval/nnue_hash.zig",
        "src/shell/debug_counters.zig",
        "src/shell/bench_positions.zig",
        "src/shell/uci_output.zig",
        "src/engine/search/uci_wdl.zig",
        "src/engine/board/score.zig",
        "src/shell/uci_strings.zig",
        "src/shell/engine/util.zig",
        "src/engine/search/timeman.zig",
        "src/engine/eval/nnue_misc.zig",
        "src/engine/eval/evaluate.zig",
        "src/engine/search/search.zig",
        "src/engine/board/bitboard.zig",
        "src/engine/state/correction_bundle.zig",
        "src/engine/state/limits_type.zig",
        "src/engine/eval/nnue_acc_rowops.zig",
        "src/engine/eval/nnue_feature.zig",
        "src/engine/eval/nnue_ft.zig",
        "src/engine/eval/nnue_refresh_cache.zig",
        "src/platform/memory.zig",
        "src/platform/clock.zig",
        "src/platform/numa.zig",
        "src/engine/state/tt_types.zig",
        "src/engine/eval/nnue_feature_bb.zig",
        "src/engine/board/bitboard_geom.zig",
        "src/engine/search/search_values.zig",
        "src/shell/option_parse.zig",
        "src/shell/option_model.zig",
        "tools/native_arch.zig",
        "tools/fetch_net.zig",
        // The parity harness's pure half: the info/bestmove parse and the field diff. The
        // gate builders around it drive a real engine, so only this file is unit-testable.
        "tools/parity/structured_diff.zig",
    }) |src_path| {
        const file_test = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(src_path),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }),
        });
        addTestRun(b, test_step, file_test, cov_dir, cov_idx);
    }

    // Build isolated unit tests for the NAMED modules whose in-tree `test {}` blocks need their
    // imports wired to compile standalone. Derive the import set from module_edges
    // (single-source): the exe wiring IS the test wiring, so adding a module_edges edge
    // auto-covers the isolated test -- there is no second list to keep in sync. These 32
    // modules previously re-declared their imports in the DepTest table below; that
    // duplication was a proven foot-gun (a new edge silently skipped the standalone test,
    // e.g. the Syzygy `tb_source` wiring). Listing a module name here is the whole opt-in.
    const module_unit_test_names = [_][]const u8{
        "tablebase",         "uci_format",       "engine_infofmt",       "engine_options",
        "position_snapshot", "worker_histories", "shared_history_types", "thread_vote",
        "runtime_hooks",     "search_types",     "position_query",       "zobrist",
        "uci_move",          "benchmark",        "movegen",              "network",
        "legality",          "search_common",    "movepick",             "position_lifecycle",
        "search_setup",      "fen_parse",        "search_ctx",           "repetition",
        "state_setup",       "worker_layout",    "move_do",              "nnue_accumulator",
        "engine_object",     "engine_nnue",      "shared_history",       "history",
        "worker_construct",  "headless_search",
    };
    for (module_unit_test_names) |name| {
        const spec_path = blk: {
            for (module_specs) |s| {
                if (std.mem.eql(u8, s.name, name)) break :blk s.path;
            }
            std.debug.panic("module_unit_test_names names '{s}', which build/modules.zig specs does not declare", .{name});
        };
        // Create a fresh module (not the shared exe module) so the test artifact links libc for
        // the c_allocator-using `test {}` blocks without mutating the exe module.
        const tm = b.createModule(.{
            .root_source_file = b.path(spec_path),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        for (module_edges) |e| {
            if (std.mem.eql(u8, e.from, name)) tm.addImport(e.imp, mods.get(e.to).?);
        }
        // build_options is attached imperatively in build.zig, not through module_edges (it is
        // not a spec'd source file), so it has no edge to derive from. Hand it to every root:
        // an unused module import costs nothing, and a missing one is a compile error in the
        // root that happens to read a flag.
        if (mods.get("build_options")) |bo| tm.addImport("build_options", bo);
        const tm_test = b.addTest(.{ .root_module = tm });
        addTestRun(b, test_step, tm_test, cov_dir, cov_idx);
    }

    // Cover PATH-LEAF files (NOT named modules, so they have no module_edges row) whose
    // `test {}` / refAllDecls need a few module imports to compile. Their deps are genuinely
    // their own data -- there is nothing to derive them from but the file's own `@import`
    // lines -- so each lists its DIRECT imports explicitly. The modules in `mods` already
    // carry their own transitive imports.
    const DepTest = struct { path: []const u8, deps: []const []const u8 };
    for ([_]DepTest{
        .{ .path = "src/engine/eval/nnue_acc_layout.zig", .deps = &.{ "position_snapshot", "position_types" } },
        .{ .path = "src/engine/eval/nnue_acc_update.zig", .deps = &.{ "position_snapshot", "position_types", "nnue_feature", "nnue_acc_rowops", "nnue_ft", "nnue_refresh_cache" } },
        .{ .path = "src/shell/thread_construct.zig", .deps = &.{"worker_layout"} },
        .{ .path = "src/engine/search/movepick_snapshot.zig", .deps = &.{ "bitboard", "position_types" } },
        .{ .path = "src/engine/search/movepick_history.zig", .deps = &.{ "position_snapshot", "shared_history_types" } },
        .{ .path = "src/engine/eval/nnue_weight_storage.zig", .deps = &.{"page_alloc"} },
        .{ .path = "src/engine/eval/nnue_inference.zig", .deps = &.{ "page_alloc", "nnue_accumulator", "position_types" } },
        .{ .path = "src/engine/search/movepick_score.zig", .deps = &.{ "bitboard", "movegen", "position_snapshot", "position_types", "shared_history_types" } },
        .{ .path = "src/engine/search/movepick_sort_avx512.zig", .deps = &.{ "bitboard", "movegen", "position_snapshot", "position_types", "shared_history_types" } },
        .{ .path = "src/engine/search/search_control.zig", .deps = &.{ "time_source", "search_ctx", "search_types" } },
        .{ .path = "src/shell/engine/control.zig", .deps = &.{ "libc", "worker_layout", "engine_object", "tt", "thread", "option", "tablebase", "engine_nnue" } },
    }) |dt| {
        const t = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(dt.path),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }),
        });
        for (dt.deps) |d| t.root_module.addImport(d, mods.get(d).?);
        if (mods.get("build_options")) |bo| t.root_module.addImport("build_options", bo);
        addTestRun(b, test_step, t, cov_dir, cov_idx);
    }

    // Wire the position_types module for state_list.zig's standalone test: it holds a typed
    // StateInfo (unlike the std-only files in the loop above).
    const state_list_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/engine/board/state_list.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    state_list_test.root_module.addImport("position_types", mods.get("position_types").?);
    addTestRun(b, test_step, state_list_test, cov_dir, cov_idx);

    // Build thread_pool.zig as a standalone test artifact (spawns real SearchThreads -> link_libc):
    // it is path-imported into the (untested) `thread` module, so its Pool footprint +
    // bound-slice lifecycle `test {}` blocks never ran in any step -- run it here
    // so `zig build test` actually exercises the ThreadPool-footprint writer/accessors.
    const thread_pool_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/platform/thread_pool.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    thread_pool_test.root_module.addImport("search_thread", mods.get("search_thread").?);
    thread_pool_test.root_module.addImport("worker_layout", mods.get("worker_layout").?);
    thread_pool_test.root_module.addImport("runtime_hooks", mods.get("runtime_hooks").?);
    addTestRun(b, test_step, thread_pool_test, cov_dir, cov_idx);
}

pub fn addTestRun(b: *std.Build, step: *std.Build.Step, artifact: *std.Build.Step.Compile, cov_dir: ?[]const u8, cov_idx: *usize) void {
    if (cov_dir) |dir| {
        const sub = b.fmt("{s}/cov-{d}", .{ dir, cov_idx.* });
        cov_idx.* += 1;
        const run = b.addSystemCommand(&.{ "kcov", "--include-path=src", sub });
        run.addArtifactArg(artifact);
        run.has_side_effects = true;
        step.dependOn(&run.step);
    } else {
        step.dependOn(&b.addRunArtifact(artifact).step);
    }
}
