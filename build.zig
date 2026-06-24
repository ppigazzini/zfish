const std = @import("std");

const Macro = struct {
    name: []const u8,
    value: []const u8,
};

const ArchConfig = struct {
    name: []const u8,
    flags: []const []const u8,
    macros: []const Macro,
    target_features: std.Target.Cpu.Feature.Set,
};

const GitInfo = struct {
    sha: ?[]const u8,
    date: ?[]const u8,
};

pub fn build(b: *std.Build) void {
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Prioritize performance, safety, or binary size",
    ) orelse .ReleaseFast;
    const signature_ref = b.option(
        []const u8,
        "signature-ref",
        "Expected bench signature for tests/signature.sh; omit to print the current signature",
    );
    const requested_arch = b.option(
        []const u8,
        "arch",
        "Stockfish ARCH value for Linux x86_64, or 'native' to use scripts/get_native_properties.sh",
    ) orelse "native";
    const arch = resolveArch(b, requested_arch);
    const git_info = readGitInfo(b);
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "arch_name", arch.name);
    build_options.addOption([]const u8, "git_sha", git_info.sha orelse "");
    build_options.addOption([]const u8, "git_date", git_info.date orelse "");
    build_options.addOption(bool, "use_avx512icl", hasMacro(arch.macros, "USE_AVX512ICL"));
    build_options.addOption(bool, "use_vnni", hasMacro(arch.macros, "USE_VNNI"));
    build_options.addOption(bool, "use_avx512", hasMacro(arch.macros, "USE_AVX512"));
    build_options.addOption(bool, "use_avx2", hasMacro(arch.macros, "USE_AVX2"));
    build_options.addOption(bool, "use_sse41", hasMacro(arch.macros, "USE_SSE41"));
    build_options.addOption(bool, "use_ssse3", hasMacro(arch.macros, "USE_SSSE3"));
    build_options.addOption(bool, "use_sse2", hasMacro(arch.macros, "USE_SSE2"));
    build_options.addOption(bool, "use_neon_dotprod", hasMacro(arch.macros, "USE_NEON_DOTPROD"));
    build_options.addOption(bool, "use_neon", hasMacro(arch.macros, "USE_NEON"));
    build_options.addOption(bool, "use_popcnt", hasMacro(arch.macros, "USE_POPCNT"));
    build_options.addOption(bool, "use_pext", hasMacro(arch.macros, "USE_PEXT"));
    build_options.addOption(bool, "has_ndebug", true);
    const build_options_module = build_options.createModule();

    const target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .cpu_model = .baseline,
        .cpu_features_add = arch.target_features,
        .os_tag = .linux,
        .abi = .gnu,
    });

    const exe = b.addExecutable(.{
        .name = "stockfish",
        .root_module = b.createModule(.{
            .root_source_file = b.path("zig_src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = true,
        }),
    });

    const legacy_exe = b.addExecutable(.{
        .name = "stockfish-legacy-cpp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("zig_src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = true,
        }),
    });

    // Per-build comptime flag so the Zig root can gate @export of symbols that the
    // legacy oracle still defines in src/ (e.g. the SearchManager field shims in
    // src/thread.cpp). In the default build legacy_target is false and Zig owns
    // the symbol; in the legacy build it is true and Zig stays silent, letting the
    // src/ definition win -- avoiding a duplicate-symbol link error.
    const default_flags = b.addOptions();
    default_flags.addOption(bool, "legacy_target", false);
    const default_flags_mod = default_flags.createModule();
    exe.root_module.addImport("target_flags", default_flags_mod);
    const legacy_flags = b.addOptions();
    legacy_flags.addOption(bool, "legacy_target", true);
    const legacy_flags_mod = legacy_flags.createModule();
    legacy_exe.root_module.addImport("target_flags", legacy_flags_mod);

    const timeman_module = b.createModule(.{
        .root_source_file = b.path("zig_build/time/timeman.zig"),
        .target = target,
        .optimize = optimize,
    });
    const benchmark_source_files = b.addWriteFiles();
    _ = benchmark_source_files.addCopyFile(b.path("src/benchmark.cpp"), "benchmark.cpp");
    const benchmark_source_module = benchmark_source_files.add(
        "benchmark_source_data.zig",
        "pub const source = @embedFile(\"benchmark.cpp\");\n",
    );
    const benchmark_module = b.createModule(.{
        .root_source_file = b.path("zig_build/bench/benchmark.zig"),
        .target = target,
        .optimize = optimize,
    });
    benchmark_module.addAnonymousImport("benchmark_source_data", .{
        .root_source_file = benchmark_source_module,
    });
    const misc_module = b.createModule(.{
        .root_source_file = b.path("zig_build/support/misc.zig"),
        .target = target,
        .optimize = optimize,
    });
    misc_module.addImport("build_options", build_options_module);
    // Stage-7: engine + thread modules are built per-exe (default vs legacy) so
    // thread.zig can read target_flags.legacy_target at COMPTIME (it was shared and
    // runtime-gated before). engine.zig pulls thread in via engine_graph.zig, so it
    // must match the exe's thread instance (same @export symbols), hence duplicated.
    const engine_module_default = b.createModule(.{
        .root_source_file = b.path("zig_build/support/engine.zig"),
        .target = target,
        .optimize = optimize,
    });
    const engine_module_legacy = b.createModule(.{
        .root_source_file = b.path("zig_build/support/engine.zig"),
        .target = target,
        .optimize = optimize,
    });
    const uci_move_module = b.createModule(.{
        .root_source_file = b.path("zig_build/support/uci_move.zig"),
        .target = target,
        .optimize = optimize,
    });
    const movepick_module = b.createModule(.{
        .root_source_file = b.path("zig_build/support/movepick.zig"),
        .target = target,
        .optimize = optimize,
    });
    const search_module = b.createModule(.{
        .root_source_file = b.path("zig_build/support/search.zig"),
        .target = target,
        .optimize = optimize,
    });
    const thread_module_default = b.createModule(.{
        .root_source_file = b.path("zig_build/support/thread.zig"),
        .target = target,
        .optimize = optimize,
    });
    const thread_module_legacy = b.createModule(.{
        .root_source_file = b.path("zig_build/support/thread.zig"),
        .target = target,
        .optimize = optimize,
    });
    const tt_module = b.createModule(.{
        .root_source_file = b.path("zig_build/support/tt.zig"),
        .target = target,
        .optimize = optimize,
    });
    const option_module = b.createModule(.{
        .root_source_file = b.path("zig_build/uci/option.zig"),
        .target = target,
        .optimize = optimize,
    });
    const bitboard_module = b.createModule(.{
        .root_source_file = b.path("zig_build/board/bitboard.zig"),
        .target = target,
        .optimize = optimize,
    });
    const position_module = b.createModule(.{
        .root_source_file = b.path("zig_build/board/position.zig"),
        .target = target,
        .optimize = optimize,
    });
    const position_snapshot_module = b.createModule(.{
        .root_source_file = b.path("zig_build/board/position_snapshot.zig"),
        .target = target,
        .optimize = optimize,
    });
    const movegen_module = b.createModule(.{
        .root_source_file = b.path("zig_build/board/movegen.zig"),
        .target = target,
        .optimize = optimize,
    });
    const nnue_feature_module = b.createModule(.{
        .root_source_file = b.path("zig_build/eval/nnue_feature.zig"),
        .target = target,
        .optimize = optimize,
    });
    const uci_module = b.createModule(.{
        .root_source_file = b.path("zig_build/uci/uci.zig"),
        .target = target,
        .optimize = optimize,
    });
    const evaluate_module = b.createModule(.{
        .root_source_file = b.path("zig_build/eval/evaluate.zig"),
        .target = target,
        .optimize = optimize,
    });
    const nnue_accumulator_module = b.createModule(.{
        .root_source_file = b.path("zig_build/eval/nnue_accumulator.zig"),
        .target = target,
        .optimize = optimize,
    });
    const network_module = b.createModule(.{
        .root_source_file = b.path("zig_build/eval/network.zig"),
        .target = target,
        .optimize = optimize,
    });
    const nnue_misc_module = b.createModule(.{
        .root_source_file = b.path("zig_build/eval/nnue_misc.zig"),
        .target = target,
        .optimize = optimize,
    });
    // Native StateList (the post-src/ `states` deque replacement, native-graph cut);
    // its own module so engine_graph.zig can hold it as a typed member.
    const state_list_module = b.createModule(.{
        .root_source_file = b.path("zig_build/board/state_list.zig"),
        .target = target,
        .optimize = optimize,
    });
    // Native NumaConfig (the post-src/ numaContext member, native-graph cut).
    const numa_config_module = b.createModule(.{
        .root_source_file = b.path("zig_build/support/numa_config.zig"),
        .target = target,
        .optimize = optimize,
    });
    // Native PositionStorage (post-src/ owner of the `pos` member's 1032B block).
    const position_storage_module = b.createModule(.{
        .root_source_file = b.path("zig_build/board/position_storage.zig"),
        .target = target,
        .optimize = optimize,
    });

    // For the native engine-graph scaffolding (engine_graph.zig) compiled via the
    // engine module: it binds the native ThreadPool and TranspositionTable. Each
    // engine variant pulls its matching (default/legacy) thread instance.
    inline for (.{
        .{ engine_module_default, thread_module_default },
        .{ engine_module_legacy, thread_module_legacy },
    }) |pair| {
        pair[0].addImport("position", position_module);
        pair[0].addImport("position_snapshot", position_snapshot_module);
        pair[0].addImport("uci_move", uci_move_module);
        pair[0].addImport("misc", misc_module);
        pair[0].addImport("thread", pair[1]);
        pair[0].addImport("tt", tt_module);
        pair[0].addImport("state_list", state_list_module);
        pair[0].addImport("numa_config", numa_config_module);
        pair[0].addImport("position_storage", position_storage_module);
    }

    // Native-graph cut: run the EngineGraph + member-module unit tests (construction,
    // lifetime, SharedState binding) with their module deps. `zig build test-graph`.
    const graph_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("zig_build/support/engine_graph.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    graph_test.root_module.addImport("thread", thread_module_default);
    graph_test.root_module.addImport("tt", tt_module);
    graph_test.root_module.addImport("state_list", state_list_module);
    graph_test.root_module.addImport("numa_config", numa_config_module);
    graph_test.root_module.addImport("position_storage", position_storage_module);
    const graph_test_step = b.step("test-graph", "Run the native-graph (cut) unit tests");
    graph_test_step.dependOn(&b.addRunArtifact(graph_test).step);

    uci_move_module.addImport("position_snapshot", position_snapshot_module);
    movepick_module.addImport("position_snapshot", position_snapshot_module);
    movepick_module.addImport("bitboard", bitboard_module);
    movegen_module.addImport("position_snapshot", position_snapshot_module);
    movegen_module.addImport("bitboard", bitboard_module);
    nnue_accumulator_module.addImport("position_snapshot", position_snapshot_module);
    position_module.addImport("bitboard", bitboard_module);
    position_module.addImport("movegen", movegen_module);
    position_module.addImport("tt", tt_module);
    position_module.addImport("movepick", movepick_module);
    position_module.addImport("search", search_module);
    inline for (.{
        .{ thread_module_default, default_flags_mod },
        .{ thread_module_legacy, legacy_flags_mod },
    }) |pair| {
        pair[0].addImport("position_snapshot", position_snapshot_module);
        pair[0].addImport("position", position_module);
        pair[0].addImport("uci_move", uci_move_module);
        pair[0].addImport("target_flags", pair[1]);
    }
    uci_module.addImport("benchmark", benchmark_module);
    uci_module.addImport("misc", misc_module);
    exe.root_module.addImport("benchmark", benchmark_module);
    exe.root_module.addImport("bitboard", bitboard_module);
    exe.root_module.addImport("engine", engine_module_default);
    exe.root_module.addImport("evaluate", evaluate_module);
    exe.root_module.addImport("misc", misc_module);
    exe.root_module.addImport("movegen", movegen_module);
    exe.root_module.addImport("movepick", movepick_module);
    exe.root_module.addImport("nnue_accumulator", nnue_accumulator_module);
    exe.root_module.addImport("network", network_module);
    exe.root_module.addImport("nnue_feature", nnue_feature_module);
    exe.root_module.addImport("nnue_misc", nnue_misc_module);
    exe.root_module.addImport("option", option_module);
    exe.root_module.addImport("position", position_module);
    exe.root_module.addImport("position_snapshot", position_snapshot_module);
    exe.root_module.addImport("search", search_module);
    exe.root_module.addImport("timeman", timeman_module);
    exe.root_module.addImport("thread", thread_module_default);
    exe.root_module.addImport("tt", tt_module);
    exe.root_module.addImport("uci", uci_module);
    exe.root_module.addImport("uci_move", uci_move_module);

    legacy_exe.root_module.addImport("benchmark", benchmark_module);
    legacy_exe.root_module.addImport("bitboard", bitboard_module);
    legacy_exe.root_module.addImport("engine", engine_module_legacy);
    legacy_exe.root_module.addImport("evaluate", evaluate_module);
    legacy_exe.root_module.addImport("misc", misc_module);
    legacy_exe.root_module.addImport("movegen", movegen_module);
    legacy_exe.root_module.addImport("movepick", movepick_module);
    legacy_exe.root_module.addImport("nnue_accumulator", nnue_accumulator_module);
    legacy_exe.root_module.addImport("network", network_module);
    legacy_exe.root_module.addImport("nnue_feature", nnue_feature_module);
    legacy_exe.root_module.addImport("nnue_misc", nnue_misc_module);
    legacy_exe.root_module.addImport("option", option_module);
    legacy_exe.root_module.addImport("position", position_module);
    legacy_exe.root_module.addImport("position_snapshot", position_snapshot_module);
    legacy_exe.root_module.addImport("search", search_module);
    legacy_exe.root_module.addImport("timeman", timeman_module);
    legacy_exe.root_module.addImport("thread", thread_module_legacy);
    legacy_exe.root_module.addImport("tt", tt_module);
    legacy_exe.root_module.addImport("uci", uci_module);
    legacy_exe.root_module.addImport("uci_move", uci_move_module);

    var compile_flags = std.ArrayList([]const u8).empty;
    compile_flags.appendSlice(b.allocator, &.{
        "-std=c++17",
        "-O3",
        "-funroll-loops",
        "-fno-exceptions",
        "-Wno-date-time",
    }) catch @panic("OOM");
    compile_flags.appendSlice(b.allocator, arch.flags) catch @panic("OOM");

    const stockfish_sources = &.{};

    const stockfish_legacy_sources = &.{
        "timeman.cpp",
        "evaluate.cpp",
        "movepick.cpp",
        "tt.cpp",
        "thread.cpp",
        "syzygy/tbprobe.cpp",
    };

    const stockfish_position_sources = &[_][]const u8{};

    const stockfish_legacy_position_sources = &[_][]const u8{};

    const zig_compat_sources = &.{
        "uci_bridge.cpp",
    };

    exe.root_module.addIncludePath(b.path("src"));
    exe.root_module.addCMacro("NDEBUG", "1");
    exe.root_module.addCMacro("DIS_64BIT", "1");
    exe.root_module.addCMacro("USE_PTHREADS", "1");
    exe.root_module.addCMacro("NNUE_EMBEDDING_OFF", "1");
    exe.root_module.addCMacro("ZFISH_ZIG_BUILD", "1");
    exe.root_module.addCMacro("ARCH", arch.name);

    legacy_exe.root_module.addIncludePath(b.path("src"));
    legacy_exe.root_module.addCMacro("NDEBUG", "1");
    legacy_exe.root_module.addCMacro("DIS_64BIT", "1");
    legacy_exe.root_module.addCMacro("USE_PTHREADS", "1");
    legacy_exe.root_module.addCMacro("NNUE_EMBEDDING_OFF", "1");
    legacy_exe.root_module.addCMacro("ZFISH_ZIG_BUILD", "1");
    legacy_exe.root_module.addCMacro("ZFISH_LEGACY_CPP_TARGET", "1");
    legacy_exe.root_module.addCMacro("ARCH", arch.name);

    applyMacros(exe.root_module, arch.macros);
    applyMacros(legacy_exe.root_module, arch.macros);
    if (git_info.sha) |sha|
        exe.root_module.addCMacro("GIT_SHA", b.fmt("\"{s}\"", .{sha}));
    if (git_info.date) |date|
        exe.root_module.addCMacro("GIT_DATE", b.fmt("\"{s}\"", .{date}));

    if (git_info.sha) |sha|
        legacy_exe.root_module.addCMacro("GIT_SHA", b.fmt("\"{s}\"", .{sha}));
    if (git_info.date) |date|
        legacy_exe.root_module.addCMacro("GIT_DATE", b.fmt("\"{s}\"", .{date}));

    if (stockfish_sources.len != 0) {
        exe.root_module.addCSourceFiles(.{
            .root = b.path("src"),
            .files = stockfish_sources,
            .flags = compile_flags.items,
        });
    }

    if (stockfish_legacy_sources.len != 0) {
        legacy_exe.root_module.addCSourceFiles(.{
            .root = b.path("src"),
            .files = stockfish_legacy_sources,
            .flags = compile_flags.items,
        });
    }

    if (stockfish_position_sources.len != 0) {
        var position_compile_flags = std.ArrayList([]const u8).empty;
        position_compile_flags.appendSlice(b.allocator, compile_flags.items) catch @panic("OOM");
        position_compile_flags.appendSlice(b.allocator, &.{
            "-DZFISH_POSITION_BRIDGE_SKIP_COMPUTE_MATERIAL_KEY",
            "-DZFISH_POSITION_BRIDGE_SKIP_ENDGAME_SET",
            "-DZFISH_POSITION_BRIDGE_SKIP_FEN",
            "-DZFISH_POSITION_BRIDGE_SKIP_REPETITION",
            "-DZFISH_POSITION_BRIDGE_SKIP_ATTACKERS_TO",
            "-DZFISH_POSITION_BRIDGE_SKIP_CHECK_INFO",
            "-DZFISH_POSITION_BRIDGE_SKIP_LEGAL",
            "-DZFISH_POSITION_BRIDGE_SKIP_GIVES_CHECK",
            "-DZFISH_POSITION_BRIDGE_SKIP_PSEUDO_LEGAL",
            "-DZFISH_POSITION_BRIDGE_SKIP_SEE_GE",
            "-DZFISH_POSITION_BRIDGE_SKIP_IS_DRAW",
            "-DZFISH_POSITION_BRIDGE_SKIP_NULL_MOVE",
            "-DZFISH_POSITION_BRIDGE_SKIP_UPCOMING_REPETITION",
            "-DZFISH_POSITION_BRIDGE_SKIP_SET_CASTLING_RIGHT",
            "-DZFISH_POSITION_BRIDGE_SKIP_SET_STATE",
            "-DZFISH_POSITION_BRIDGE_SKIP_FLIP",
            "-DZFISH_POSITION_BRIDGE_SKIP_SET",
            "-DZFISH_POSITION_BRIDGE_SKIP_UNDO_MOVE",
            "-DZFISH_POSITION_BRIDGE_SKIP_DO_MOVE",
            "-DZFISH_POSITION_BRIDGE_SKIP_INIT",
        }) catch @panic("OOM");

        exe.root_module.addCSourceFiles(.{
            .root = b.path("src"),
            .files = stockfish_position_sources,
            .flags = position_compile_flags.items,
        });
    }

    if (stockfish_legacy_position_sources.len != 0) {
        var legacy_position_compile_flags = std.ArrayList([]const u8).empty;
        legacy_position_compile_flags.appendSlice(b.allocator, compile_flags.items) catch @panic("OOM");
        legacy_position_compile_flags.appendSlice(b.allocator, &.{
            "-DZFISH_POSITION_BRIDGE_SKIP_COMPUTE_MATERIAL_KEY",
            "-DZFISH_POSITION_BRIDGE_SKIP_ENDGAME_SET",
            "-DZFISH_POSITION_BRIDGE_SKIP_FEN",
            "-DZFISH_POSITION_BRIDGE_SKIP_REPETITION",
            "-DZFISH_POSITION_BRIDGE_SKIP_ATTACKERS_TO",
            "-DZFISH_POSITION_BRIDGE_SKIP_CHECK_INFO",
            "-DZFISH_POSITION_BRIDGE_SKIP_LEGAL",
            "-DZFISH_POSITION_BRIDGE_SKIP_GIVES_CHECK",
            "-DZFISH_POSITION_BRIDGE_SKIP_PSEUDO_LEGAL",
            "-DZFISH_POSITION_BRIDGE_SKIP_SEE_GE",
            "-DZFISH_POSITION_BRIDGE_SKIP_IS_DRAW",
            "-DZFISH_POSITION_BRIDGE_SKIP_NULL_MOVE",
            "-DZFISH_POSITION_BRIDGE_SKIP_UPCOMING_REPETITION",
            "-DZFISH_POSITION_BRIDGE_SKIP_SET_CASTLING_RIGHT",
            "-DZFISH_POSITION_BRIDGE_SKIP_SET_STATE",
            "-DZFISH_POSITION_BRIDGE_SKIP_FLIP",
            "-DZFISH_POSITION_BRIDGE_SKIP_SET",
            "-DZFISH_POSITION_BRIDGE_SKIP_UNDO_MOVE",
            "-DZFISH_POSITION_BRIDGE_SKIP_DO_MOVE",
            "-DZFISH_POSITION_BRIDGE_SKIP_INIT",
        }) catch @panic("OOM");

        legacy_exe.root_module.addCSourceFiles(.{
            .root = b.path("src"),
            .files = stockfish_legacy_position_sources,
            .flags = legacy_position_compile_flags.items,
        });
    }

    exe.root_module.addCSourceFiles(.{
        .root = b.path("zig_compat"),
        .files = zig_compat_sources,
        .flags = compile_flags.items,
    });

    legacy_exe.root_module.addCSourceFiles(.{
        .root = b.path("zig_compat"),
        .files = zig_compat_sources,
        .flags = compile_flags.items,
    });

    exe.root_module.linkSystemLibrary("pthread", .{});
    exe.root_module.linkSystemLibrary("rt", .{});

    legacy_exe.root_module.linkSystemLibrary("pthread", .{});
    legacy_exe.root_module.linkSystemLibrary("rt", .{});

    b.installArtifact(exe);
    b.installArtifact(legacy_exe);

    const install_step = b.getInstallStep();

    const net_cmd = b.addSystemCommand(&.{
        "sh",
        b.pathFromRoot("scripts/net.sh"),
    });
    net_cmd.setCwd(b.path("src"));

    const net_step = b.step(
        "net",
        "Download the default NNUE net into src for external-net Zig parity",
    );
    net_step.dependOn(&net_cmd.step);

    const bench_run = b.addRunArtifact(exe);
    bench_run.step.dependOn(install_step);
    bench_run.step.dependOn(&net_cmd.step);
    bench_run.setCwd(b.path("src"));
    bench_run.addArg("bench");
    bench_run.expectStdErrMatch("Nodes searched  : ");

    const bench_step = b.step(
        "bench",
        "Run stockfish bench from src after fetching the default external NNUE net",
    );
    bench_step.dependOn(&bench_run.step);

    const uci_run = b.addRunArtifact(exe);
    uci_run.step.dependOn(install_step);
    uci_run.step.dependOn(&net_cmd.step);
    uci_run.setCwd(b.path("src"));
    uci_run.setStdIn(.{ .bytes = "uci\nquit\n" });
    // The engine routes UCI output to stderr (same convention as the bench
    // signature), so the handshake must be checked on stderr, not stdout.
    uci_run.expectStdErrMatch("id name Stockfish");
    uci_run.expectStdErrMatch("uciok");

    const uci_step = b.step(
        "uci",
        "Run a scripted UCI handshake against the Zig-built Stockfish binary",
    );
    uci_step.dependOn(&uci_run.step);

    const signature_cmd = b.addSystemCommand(&.{
        "env",
        b.fmt("STOCKFISH_BIN={s}", .{b.getInstallPath(.bin, "stockfish")}),
        "bash",
        b.pathFromRoot("tests/signature.sh"),
    });
    signature_cmd.step.dependOn(install_step);
    signature_cmd.step.dependOn(&net_cmd.step);
    signature_cmd.setCwd(b.path("src"));
    if (signature_ref) |reference|
        signature_cmd.addArg(reference);

    const signature_step = b.step(
        "signature",
        if (signature_ref != null)
            "Verify the Zig-built Stockfish bench signature through tests/signature.sh"
        else
            "Report the Zig-built Stockfish bench signature through tests/signature.sh",
    );
    signature_step.dependOn(&signature_cmd.step);

    // Per-position search-fingerprint differential harness (M5). Localizes a
    // bench-signature mismatch to a single position + drifted field, the
    // granularity the search.cpp keystone port needs to validate safely.
    const search_parity_golden = b.pathFromRoot("zig_build/tools/search_parity.golden");
    const search_parity_script = b.pathFromRoot("zig_build/tools/search_parity.sh");

    const search_parity_cmd = b.addSystemCommand(&.{
        "bash",
        search_parity_script,
        b.getInstallPath(.bin, "stockfish"),
        search_parity_golden,
        "check",
    });
    search_parity_cmd.step.dependOn(install_step);
    search_parity_cmd.step.dependOn(&net_cmd.step);
    search_parity_cmd.setCwd(b.path("src"));

    const search_parity_step = b.step(
        "search-parity",
        "Diff per-position bench search fingerprints against the committed golden",
    );
    search_parity_step.dependOn(&search_parity_cmd.step);

    const search_parity_update_cmd = b.addSystemCommand(&.{
        "bash",
        search_parity_script,
        b.getInstallPath(.bin, "stockfish"),
        search_parity_golden,
        "update",
    });
    search_parity_update_cmd.step.dependOn(install_step);
    search_parity_update_cmd.step.dependOn(&net_cmd.step);
    search_parity_update_cmd.setCwd(b.path("src"));

    const search_parity_update_step = b.step(
        "search-parity-update",
        "Regenerate zig_build/tools/search_parity.golden from the current binary",
    );
    search_parity_update_step.dependOn(&search_parity_update_cmd.step);

    // Deterministic non-bench search-mode harness (node-limit / MultiPV /
    // searchmoves) -- validates iterative_deepening control flow beyond bench.
    const search_modes_golden = b.pathFromRoot("zig_build/tools/search_modes.golden");
    const search_modes_script = b.pathFromRoot("zig_build/tools/search_modes.sh");

    const search_modes_cmd = b.addSystemCommand(&.{
        "bash", search_modes_script, b.getInstallPath(.bin, "stockfish"), search_modes_golden, "check",
    });
    search_modes_cmd.step.dependOn(install_step);
    search_modes_cmd.step.dependOn(&net_cmd.step);
    search_modes_cmd.setCwd(b.path("src"));

    const search_modes_step = b.step(
        "search-modes",
        "Diff deterministic non-bench search modes against the committed golden",
    );
    search_modes_step.dependOn(&search_modes_cmd.step);

    const search_modes_update_cmd = b.addSystemCommand(&.{
        "bash", search_modes_script, b.getInstallPath(.bin, "stockfish"), search_modes_golden, "update",
    });
    search_modes_update_cmd.step.dependOn(install_step);
    search_modes_update_cmd.step.dependOn(&net_cmd.step);
    search_modes_update_cmd.setCwd(b.path("src"));

    const search_modes_update_step = b.step(
        "search-modes-update",
        "Regenerate zig_build/tools/search_modes.golden from the current binary",
    );
    search_modes_update_step.dependOn(&search_modes_update_cmd.step);

    // Differential oracle gate (M5): assert the Zig-owned default binary and the
    // C++ legacy oracle produce identical bench signatures.
    const oracle_parity_cmd = b.addSystemCommand(&.{
        "bash",
        b.pathFromRoot("zig_build/tools/oracle_parity.sh"),
        b.getInstallPath(.bin, "stockfish"),
        b.getInstallPath(.bin, "stockfish-legacy-cpp"),
    });
    oracle_parity_cmd.step.dependOn(install_step);
    oracle_parity_cmd.step.dependOn(&net_cmd.step);
    oracle_parity_cmd.setCwd(b.path("src"));

    const oracle_parity_step = b.step(
        "oracle-parity",
        "Assert the default (Zig) and legacy (C++) bench signatures are identical",
    );
    oracle_parity_step.dependOn(&oracle_parity_cmd.step);

    // Full-output differential gate (M5): diff the bench UCI info+bestmove text
    // (time/nps stripped) between the default (Zig) binary and the legacy (C++)
    // oracle. Catches info-line drift the signature/bestmove gates miss -- the
    // regression catcher for porting SearchManager::pv and the driver output.
    const output_parity_cmd = b.addSystemCommand(&.{
        "bash",
        b.pathFromRoot("zig_build/tools/output_parity.sh"),
        b.getInstallPath(.bin, "stockfish"),
        b.getInstallPath(.bin, "stockfish-legacy-cpp"),
    });
    output_parity_cmd.step.dependOn(install_step);
    output_parity_cmd.step.dependOn(&net_cmd.step);
    output_parity_cmd.setCwd(b.path("src"));

    const output_parity_step = b.step(
        "output-parity",
        "Assert the default (Zig) and legacy (C++) bench info-line output is identical",
    );
    output_parity_step.dependOn(&output_parity_cmd.step);

    // Full-output GOLDEN gate (Stage-7 7.0a, H8): same stripped bench info+bestmove
    // text as output-parity, but pinned against a committed golden instead of the
    // legacy oracle, so it survives oracle deletion (Annex B B.4). The golden is
    // captured while the oracle still exists; output-parity proves golden == oracle.
    const output_golden = b.pathFromRoot("zig_build/tools/output_parity.golden");
    const output_golden_cmd = b.addSystemCommand(&.{
        "bash",
        b.pathFromRoot("zig_build/tools/output_parity_golden.sh"),
        b.getInstallPath(.bin, "stockfish"),
        output_golden,
        "check",
    });
    output_golden_cmd.step.dependOn(install_step);
    output_golden_cmd.step.dependOn(&net_cmd.step);
    output_golden_cmd.setCwd(b.path("src"));

    const output_golden_step = b.step(
        "output-golden",
        "Assert the default (Zig) bench info-line output matches the committed golden",
    );
    output_golden_step.dependOn(&output_golden_cmd.step);

    const output_golden_update_cmd = b.addSystemCommand(&.{
        "bash",
        b.pathFromRoot("zig_build/tools/output_parity_golden.sh"),
        b.getInstallPath(.bin, "stockfish"),
        output_golden,
        "update",
    });
    output_golden_update_cmd.step.dependOn(install_step);
    output_golden_update_cmd.step.dependOn(&net_cmd.step);
    output_golden_update_cmd.setCwd(b.path("src"));

    const output_golden_update_step = b.step(
        "output-golden-update",
        "Regenerate zig_build/tools/output_parity.golden from the current binary",
    );
    output_golden_update_step.dependOn(&output_golden_update_cmd.step);

    // Thread-runtime stress / liveness harness (H2, REPORT-9 big-bang plan).
    // Hammers (ucinewgame -> setoption Threads -> go/stop) cycles across thread
    // counts + a construct/destroy churn, under a wall-clock watchdog. A liveness
    // gate (no hang / crash / lost search), not a determinism gate -- the
    // regression net the native stage-4 thread runtime must still pass. Kept out
    // of the core `parity` aggregate (slower, wall-clock-timed); run explicitly
    // for any thread-runtime slice.
    const stress_cmd = b.addSystemCommand(&.{
        "bash",
        b.pathFromRoot("zig_build/tools/stress.sh"),
        b.getInstallPath(.bin, "stockfish"),
    });
    stress_cmd.step.dependOn(install_step);
    stress_cmd.step.dependOn(&net_cmd.step);
    stress_cmd.setCwd(b.path("src"));

    const stress_step = b.step(
        "parity-stress",
        "Thread-runtime stress/liveness: go/stop storms + construct/destroy churn",
    );
    stress_step.dependOn(&stress_cmd.step);

    // Memory-error / leak gate (H3, REPORT-9 big-bang plan): Valgrind memcheck
    // over short multi-thread sessions, asserting no invalid access / bad free /
    // definite leak (uninit-value checking off -- NNUE SIMD makes it false-noisy).
    // The ASan/LSan-equivalent net for the native Worker/large-page lifecycle and
    // the stage-4 cut. (TSan/race detection is deferred to stage 4: meaningful
    // only for the native futex runtime; the current C++ runtime has benign TT
    // data races by design.) Out of the core `parity` aggregate (slow).
    const valgrind_cmd = b.addSystemCommand(&.{
        "bash",
        b.pathFromRoot("zig_build/tools/valgrind.sh"),
        b.getInstallPath(.bin, "stockfish"),
    });
    valgrind_cmd.step.dependOn(install_step);
    valgrind_cmd.step.dependOn(&net_cmd.step);
    valgrind_cmd.setCwd(b.path("src"));

    const valgrind_step = b.step(
        "parity-valgrind",
        "Valgrind memcheck (leak / invalid-access / bad-free) across thread counts",
    );
    valgrind_step.dependOn(&valgrind_cmd.step);

    // Multi-thread search sanity (H1, REPORT-9 big-bang plan). Multi-threaded
    // search is non-deterministic (Lazy SMP), so this is a tolerance gate, not a
    // bit-exact golden: at fixed depth on calm positions, Threads {2,4} must emit
    // a well-formed bestmove and a score of the same kind/sign within a generous
    // cp band of the deterministic single-thread reference. Anchors gross
    // multi-thread behaviour against the live C++ runtime before stage 4 swaps it;
    // catches a native runtime that runs but corrupts result aggregation. Out of
    // the core `parity` aggregate (non-deterministic, sleep-paced).
    const mt_golden = b.pathFromRoot("zig_build/tools/mt_sanity.golden");
    const mt_script = b.pathFromRoot("zig_build/tools/mt_sanity.sh");

    const mt_cmd = b.addSystemCommand(&.{
        "bash", mt_script, b.getInstallPath(.bin, "stockfish"), mt_golden, "check",
    });
    mt_cmd.step.dependOn(install_step);
    mt_cmd.step.dependOn(&net_cmd.step);
    mt_cmd.setCwd(b.path("src"));

    const mt_step = b.step(
        "parity-mt",
        "Multi-thread search sanity: Threads {2,4} score-band vs single-thread golden",
    );
    mt_step.dependOn(&mt_cmd.step);

    const mt_update_cmd = b.addSystemCommand(&.{
        "bash", mt_script, b.getInstallPath(.bin, "stockfish"), mt_golden, "update",
    });
    mt_update_cmd.step.dependOn(install_step);
    mt_update_cmd.step.dependOn(&net_cmd.step);
    mt_update_cmd.setCwd(b.path("src"));

    const mt_update_step = b.step(
        "parity-mt-update",
        "Regenerate zig_build/tools/mt_sanity.golden (single-thread reference)",
    );
    mt_update_step.dependOn(&mt_update_cmd.step);

    // Leak gate for the std::vector lifecycle stage 5 ports (H5, REPORT-9 plan):
    // Valgrind memcheck over a `go searchmoves` + ucinewgame churn, asserting no
    // definite leak / bad free of limits.searchmoves and worker.rootMoves -- the
    // path bench never exercises. Reads the verdict from valgrind's summary and
    // tolerates the known post-exit thread-join hang under memcheck. Out of the
    // core `parity` aggregate (slow).
    const teardown_cmd = b.addSystemCommand(&.{
        "bash",
        b.pathFromRoot("zig_build/tools/teardown.sh"),
        b.getInstallPath(.bin, "stockfish"),
    });
    teardown_cmd.step.dependOn(install_step);
    teardown_cmd.step.dependOn(&net_cmd.step);
    teardown_cmd.setCwd(b.path("src"));

    const teardown_step = b.step(
        "parity-teardown",
        "Valgrind leak gate for searchmoves/rootMoves vector lifecycle + Worker clear",
    );
    teardown_step.dependOn(&teardown_cmd.step);

    const parity_step = b.step(
        "parity",
        "Run the current bench, UCI, and signature checks through the Zig build entry",
    );
    parity_step.dependOn(&bench_run.step);
    parity_step.dependOn(&uci_run.step);
    parity_step.dependOn(&signature_cmd.step);
    parity_step.dependOn(&search_parity_cmd.step);
    parity_step.dependOn(&search_modes_cmd.step);
    parity_step.dependOn(&oracle_parity_cmd.step);
    parity_step.dependOn(&output_parity_cmd.step);
    parity_step.dependOn(&output_golden_cmd.step);

    const stockfish_step = b.step(
        "stockfish",
        "Build the imported Stockfish C++ engine for Linux x86_64",
    );
    stockfish_step.dependOn(install_step);

    const legacy_install = b.addInstallArtifact(legacy_exe, .{});
    const legacy_stockfish_step = b.step(
        "stockfish-legacy-cpp",
        "Build the optional legacy C++ fallback engine target",
    );
    legacy_stockfish_step.dependOn(&legacy_install.step);
}

fn applyMacros(module: *std.Build.Module, macros: []const Macro) void {
    for (macros) |macro|
        module.addCMacro(macro.name, macro.value);
}

fn resolveArch(b: *std.Build, requested_arch: []const u8) ArchConfig {
    const arch_name = if (std.mem.eql(u8, requested_arch, "native"))
        trimOutput(b.run(&.{ "sh", b.pathFromRoot("scripts/get_native_properties.sh") }))
    else
        requested_arch;

    return archConfigFor(arch_name);
}

fn archConfigFor(arch_name: []const u8) ArchConfig {
    if (std.mem.eql(u8, arch_name, "x86-64"))
        return .{
            .name = "x86-64",
            .flags = &.{ "-msse", "-msse2" },
            .macros = &.{
                .{ .name = "USE_SSE2", .value = "1" },
            },
            .target_features = std.Target.x86.featureSet(&.{
                .sse2,
            }),
        };

    if (std.mem.eql(u8, arch_name, "x86-64-sse3-popcnt"))
        return .{
            .name = "x86-64-sse3-popcnt",
            .flags = &.{ "-msse", "-msse2", "-msse3", "-mpopcnt" },
            .macros = &.{
                .{ .name = "USE_SSE2", .value = "1" },
                .{ .name = "USE_POPCNT", .value = "1" },
            },
            .target_features = std.Target.x86.featureSet(&.{
                .sse2,
                .sse3,
                .popcnt,
            }),
        };

    if (std.mem.eql(u8, arch_name, "x86-64-ssse3"))
        return .{
            .name = "x86-64-ssse3",
            .flags = &.{ "-msse", "-msse2", "-mssse3" },
            .macros = &.{
                .{ .name = "USE_SSE2", .value = "1" },
                .{ .name = "USE_SSSE3", .value = "1" },
            },
            .target_features = std.Target.x86.featureSet(&.{
                .sse2,
                .sse3,
                .ssse3,
            }),
        };

    if (std.mem.eql(u8, arch_name, "x86-64-modern") or
        std.mem.eql(u8, arch_name, "x86-64-sse41-popcnt"))
        return .{
            .name = "x86-64-sse41-popcnt",
            .flags = &.{
                "-msse",
                "-msse2",
                "-msse3",
                "-mpopcnt",
                "-mssse3",
                "-msse4.1",
            },
            .macros = &.{
                .{ .name = "USE_SSE2", .value = "1" },
                .{ .name = "USE_POPCNT", .value = "1" },
                .{ .name = "USE_SSSE3", .value = "1" },
                .{ .name = "USE_SSE41", .value = "1" },
            },
            .target_features = std.Target.x86.featureSet(&.{
                .sse2,
                .sse3,
                .ssse3,
                .sse4_1,
                .popcnt,
            }),
        };

    if (std.mem.eql(u8, arch_name, "x86-64-avx2"))
        return .{
            .name = "x86-64-avx2",
            .flags = &.{
                "-msse",
                "-msse2",
                "-msse3",
                "-mpopcnt",
                "-mssse3",
                "-msse4.1",
                "-mavx2",
                "-mbmi",
            },
            .macros = &.{
                .{ .name = "USE_SSE2", .value = "1" },
                .{ .name = "USE_POPCNT", .value = "1" },
                .{ .name = "USE_SSSE3", .value = "1" },
                .{ .name = "USE_SSE41", .value = "1" },
                .{ .name = "USE_AVX2", .value = "1" },
            },
            .target_features = std.Target.x86.featureSet(&.{
                .sse2,
                .sse3,
                .ssse3,
                .sse4_1,
                .popcnt,
                .avx2,
                .bmi,
            }),
        };

    if (std.mem.eql(u8, arch_name, "x86-64-bmi2"))
        return .{
            .name = "x86-64-bmi2",
            .flags = &.{
                "-msse",
                "-msse2",
                "-msse3",
                "-mpopcnt",
                "-mssse3",
                "-msse4.1",
                "-mavx2",
                "-mbmi",
                "-mbmi2",
            },
            .macros = &.{
                .{ .name = "USE_SSE2", .value = "1" },
                .{ .name = "USE_POPCNT", .value = "1" },
                .{ .name = "USE_SSSE3", .value = "1" },
                .{ .name = "USE_SSE41", .value = "1" },
                .{ .name = "USE_AVX2", .value = "1" },
                .{ .name = "USE_PEXT", .value = "1" },
                .{ .name = "USE_COMPTIME_ATTACKS", .value = "1" },
            },
            .target_features = std.Target.x86.featureSet(&.{
                .sse2,
                .sse3,
                .ssse3,
                .sse4_1,
                .popcnt,
                .avx2,
                .bmi,
                .bmi2,
            }),
        };

    if (std.mem.eql(u8, arch_name, "x86-64-avxvnni"))
        return .{
            .name = "x86-64-avxvnni",
            .flags = &.{
                "-msse",
                "-msse2",
                "-msse3",
                "-mpopcnt",
                "-mssse3",
                "-msse4.1",
                "-mavx2",
                "-mbmi",
                "-mavxvnni",
                "-mbmi2",
            },
            .macros = &.{
                .{ .name = "USE_SSE2", .value = "1" },
                .{ .name = "USE_POPCNT", .value = "1" },
                .{ .name = "USE_SSSE3", .value = "1" },
                .{ .name = "USE_SSE41", .value = "1" },
                .{ .name = "USE_AVX2", .value = "1" },
                .{ .name = "USE_VNNI", .value = "1" },
                .{ .name = "USE_AVXVNNI", .value = "1" },
                .{ .name = "USE_PEXT", .value = "1" },
                .{ .name = "USE_COMPTIME_ATTACKS", .value = "1" },
            },
            .target_features = std.Target.x86.featureSet(&.{
                .sse2,
                .sse3,
                .ssse3,
                .sse4_1,
                .popcnt,
                .avx2,
                .bmi,
                .bmi2,
                .avxvnni,
            }),
        };

    if (std.mem.eql(u8, arch_name, "x86-64-avx512"))
        return .{
            .name = "x86-64-avx512",
            .flags = &.{
                "-msse",
                "-msse2",
                "-msse3",
                "-mpopcnt",
                "-mssse3",
                "-msse4.1",
                "-mavx2",
                "-mbmi",
                "-mbmi2",
                "-mavx512f",
                "-mavx512bw",
                "-mavx512dq",
                "-mavx512vl",
            },
            .macros = &.{
                .{ .name = "USE_SSE2", .value = "1" },
                .{ .name = "USE_POPCNT", .value = "1" },
                .{ .name = "USE_SSSE3", .value = "1" },
                .{ .name = "USE_SSE41", .value = "1" },
                .{ .name = "USE_AVX2", .value = "1" },
                .{ .name = "USE_AVX512", .value = "1" },
                .{ .name = "USE_PEXT", .value = "1" },
                .{ .name = "USE_COMPTIME_ATTACKS", .value = "1" },
            },
            .target_features = std.Target.x86.featureSet(&.{
                .sse2,
                .sse3,
                .ssse3,
                .sse4_1,
                .popcnt,
                .avx2,
                .bmi,
                .bmi2,
                .avx512f,
                .avx512bw,
                .avx512dq,
                .avx512vl,
            }),
        };

    if (std.mem.eql(u8, arch_name, "x86-64-vnni512"))
        return .{
            .name = "x86-64-vnni512",
            .flags = &.{
                "-msse",
                "-msse2",
                "-msse3",
                "-mpopcnt",
                "-mssse3",
                "-msse4.1",
                "-mavx2",
                "-mbmi",
                "-mbmi2",
                "-mavx512f",
                "-mavx512bw",
                "-mavx512vnni",
                "-mavx512dq",
                "-mavx512vl",
            },
            .macros = &.{
                .{ .name = "USE_SSE2", .value = "1" },
                .{ .name = "USE_POPCNT", .value = "1" },
                .{ .name = "USE_SSSE3", .value = "1" },
                .{ .name = "USE_SSE41", .value = "1" },
                .{ .name = "USE_AVX2", .value = "1" },
                .{ .name = "USE_AVX512", .value = "1" },
                .{ .name = "USE_VNNI", .value = "1" },
                .{ .name = "USE_PEXT", .value = "1" },
                .{ .name = "USE_COMPTIME_ATTACKS", .value = "1" },
            },
            .target_features = std.Target.x86.featureSet(&.{
                .sse2,
                .sse3,
                .ssse3,
                .sse4_1,
                .popcnt,
                .avx2,
                .bmi,
                .bmi2,
                .avx512f,
                .avx512bw,
                .avx512dq,
                .avx512vl,
                .avx512vnni,
            }),
        };

    if (std.mem.eql(u8, arch_name, "x86-64-avx512icl"))
        return .{
            .name = "x86-64-avx512icl",
            .flags = &.{
                "-msse",
                "-msse2",
                "-msse3",
                "-mpopcnt",
                "-mssse3",
                "-msse4.1",
                "-mavx2",
                "-mbmi",
                "-mbmi2",
                "-mavx512f",
                "-mavx512cd",
                "-mavx512vl",
                "-mavx512dq",
                "-mavx512bw",
                "-mavx512ifma",
                "-mavx512vbmi",
                "-mavx512vbmi2",
                "-mavx512vpopcntdq",
                "-mavx512bitalg",
                "-mavx512vnni",
                "-mvpclmulqdq",
                "-mgfni",
                "-mvaes",
            },
            .macros = &.{
                .{ .name = "USE_SSE2", .value = "1" },
                .{ .name = "USE_POPCNT", .value = "1" },
                .{ .name = "USE_SSSE3", .value = "1" },
                .{ .name = "USE_SSE41", .value = "1" },
                .{ .name = "USE_AVX2", .value = "1" },
                .{ .name = "USE_AVX512", .value = "1" },
                .{ .name = "USE_VNNI", .value = "1" },
                .{ .name = "USE_AVX512ICL", .value = "1" },
                .{ .name = "USE_PEXT", .value = "1" },
                .{ .name = "USE_COMPTIME_ATTACKS", .value = "1" },
            },
            .target_features = std.Target.x86.featureSet(&.{
                .sse2,
                .sse3,
                .ssse3,
                .sse4_1,
                .popcnt,
                .avx2,
                .bmi,
                .bmi2,
                .avx512f,
                .avx512cd,
                .avx512vl,
                .avx512dq,
                .avx512bw,
                .avx512ifma,
                .avx512vbmi,
                .avx512vbmi2,
                .avx512vpopcntdq,
                .avx512bitalg,
                .avx512vnni,
                .vpclmulqdq,
                .gfni,
                .vaes,
            }),
        };

    std.process.fatal(
        "unsupported ARCH '{s}' for the current Linux x86_64 Zig parity slice",
        .{arch_name},
    );
}

fn hasMacro(macros: []const Macro, name: []const u8) bool {
    for (macros) |macro| {
        if (std.mem.eql(u8, macro.name, name)) {
            return true;
        }
    }

    return false;
}

fn readGitInfo(b: *std.Build) GitInfo {
    const repo_root = b.pathFromRoot(".");

    return .{
        .sha = runAndTrimOrNull(b, &.{ "git", "-C", repo_root, "rev-parse", "--short=8", "HEAD" }),
        .date = runAndTrimOrNull(
            b,
            &.{
                "git",
                "-C",
                repo_root,
                "show",
                "-s",
                "--date=format:%Y%m%d",
                "--format=%cd",
                "HEAD",
            },
        ),
    };
}

fn runAndTrimOrNull(b: *std.Build, argv: []const []const u8) ?[]const u8 {
    var code: u8 = undefined;
    const output = b.runAllowFail(argv, &code, .ignore) catch return null;
    const trimmed = trimOutput(output);
    if (trimmed.len == 0)
        return null;
    return trimmed;
}

fn trimOutput(output: []const u8) []const u8 {
    return std.mem.trim(u8, output, &std.ascii.whitespace);
}
