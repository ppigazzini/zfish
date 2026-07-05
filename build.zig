const std = @import("std");

const Macro = struct {
    name: []const u8,
    value: []const u8,
};

// Owned runtime OSes (M-PORT). Selected with -Dos=; each maps to an (os_tag, abi) pair
// in build(). Orthogonal to -Darch= (the ISA tier), so any arch tier can target any OS.
const TargetOs = enum { linux, windows, macos };

const ArchConfig = struct {
    name: []const u8,
    flags: []const []const u8,
    macros: []const Macro,
    target_features: std.Target.Cpu.Feature.Set,
    // Owned runtime is x86_64 by default; non-x86 tiers (M15.5) set this so the pure
    // Zig @Vector NNUE cross-compiles to that ISA (LLVM lowers to NEON/etc). The C++
    // differential oracle is x86-only and is skipped off x86_64.
    cpu_arch: std.Target.Cpu.Arch = .x86_64,
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
    // Owned runtime targets (M-PORT): Linux (default), Windows, and macOS. The pure-Zig
    // engine is OS-portable behind a thin platform seam -- sync (thread_runtime.zig futex
    // seam), aligned/large-page allocation (memory.zig), the steady clock and CPU-affinity
    // string (main.zig). Windows uses the self-contained mingw (gnu) ABI so no MSVC/SDK is
    // needed; macOS uses its native ABI. The integer-exact NNUE eval is arch/OS-invariant,
    // so bench must be 2067208 on every (arch, os) tier -- the parity lanes assert it.
    const os_choice = b.option(TargetOs, "os", "Target OS: linux (default), windows, or macos") orelse .linux;
    const os_tag: std.Target.Os.Tag = switch (os_choice) {
        .linux => .linux,
        .windows => .windows,
        .macos => .macos,
    };
    const abi: std.Target.Abi = switch (os_choice) {
        .linux => .gnu,
        .windows => .gnu, // mingw: self-contained, ships with Zig (no Visual Studio / Windows SDK)
        .macos => .none, // macOS has a single system ABI (libSystem); no gnu/musl split
    };
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
        .cpu_arch = arch.cpu_arch,
        .cpu_model = .baseline,
        .cpu_features_add = arch.target_features,
        .os_tag = os_tag,
        .abi = abi,
    });

    const exe = b.addExecutable(.{
        .name = "stockfish",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            // No .link_libcpp: the engine compiles zero C++ TUs (TU=0), so the C++
            // stdlib is dead weight. (The retired in-tree oracle was the only linker
            // of it; REPORT-16 M16.1.)
        }),
    });

    // Thin libc binding shared by the files that used to each @cImport <stdio.h> etc.
    // (REPORT-16). Imported as `libc` wherever a module says `const c = @import("libc")`.
    const libc_module = b.createModule(.{
        .root_source_file = b.path("src/libc.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Aligned/large-page allocator as a shared module (REPORT-16 M16.5): consumers call it
    // directly instead of round-tripping through main.zig's C-ABI `zfish_aligned_large_pages_*`
    // exports (dead scaffolding now the C++ oracle is retired).
    const memory_module = b.createModule(.{
        .root_source_file = b.path("src/memory.zig"),
        .target = target,
        .optimize = optimize,
    });

    // M16.2b/M16.5: typed engine-graph views (ThreadPool/Worker/... offset structs), imported
    // by the modules that used to reach the graph through main.zig C-ABI glue.
    const tablebase_module = b.createModule(.{
        .root_source_file = b.path("src/support/tablebase.zig"),
        .target = target,
        .optimize = optimize,
    });
    const clock_module = b.createModule(.{
        .root_source_file = b.path("src/support/clock.zig"),
        .target = target,
        .optimize = optimize,
    });
    const uci_output_module = b.createModule(.{
        .root_source_file = b.path("src/support/uci_output.zig"),
        .target = target,
        .optimize = optimize,
    });
    const numa_module = b.createModule(.{
        .root_source_file = b.path("src/support/numa.zig"),
        .target = target,
        .optimize = optimize,
    });
    const graph_layout_module = b.createModule(.{
        .root_source_file = b.path("src/graph_layout.zig"),
        .target = target,
        .optimize = optimize,
    });

    const native_engine_module = b.createModule(.{
        .root_source_file = b.path("src/native_engine.zig"),
        .target = target,
        .optimize = optimize,
    });

    const timeman_module = b.createModule(.{
        .root_source_file = b.path("src/time/timeman.zig"),
        .target = target,
        .optimize = optimize,
    });
    const benchmark_source_files = b.addWriteFiles();
    // REPORT-12 TU=0: the bench positions are embedded from an in-repo copy (src/bench),
    // so the native build depends on NOTHING from the old src/ tree at build time. The only
    // external artifact is the NNUE net, fetched into net/ and read from cwd at runtime.
    _ = benchmark_source_files.addCopyFile(b.path("src/bench/benchmark.cpp"), "benchmark.cpp");
    const benchmark_source_module = benchmark_source_files.add(
        "benchmark_source_data.zig",
        "pub const source = @embedFile(\"benchmark.cpp\");\n",
    );
    const benchmark_module = b.createModule(.{
        .root_source_file = b.path("src/bench/benchmark.zig"),
        .target = target,
        .optimize = optimize,
    });
    benchmark_module.addAnonymousImport("benchmark_source_data", .{
        .root_source_file = benchmark_source_module,
    });
    const misc_module = b.createModule(.{
        .root_source_file = b.path("src/support/misc.zig"),
        .target = target,
        .optimize = optimize,
    });
    misc_module.addImport("build_options", build_options_module);
    const engine_module_default = b.createModule(.{
        .root_source_file = b.path("src/support/engine.zig"),
        .target = target,
        .optimize = optimize,
    });
    const uci_move_module = b.createModule(.{
        .root_source_file = b.path("src/support/uci_move.zig"),
        .target = target,
        .optimize = optimize,
    });
    const movepick_module = b.createModule(.{
        .root_source_file = b.path("src/support/movepick.zig"),
        .target = target,
        .optimize = optimize,
    });
    const search_module = b.createModule(.{
        .root_source_file = b.path("src/support/search.zig"),
        .target = target,
        .optimize = optimize,
    });
    const thread_module_default = b.createModule(.{
        .root_source_file = b.path("src/support/thread.zig"),
        .target = target,
        .optimize = optimize,
    });
    const tt_module = b.createModule(.{
        .root_source_file = b.path("src/support/tt.zig"),
        .target = target,
        .optimize = optimize,
    });
    const option_module = b.createModule(.{
        .root_source_file = b.path("src/uci/option.zig"),
        .target = target,
        .optimize = optimize,
    });
    const bitboard_module = b.createModule(.{
        .root_source_file = b.path("src/board/bitboard.zig"),
        .target = target,
        .optimize = optimize,
    });
    const position_module = b.createModule(.{
        .root_source_file = b.path("src/board/position.zig"),
        .target = target,
        .optimize = optimize,
    });
    const position_snapshot_module = b.createModule(.{
        .root_source_file = b.path("src/board/position_snapshot.zig"),
        .target = target,
        .optimize = optimize,
    });
    const movegen_module = b.createModule(.{
        .root_source_file = b.path("src/board/movegen.zig"),
        .target = target,
        .optimize = optimize,
    });
    const nnue_feature_module = b.createModule(.{
        .root_source_file = b.path("src/eval/nnue_feature.zig"),
        .target = target,
        .optimize = optimize,
    });
    const uci_module = b.createModule(.{
        .root_source_file = b.path("src/uci/uci.zig"),
        .target = target,
        .optimize = optimize,
    });
    const evaluate_module = b.createModule(.{
        .root_source_file = b.path("src/eval/evaluate.zig"),
        .target = target,
        .optimize = optimize,
    });
    const nnue_accumulator_module = b.createModule(.{
        .root_source_file = b.path("src/eval/nnue_accumulator.zig"),
        .target = target,
        .optimize = optimize,
    });
    const network_module = b.createModule(.{
        .root_source_file = b.path("src/eval/network.zig"),
        .target = target,
        .optimize = optimize,
    });
    const nnue_misc_module = b.createModule(.{
        .root_source_file = b.path("src/eval/nnue_misc.zig"),
        .target = target,
        .optimize = optimize,
    });
    // Native StateList (the post-src/ `states` deque replacement, native-graph cut);
    // its own module so engine_graph.zig can hold it as a typed member.
    const state_list_module = b.createModule(.{
        .root_source_file = b.path("src/board/state_list.zig"),
        .target = target,
        .optimize = optimize,
    });
    // Native NumaConfig (the post-src/ numaContext member, native-graph cut).
    const numa_config_module = b.createModule(.{
        .root_source_file = b.path("src/support/numa_config.zig"),
        .target = target,
        .optimize = optimize,
    });
    // Native NumaReplicationContext (the `numa_context` member; B2 switch).
    const numa_replication_module = b.createModule(.{
        .root_source_file = b.path("src/support/numa_replication.zig"),
        .target = target,
        .optimize = optimize,
    });
    numa_replication_module.addImport("numa_config", numa_config_module);
    // Native PositionStorage (post-src/ owner of the `pos` member's 1032B block).
    const position_storage_module = b.createModule(.{
        .root_source_file = b.path("src/board/position_storage.zig"),
        .target = target,
        .optimize = optimize,
    });
    // Native SharedHistories sizing (the `shared_histories` member, pure count logic).
    const shared_histories_module = b.createModule(.{
        .root_source_file = b.path("src/support/shared_histories.zig"),
        .target = target,
        .optimize = optimize,
    });
    position_module.addImport("nnue_accumulator", nnue_accumulator_module);
    position_module.addImport("evaluate", evaluate_module);
    position_module.addImport("shared_histories", shared_histories_module);
    // Native sharedHists map container (the `sharedHists` member type), instantiated in
    // position.zig with the real SharedHistories.
    const shared_histories_map_module = b.createModule(.{
        .root_source_file = b.path("src/support/shared_histories_map.zig"),
        .target = target,
        .optimize = optimize,
    });
    position_module.addImport("shared_histories_map", shared_histories_map_module);
    // Native network holder (the `network` member: LazyNumaReplicated<Network> shape +
    // replica-count shadow verifier).
    const network_holder_module = b.createModule(.{
        .root_source_file = b.path("src/support/network_holder.zig"),
        .target = target,
        .optimize = optimize,
    });

    // For the native engine-graph scaffolding (engine_graph.zig) compiled via the
    // engine module: it binds the native ThreadPool and TranspositionTable.
    engine_module_default.addImport("position", position_module);
    engine_module_default.addImport("position_snapshot", position_snapshot_module);
    engine_module_default.addImport("uci_move", uci_move_module);
    engine_module_default.addImport("misc", misc_module);
    engine_module_default.addImport("thread", thread_module_default);
    native_engine_module.addImport("graph_layout", graph_layout_module);
    native_engine_module.addImport("misc", misc_module);
    native_engine_module.addImport("state_list", state_list_module);
    native_engine_module.addImport("network", network_module);
    engine_module_default.addImport("native_engine", native_engine_module);
    engine_module_default.addImport("numa", numa_module);
    thread_module_default.addImport("numa", numa_module);
    exe.root_module.addImport("native_engine", native_engine_module);
    engine_module_default.addImport("tt", tt_module);
    engine_module_default.addImport("state_list", state_list_module);
    engine_module_default.addImport("numa_config", numa_config_module);
    engine_module_default.addImport("numa_replication", numa_replication_module);
    engine_module_default.addImport("position_storage", position_storage_module);
    // engine.zig single-sources default_eval_file_name from network.zig
    // (network has no engine dep, so this edge is acyclic).
    engine_module_default.addImport("network", network_module);
    engine_module_default.addImport("nnue_accumulator", nnue_accumulator_module);
    engine_module_default.addImport("evaluate", evaluate_module);
    engine_module_default.addImport("nnue_misc", nnue_misc_module);

    // Native-graph cut: run the EngineGraph + member-module unit tests (construction,
    // lifetime, SharedState binding) with their module deps. `zig build test-graph`.
    const graph_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/support/engine_graph.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    graph_test.root_module.addImport("thread", thread_module_default);
    graph_test.root_module.addImport("tt", tt_module);
    graph_test.root_module.addImport("state_list", state_list_module);
    graph_test.root_module.addImport("numa_config", numa_config_module);
    graph_test.root_module.addImport("numa_replication", numa_replication_module);
    graph_test.root_module.addImport("position_storage", position_storage_module);
    const graph_test_step = b.step("test-graph", "Run the native-graph (cut) unit tests");
    graph_test_step.dependOn(&b.addRunArtifact(graph_test).step);
    // B2 switch: native NumaReplicationContext (numaContext member) — tests need the
    // numa_config dep, so they run via test-graph rather than standalone.
    const numa_repl_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/support/numa_replication.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    numa_repl_test.root_module.addImport("numa_config", numa_config_module);
    graph_test_step.dependOn(&b.addRunArtifact(numa_repl_test).step);
    // B2 switch: native sharedHists map container (std-only generic; tested with a mock
    // entry). board/position.zig instantiates it with the real SharedHistories.
    const sh_map_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/support/shared_histories_map.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    graph_test_step.dependOn(&b.addRunArtifact(sh_map_test).step);

    uci_move_module.addImport("position_snapshot", position_snapshot_module);
    movepick_module.addImport("position_snapshot", position_snapshot_module);
    movepick_module.addImport("bitboard", bitboard_module);
    movepick_module.addImport("movegen", movegen_module);
    movegen_module.addImport("position_snapshot", position_snapshot_module);
    movegen_module.addImport("bitboard", bitboard_module);
    nnue_accumulator_module.addImport("position_snapshot", position_snapshot_module);
    nnue_accumulator_module.addImport("nnue_feature", nnue_feature_module);
    position_module.addImport("bitboard", bitboard_module);
    position_module.addImport("movegen", movegen_module);
    position_module.addImport("tt", tt_module);
    position_module.addImport("movepick", movepick_module);
    position_module.addImport("search", search_module);
    thread_module_default.addImport("position_snapshot", position_snapshot_module);
    thread_module_default.addImport("position", position_module);
    thread_module_default.addImport("uci_move", uci_move_module);
    uci_module.addImport("benchmark", benchmark_module);
    uci_module.addImport("misc", misc_module);
    uci_module.addImport("engine", engine_module_default); // M16.5: direct engine calls
    uci_module.addImport("option", option_module);
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
    exe.root_module.addImport("network_holder", network_holder_module);
    exe.root_module.addImport("state_list", state_list_module);
    exe.root_module.addImport("numa_config", numa_config_module);
    exe.root_module.addImport("position_storage", position_storage_module);
    exe.root_module.addImport("option", option_module);
    exe.root_module.addImport("position", position_module);
    exe.root_module.addImport("position_snapshot", position_snapshot_module);
    exe.root_module.addImport("search", search_module);
    exe.root_module.addImport("timeman", timeman_module);
    exe.root_module.addImport("thread", thread_module_default);
    exe.root_module.addImport("tt", tt_module);
    exe.root_module.addImport("uci", uci_module);
    exe.root_module.addImport("uci_move", uci_move_module);

    // REPORT-16: the thin libc binding, for every module that replaced an @cImport with
    // `const c = @import("libc")` (main + the 8 files below; misc keeps its own @cImport
    // until its compiler-macro reads are ported to Zig build info).
    exe.root_module.addImport("libc", libc_module);
    benchmark_module.addImport("libc", libc_module);
    uci_module.addImport("libc", libc_module);
    misc_module.addImport("libc", libc_module);
    engine_module_default.addImport("libc", libc_module);
    thread_module_default.addImport("libc", libc_module);

    // M16.5: direct callers of the aligned/large-page allocator.
    exe.root_module.addImport("memory", memory_module);
    exe.root_module.addImport("graph_layout", graph_layout_module);
    exe.root_module.addImport("clock", clock_module);
    exe.root_module.addImport("uci_output", uci_output_module);
    uci_output_module.addImport("libc", libc_module);
    engine_module_default.addImport("uci_output", uci_output_module);
    tt_module.addImport("memory", memory_module);
    position_module.addImport("memory", memory_module);
    position_module.addImport("option", option_module);
    position_module.addImport("timeman", timeman_module);
    misc_module.addImport("memory", memory_module);
    tt_module.addImport("graph_layout", graph_layout_module);
    tt_module.addImport("thread", thread_module_default);
    thread_module_default.addImport("graph_layout", graph_layout_module);
    engine_module_default.addImport("graph_layout", graph_layout_module);
    thread_module_default.addImport("movegen", movegen_module);
    uci_move_module.addImport("movegen", movegen_module);
    uci_move_module.addImport("position", position_module);
    thread_module_default.addImport("tablebase", tablebase_module);
    thread_module_default.addImport("option", option_module);
    thread_module_default.addImport("state_list", state_list_module);
    engine_module_default.addImport("tablebase", tablebase_module);
    engine_module_default.addImport("option", option_module);
    position_module.addImport("clock", clock_module);
    position_module.addImport("graph_layout", graph_layout_module);
    network_module.addImport("libc", libc_module);
    network_module.addImport("memory", memory_module);
    network_module.addImport("graph_layout", graph_layout_module);
    network_module.addImport("nnue_accumulator", nnue_accumulator_module);
    // network no longer imports position (broke the network->position cycle, M16.7):
    // its two Position field reads go through the leaf graph_layout. That frees
    // position -> network for the direct eval call below.
    position_module.addImport("network", network_module);
    nnue_misc_module.addImport("libc", libc_module);
    evaluate_module.addImport("libc", libc_module);

    // REPORT-12 TU=0 / REPORT-16 M16.1: the shipped engine compiles zero C++ TUs and
    // the in-tree C++ oracle is retired, so the whole C++ toolchain (compile flags,
    // src/ + zig_compat/ sources, include paths, C macros) is gone. These addCMacro
    // calls are dead now (no C TU consumes them) but harmless; dropped with the last
    // interop in a later milestone.
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

    // pthread + librt are Linux-only: on macOS the pthread + realtime-clock symbols live
    // in libSystem (pulled in by link_libc), and on Windows threading/sync is Win32 and
    // there is no librt. link_libc already provides the C runtime (ucrt via mingw) the
    // aligned allocator needs on Windows.
    if (os_tag == .linux) {
        exe.root_module.linkSystemLibrary("pthread", .{});
        exe.root_module.linkSystemLibrary("rt", .{});
    }

    b.installArtifact(exe);

    const install_step = b.getInstallStep();

    // Fetch the net the Zig binary actually loads (network.zig's default_eval_file_name -- the single
    // source of truth engine.zig imports), not the net named in the stale upstream src/evaluate.h. After
    // an upstream net bump the two diverge, and the upstream scripts/net.sh would fetch the wrong file ->
    // the binary can't load its net and crashes.
    // `bash` (not `sh`): on Windows runners git-bash's bash.exe is on PATH while a bare
    // `sh` is not, so this keeps `zig build net`/`parity-portable` working there. The script
    // is POSIX and runs the same under bash on Linux/macOS.
    const net_cmd = b.addSystemCommand(&.{
        "bash",
        b.pathFromRoot("tools/fetch_net.sh"),
        b.pathFromRoot("src/eval/network.zig"),
    });
    net_cmd.setCwd(b.path("net"));

    const net_step = b.step(
        "net",
        "Download the default NNUE net into net/ for external-net Zig parity",
    );
    net_step.dependOn(&net_cmd.step);

    // Pure-Zig parity harness (M-PORT.2): drives the built engine over UCI and diffs the
    // deterministic fingerprints against the committed goldens -- the cross-platform
    // replacement for the bash golden scripts (output_parity/search_parity/search_modes/
    // perft/eval/misc), so `zig build parity` runs identically on Linux/Windows/macOS with
    // no shell/coreutils dependency. Built for the HOST (it spawns the engine as a
    // subprocess): in CI each lane builds natively so host == the engine's target.
    const harness_exe = b.addExecutable(.{
        .name = "parity_harness",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/parity_harness.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseFast,
        }),
    });

    const bench_run = b.addRunArtifact(exe);
    bench_run.step.dependOn(install_step);
    bench_run.step.dependOn(&net_cmd.step);
    bench_run.setCwd(b.path("net"));
    bench_run.addArg("bench");
    bench_run.expectStdErrMatch("Nodes searched  : ");

    const bench_step = b.step(
        "bench",
        "Run stockfish bench from net/ after fetching the default external NNUE net",
    );
    bench_step.dependOn(&bench_run.step);

    const uci_run = b.addRunArtifact(exe);
    uci_run.step.dependOn(install_step);
    uci_run.step.dependOn(&net_cmd.step);
    uci_run.setCwd(b.path("net"));
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
    signature_cmd.setCwd(b.path("net"));
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
    const search_parity_golden = b.pathFromRoot("tools/search_parity.golden");

    const search_parity_cmd = addHarnessRun(b, harness_exe, install_step, &net_cmd.step, "search-parity", search_parity_golden, "check");

    const search_parity_step = b.step(
        "search-parity",
        "Diff per-position bench search fingerprints against the committed golden",
    );
    search_parity_step.dependOn(&search_parity_cmd.step);

    const search_parity_update_cmd = addHarnessRun(b, harness_exe, install_step, &net_cmd.step, "search-parity", search_parity_golden, "update");

    const search_parity_update_step = b.step(
        "search-parity-update",
        "Regenerate tools/search_parity.golden from the current binary",
    );
    search_parity_update_step.dependOn(&search_parity_update_cmd.step);

    // Deterministic non-bench search-mode harness (node-limit / MultiPV /
    // searchmoves) -- validates iterative_deepening control flow beyond bench.
    const search_modes_golden = b.pathFromRoot("tools/search_modes.golden");

    const search_modes_cmd = addHarnessRun(b, harness_exe, install_step, &net_cmd.step, "search-modes", search_modes_golden, "check");

    const search_modes_step = b.step(
        "search-modes",
        "Diff deterministic non-bench search modes against the committed golden",
    );
    search_modes_step.dependOn(&search_modes_cmd.step);

    const search_modes_update_cmd = addHarnessRun(b, harness_exe, install_step, &net_cmd.step, "search-modes", search_modes_golden, "update");

    const search_modes_update_step = b.step(
        "search-modes-update",
        "Regenerate tools/search_modes.golden from the current binary",
    );
    search_modes_update_step.dependOn(&search_modes_update_cmd.step);

    // Worktree-based upstream oracle gate (REPORT-16 M16.1): assert the default (Zig)
    // bench == the PRISTINE upstream Stockfish at UPSTREAM_BASE, built in a persistent
    // git worktree with ZERO vendored C++. This is the drift-proof replacement for
    // oracle-parity: it pins to the exact upstream sha we claim to be at (so it can
    // never become a stale/broken test the way frozen src/ does), and the oracle build
    // is a cached no-op in steady state (upstream_oracle.sh only rebuilds when BASE
    // moves), so it is actually faster than rebuilding the in-tree legacy exe. Kept
    // standalone for now; the parity aggregate + CI switch land with the oracle
    // deletion so CI can add the upstream fetch atomically.
    const upstream_base_sha = runAndTrimOrNull(b, &.{
        "cat",
        b.pathFromRoot("tools/upstream/UPSTREAM_BASE"),
    }) orelse "";
    const upstream_parity_cmd = b.addSystemCommand(&.{
        "bash",
        b.pathFromRoot("tools/upstream_parity.sh"),
        b.getInstallPath(.bin, "stockfish"),
        upstream_base_sha,
    });
    upstream_parity_cmd.step.dependOn(install_step);
    upstream_parity_cmd.step.dependOn(&net_cmd.step);
    const upstream_parity_step = b.step(
        "upstream-parity",
        "Assert default (Zig) bench == pristine upstream@UPSTREAM_BASE (git worktree, no vendored C++)",
    );
    upstream_parity_step.dependOn(&upstream_parity_cmd.step);

    // Full-output GOLDEN gate (Stage-7 7.0a, H8): same stripped bench info+bestmove
    // text as output-parity, but pinned against a committed golden instead of the
    // legacy oracle, so it survives oracle deletion (Annex B B.4). The golden is
    // captured while the oracle still exists; output-parity proves golden == oracle.
    const output_golden = b.pathFromRoot("tools/output_parity.golden");
    const output_golden_cmd = addHarnessRun(b, harness_exe, install_step, &net_cmd.step, "output-golden", output_golden, "check");

    const output_golden_step = b.step(
        "output-golden",
        "Assert the default (Zig) bench info-line output matches the committed golden",
    );
    output_golden_step.dependOn(&output_golden_cmd.step);

    const output_golden_update_cmd = addHarnessRun(b, harness_exe, install_step, &net_cmd.step, "output-golden", output_golden, "update");

    const output_golden_update_step = b.step(
        "output-golden-update",
        "Regenerate tools/output_parity.golden from the current binary",
    );
    output_golden_update_step.dependOn(&output_golden_update_cmd.step);

    // driver-golden (M16.7): pins the search-manager driver + its emit callbacks
    // (multipv/wdl/ponder/currmove/no-moves) bit-exact, to de-risk relocating them.
    const driver_golden = b.pathFromRoot("tools/driver.golden");
    const driver_golden_cmd = addHarnessRun(b, harness_exe, install_step, &net_cmd.step, "driver-golden", driver_golden, "check");
    const driver_golden_step = b.step(
        "driver-golden",
        "Assert the search-driver + emit-callback UCI output matches the committed golden",
    );
    driver_golden_step.dependOn(&driver_golden_cmd.step);

    const driver_golden_update_cmd = addHarnessRun(b, harness_exe, install_step, &net_cmd.step, "driver-golden", driver_golden, "update");
    const driver_golden_update_step = b.step(
        "driver-golden-update",
        "Regenerate tools/driver.golden from the current binary",
    );
    driver_golden_update_step.dependOn(&driver_golden_update_cmd.step);

    // Thread-runtime stress / liveness harness (H2, REPORT-09 big-bang plan).
    // Hammers (ucinewgame -> setoption Threads -> go/stop) cycles across thread
    // counts + a construct/destroy churn, under a wall-clock watchdog. A liveness
    // gate (no hang / crash / lost search), not a determinism gate -- the
    // regression net the native stage-4 thread runtime must still pass. Kept out
    // of the core `parity` aggregate (slower, wall-clock-timed); run explicitly
    // for any thread-runtime slice.
    const stress_cmd = addHarnessRun(b, harness_exe, install_step, &net_cmd.step, "stress", "-", "check");

    const stress_step = b.step(
        "parity-stress",
        "Thread-runtime stress/liveness: go/stop storms + construct/destroy churn",
    );
    stress_step.dependOn(&stress_cmd.step);

    // Memory-error / leak gate (H3, REPORT-09 big-bang plan): Valgrind memcheck
    // over short multi-thread sessions, asserting no invalid access / bad free /
    // definite leak (uninit-value checking off -- NNUE SIMD makes it false-noisy).
    // The ASan/LSan-equivalent net for the native Worker/large-page lifecycle and
    // the stage-4 cut. (TSan/race detection is deferred to stage 4: meaningful
    // only for the native futex runtime; the current C++ runtime has benign TT
    // data races by design.) Out of the core `parity` aggregate (slow).
    const valgrind_cmd = b.addSystemCommand(&.{
        "bash",
        b.pathFromRoot("tools/valgrind.sh"),
        b.getInstallPath(.bin, "stockfish"),
    });
    valgrind_cmd.step.dependOn(install_step);
    valgrind_cmd.step.dependOn(&net_cmd.step);
    valgrind_cmd.setCwd(b.path("net"));

    const valgrind_step = b.step(
        "parity-valgrind",
        "Valgrind memcheck (leak / invalid-access / bad-free) across thread counts",
    );
    valgrind_step.dependOn(&valgrind_cmd.step);

    // Multi-thread search sanity (H1, REPORT-09 big-bang plan). Multi-threaded
    // search is non-deterministic (Lazy SMP), so this is a tolerance gate, not a
    // bit-exact golden: at fixed depth on calm positions, Threads {2,4} must emit
    // a well-formed bestmove and a score of the same kind/sign within a generous
    // cp band of the deterministic single-thread reference. Anchors gross
    // multi-thread behaviour against the live C++ runtime before stage 4 swaps it;
    // catches a native runtime that runs but corrupts result aggregation. Out of
    // the core `parity` aggregate (non-deterministic, sleep-paced).
    const mt_golden = b.pathFromRoot("tools/mt_sanity.golden");

    const mt_cmd = addHarnessRun(b, harness_exe, install_step, &net_cmd.step, "mt-sanity", mt_golden, "check");

    const mt_step = b.step(
        "parity-mt",
        "Multi-thread search sanity: Threads {2,4} score-band vs single-thread golden",
    );
    mt_step.dependOn(&mt_cmd.step);

    const mt_update_cmd = addHarnessRun(b, harness_exe, install_step, &net_cmd.step, "mt-sanity", mt_golden, "update");

    const mt_update_step = b.step(
        "parity-mt-update",
        "Regenerate tools/mt_sanity.golden (single-thread reference)",
    );
    mt_update_step.dependOn(&mt_update_cmd.step);

    // Leak gate for the std::vector lifecycle stage 5 ports (H5, REPORT-09 plan):
    // Valgrind memcheck over a `go searchmoves` + ucinewgame churn, asserting no
    // definite leak / bad free of limits.searchmoves and worker.rootMoves -- the
    // path bench never exercises. Reads the verdict from valgrind's summary and
    // tolerates the known post-exit thread-join hang under memcheck. Out of the
    // core `parity` aggregate (slow).
    const teardown_cmd = b.addSystemCommand(&.{
        "bash",
        b.pathFromRoot("tools/teardown.sh"),
        b.getInstallPath(.bin, "stockfish"),
    });
    teardown_cmd.step.dependOn(install_step);
    teardown_cmd.step.dependOn(&net_cmd.step);
    teardown_cmd.setCwd(b.path("net"));

    const teardown_step = b.step(
        "parity-teardown",
        "Valgrind leak gate for searchmoves/rootMoves vector lifecycle + Worker clear",
    );
    teardown_step.dependOn(&teardown_cmd.step);

    // Wall-clock time-management sanity (REPORT-15 §9): the ONLY gate over `go
    // movetime` / `go wtime` / TimeManagement.startTime -- the whole rest of the
    // battery is depth/node-limited and never consults the clock, which is how the
    // startTime=0 bug (fbcefd0d6) shipped. Invariant-based (no golden): reported
    // elapsed must track the movetime budget and scale with it. Non-deterministic
    // and sleep-paced, so it is its own step (like parity-mt), outside the core
    // deterministic `parity` aggregate; the CI workflow runs it explicitly.
    const time_cmd = addHarnessRun(b, harness_exe, install_step, &net_cmd.step, "time-mgmt", "-", "check");

    const time_step = b.step(
        "parity-time",
        "Wall-clock time management: go movetime/wtime budget + clock-scaling invariants",
    );
    time_step.dependOn(&time_cmd.step);

    // Perft differential + golden gate (REPORT-11 E1.1): the ONLY gate over
    // Position::do_move/undo_move + the legal movegen + the UCI move formatter (bench never runs
    // perft; search-modes only checks bestmoves). perft-parity certifies default == legacy while the
    // oracle still exists; the perft golden survives oracle deletion at TU=0 (REPORT-11 §2.2).
    const perft_golden = b.pathFromRoot("tools/perft.golden");
    const perft_cmd = addHarnessRun(b, harness_exe, install_step, &net_cmd.step, "perft", perft_golden, "check");

    const perft_step = b.step(
        "perft",
        "Diff perft divide counts + totals against the committed golden (do_move/undo_move/movegen)",
    );
    perft_step.dependOn(&perft_cmd.step);

    const perft_update_cmd = addHarnessRun(b, harness_exe, install_step, &net_cmd.step, "perft", perft_golden, "update");

    const perft_update_step = b.step(
        "perft-update",
        "Regenerate tools/perft.golden from the current binary",
    );
    perft_update_step.dependOn(&perft_update_cmd.step);

    // Eval-trace differential + golden gate (REPORT-11 E1.2): pins the NNUE `eval` trace block
    // (buildNnueTrace + the network-ptr / accumulator-cache trace path) — bench covers the eval
    // value but not this formatting path. eval-parity certifies default == legacy while the oracle
    // lives; the golden survives oracle deletion.
    const eval_golden = b.pathFromRoot("tools/eval.golden");
    const eval_cmd = addHarnessRun(b, harness_exe, install_step, &net_cmd.step, "eval", eval_golden, "check");

    const eval_step = b.step(
        "eval-trace",
        "Diff the NNUE eval trace block against the committed golden (buildNnueTrace path)",
    );
    eval_step.dependOn(&eval_cmd.step);

    const eval_update_cmd = addHarnessRun(b, harness_exe, install_step, &net_cmd.step, "eval", eval_golden, "update");

    const eval_update_step = b.step(
        "eval-trace-update",
        "Regenerate tools/eval.golden from the current binary",
    );
    eval_update_step.dependOn(&eval_update_cmd.step);

    // UCI misc-command gate (REPORT-11 E1.2 coverage tail): d/flip Fen+Key+Checkers — the
    // frozen-Position fen/flip/zobrist/gives_check read paths no other gate touches.
    const misc_golden = b.pathFromRoot("tools/misc.golden");
    const misc_cmd = addHarnessRun(b, harness_exe, install_step, &net_cmd.step, "misc", misc_golden, "check");

    const misc_step = b.step(
        "misc",
        "Diff d/flip (Fen/Key/Checkers) against the committed golden (fen/flip/zobrist/gives_check)",
    );
    misc_step.dependOn(&misc_cmd.step);

    const misc_update_cmd = addHarnessRun(b, harness_exe, install_step, &net_cmd.step, "misc", misc_golden, "update");

    const misc_update_step = b.step(
        "misc-update",
        "Regenerate tools/misc.golden from the current binary",
    );
    misc_update_step.dependOn(&misc_update_cmd.step);

    // H9 src-free / TU=0 structural gate (REPORT-11 E1.4; achieved REPORT-16 M16.1): asserts the
    // shipped binary contains zero C++ TUs (no Stockfish:: / libc++ runtime symbols) and still
    // benches 2067208. Now that the in-tree oracle is retired and src/ is deleted, this is GREEN and
    // a permanent invariant, so it joins the `parity` aggregate below (guards against any C++ TU
    // being reintroduced into the default binary).
    const h9_cmd = b.addSystemCommand(&.{
        "bash",
        b.pathFromRoot("tools/h9_src_free.sh"),
        b.getInstallPath(.bin, "stockfish"),
    });
    h9_cmd.step.dependOn(install_step);
    h9_cmd.step.dependOn(&net_cmd.step);
    h9_cmd.setCwd(b.path("net"));

    const h9_step = b.step(
        "h9",
        "src-free structural gate: zero C++ Stockfish/libc++ symbols in the shipped binary",
    );
    h9_step.dependOn(&h9_cmd.step);

    // Aggregate unit-test step (REPORT-16 M16.0b): run the in-tree `test {}` blocks of
    // every named module that has them, reusing the already-wired modules so their
    // imports resolve, plus the pre-existing native-graph (cut) tests. Reachability
    // caveat: tests in a path-imported sub-file run only when a module built here
    // imports it; a file with no test-reachable importer is not yet covered.
    const test_step = b.step("test", "Run the Zig unit tests");
    test_step.dependOn(graph_test_step);
    inline for (.{
        position_storage_module,
        state_list_module,
        numa_config_module,
        tt_module,
        network_holder_module,
        shared_histories_module,
    }) |unit_module| {
        const unit_test = b.addTest(.{ .root_module = unit_module });
        test_step.dependOn(&b.addRunArtifact(unit_test).step);
    }
    // option.zig uses std.heap.c_allocator, so its standalone test build needs libc
    // (in the exe the libc linkage comes from the root module). It has no module deps.
    const option_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/uci/option.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(option_test).step);

    const parity_step = b.step(
        "parity",
        "Run the current bench, UCI, and signature checks through the Zig build entry",
    );
    // M16.1b: the per-push `parity` aggregate no longer depends on the in-tree C++
    // oracle. Whole-engine regression is caught by `signature` (== 2067208) and the
    // GOLDEN gates (output-golden / perft / eval-trace / misc / search-parity /
    // search-modes), all in-repo with no oracle. The `*-parity`-vs-legacy-C++ variants
    // they replace were redundant with those goldens and were the only thing exercising
    // the legacy exe in this gate. The authoritative differential-vs-real-upstream check
    // is `upstream-parity` (worktree oracle), run at sync time where upstream is already
    // fetched -- per push it would only re-assert the same 2067208 the signature checks.
    parity_step.dependOn(&bench_run.step);
    parity_step.dependOn(&uci_run.step);
    parity_step.dependOn(&signature_cmd.step);
    parity_step.dependOn(&search_parity_cmd.step);
    parity_step.dependOn(&search_modes_cmd.step);
    parity_step.dependOn(&output_golden_cmd.step);
    parity_step.dependOn(&driver_golden_cmd.step);
    parity_step.dependOn(&perft_cmd.step);
    parity_step.dependOn(&eval_cmd.step);
    parity_step.dependOn(&misc_cmd.step);
    // M-PORT.2: the interactive concurrency/timing gates now run in the pure-Zig harness, so
    // they join the core aggregate (previously CI ran them as separate ad-hoc steps).
    parity_step.dependOn(&mt_cmd.step);
    parity_step.dependOn(&stress_cmd.step);
    parity_step.dependOn(&time_cmd.step);
    // M16.1d: the src-free structural invariant is now permanent, so it gates every push.
    parity_step.dependOn(&h9_cmd.step);

    // Cross-OS aggregate (M-PORT.2): the platform-independent subset of `parity` -- bench,
    // the UCI handshake, the bench signature, and all six golden checks, every one driven by
    // the pure-Zig harness (no bash / no nm). This is what the Windows and macOS lanes run;
    // the Linux-only structural gates (h9 src-free via `nm`, signature.sh, arch-determinism)
    // stay in `parity`. The bench signature is asserted in-harness against the 2067208
    // arch/OS invariant.
    const harness_sig_cmd = addHarnessRun(b, harness_exe, install_step, &net_cmd.step, "signature", "2067208", "check");
    const parity_portable_step = b.step(
        "parity-portable",
        "Cross-OS parity via the pure-Zig harness: signature + six golden gates + mt/stress/time",
    );
    parity_portable_step.dependOn(&bench_run.step);
    parity_portable_step.dependOn(&uci_run.step);
    parity_portable_step.dependOn(&harness_sig_cmd.step);
    parity_portable_step.dependOn(&search_parity_cmd.step);
    parity_portable_step.dependOn(&search_modes_cmd.step);
    parity_portable_step.dependOn(&output_golden_cmd.step);
    parity_portable_step.dependOn(&perft_cmd.step);
    parity_portable_step.dependOn(&eval_cmd.step);
    parity_portable_step.dependOn(&misc_cmd.step);
    // The concurrency + timing gates -- the cross-OS payoff of M-PORT: these exercise the
    // ported sync primitives (futex / RtlWaitOnAddress / __ulock) under real threading and the
    // ported steady clock (QueryPerformanceCounter on Windows) on every OS, not just Linux.
    parity_portable_step.dependOn(&mt_cmd.step);
    parity_portable_step.dependOn(&stress_cmd.step);
    parity_portable_step.dependOn(&time_cmd.step);

    const stockfish_step = b.step(
        "stockfish",
        "Build the Zig-owned Stockfish engine for Linux x86_64 / aarch64",
    );
    stockfish_step.dependOn(install_step);
}

// Wire one pure-Zig parity-harness invocation (M-PORT.2): run the harness (host) with the
// engine binary, golden path, and mode, from net/ so the spawned engine finds the net.
fn addHarnessRun(
    b: *std.Build,
    harness: *std.Build.Step.Compile,
    install_step: *std.Build.Step,
    net_step: *std.Build.Step,
    check_name: []const u8,
    golden_or_expected: []const u8,
    mode: []const u8,
) *std.Build.Step.Run {
    const run = b.addRunArtifact(harness);
    run.addArgs(&.{ check_name, b.getInstallPath(.bin, "stockfish"), golden_or_expected, mode });
    run.setCwd(b.path("net"));
    run.step.dependOn(install_step);
    run.step.dependOn(net_step);
    return run;
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

    // Non-x86 tiers (M15.5). The pure-Zig @Vector NNUE lowers to NEON with no source
    // changes, so these just map get_native_properties.sh's aarch64 outputs to a Zig
    // aarch64 target. NEON is mandatory in AArch64 (baseline has it); dotprod (sdot) is
    // added where present. The C++ differential oracle is x86-only, so `-Darch=<arm>`
    // builds the pure Zig engine only (legacy is skipped off x86_64). Runtime-validated
    // under qemu-user in CI (bench == 2067208), matching upstream's arm_compilation.yml.
    if (std.mem.eql(u8, arch_name, "armv8"))
        return .{
            .name = "armv8",
            .flags = &.{},
            .macros = &.{.{ .name = "USE_NEON", .value = "8" }},
            .target_features = std.Target.aarch64.featureSet(&.{.neon}),
            .cpu_arch = .aarch64,
        };

    if (std.mem.eql(u8, arch_name, "armv8-dotprod") or
        std.mem.eql(u8, arch_name, "apple-silicon"))
        return .{
            .name = arch_name,
            .flags = &.{},
            .macros = &.{
                .{ .name = "USE_NEON", .value = "8" },
                .{ .name = "USE_NEON_DOTPROD", .value = "1" },
            },
            .target_features = std.Target.aarch64.featureSet(&.{ .neon, .dotprod }),
            .cpu_arch = .aarch64,
        };

    std.process.fatal(
        "unsupported ARCH '{s}' (x86_64 tiers + aarch64 armv8/armv8-dotprod/apple-silicon)",
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
