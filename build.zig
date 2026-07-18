const std = @import("std");

const Macro = struct {
    name: []const u8,
    value: []const u8,
};

// Enumerate the owned runtime OSes. Select with -Dos=; each maps to an (os_tag, abi) pair
// in build(). Keep orthogonal to -Darch= (the ISA tier), so any arch tier can target any OS.
const TargetOs = enum { linux, windows, macos };

const ArchConfig = struct {
    name: []const u8,
    flags: []const []const u8,
    macros: []const Macro,
    target_features: std.Target.Cpu.Feature.Set,
    // Default the owned runtime to x86_64; non-x86 tiers set this so the pure
    // Zig @Vector NNUE cross-compiles to that ISA (LLVM lowers to NEON/etc).
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
        "Expected bench signature for the `signature` step; defaults to the 2466447 invariant",
    );
    const requested_arch = b.option(
        []const u8,
        "arch",
        "Stockfish ARCH value (e.g. x86-64-avx2), or 'native' to auto-detect the host CPU tier in Zig",
    ) orelse "native";
    const arch = resolveArch(b, requested_arch);
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
    // Use a relative "kcov-out" (not b.pathFromRoot): the Run step's default cwd is the build root, so
    // kcov writes there -- and a plain string stays valid across Zig 0.16/0.17 (pathFromRoot was
    // removed in 0.17), which keeps the non-blocking nightly lane building instead of tripping here.
    const cov_dir: ?[]const u8 = if (test_coverage) "kcov-out" else null;
    var cov_idx: usize = 0;
    // Target the owned runtimes: Linux (default), Windows, and macOS. The pure-Zig
    // engine is OS-portable behind a thin platform seam -- sync (thread_runtime.zig futex
    // seam), aligned/large-page allocation (memory.zig), the steady clock and CPU-affinity
    // string (main.zig). Windows uses the self-contained mingw (gnu) ABI so no MSVC/SDK is
    // needed; macOS uses its native ABI. The integer-exact NNUE eval is arch/OS-invariant,
    // so bench must be 2466447 on every (arch, os) tier -- the parity lanes assert it.
    const os_choice = b.option(TargetOs, "os", "Target OS: linux (default), windows, or macos") orelse .linux;
    const os_tag: std.Target.Os.Tag = switch (os_choice) {
        .linux => .linux,
        .windows => .windows,
        .macos => .macos,
    };
    const abi: std.Target.Abi = switch (os_choice) {
        .linux => .gnu,
        .windows => .gnu, // mingw: self-contained, ships with Zig (no Visual Studio / Windows SDK)
        .macos => .none, // Take macOS's single system ABI (libSystem); no gnu/musl split
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

    // Model the module graph as data: each engine module is a uniform {name, path}
    // spec, and import edges are a table.
    const ModuleSpec = struct { name: []const u8, path: []const u8 };
    const module_specs = [_]ModuleSpec{
        .{ .name = "libc", .path = "src/platform/libc.zig" },
        .{ .name = "memory", .path = "src/platform/memory.zig" },
        .{ .name = "tablebase", .path = "src/platform/tablebase.zig" },
        .{ .name = "clock", .path = "src/platform/clock.zig" },
        .{ .name = "uci_output", .path = "src/shell/uci_output.zig" },
        .{ .name = "uci_wdl", .path = "src/engine/search/uci_wdl.zig" },
        .{ .name = "score", .path = "src/engine/board/score.zig" },
        .{ .name = "thread_vote", .path = "src/platform/thread_vote.zig" },
        .{ .name = "thread_runtime", .path = "src/platform/thread_runtime.zig" },
        .{ .name = "search_thread", .path = "src/platform/search_thread.zig" },
        .{ .name = "numa", .path = "src/platform/numa.zig" },
        .{ .name = "worker_layout", .path = "src/engine/state/worker_layout.zig" },
        .{ .name = "worker_construct", .path = "src/engine/state/worker_construct.zig" },
        .{ .name = "shared_state", .path = "src/engine/state/shared_state.zig" },
        .{ .name = "limits_type", .path = "src/engine/state/limits_type.zig" },
        .{ .name = "root_move", .path = "src/engine/state/root_move.zig" },
        .{ .name = "engine_object", .path = "src/shell/engine/object.zig" },
        .{ .name = "timeman", .path = "src/engine/search/timeman.zig" },
        .{ .name = "benchmark", .path = "src/shell/benchmark.zig" },
        .{ .name = "misc", .path = "src/shell/misc.zig" },
        .{ .name = "engine", .path = "src/shell/engine.zig" },
        .{ .name = "engine_util", .path = "src/shell/engine/util.zig" },
        .{ .name = "engine_infofmt", .path = "src/shell/engine/infofmt.zig" },
        .{ .name = "engine_nnue", .path = "src/shell/engine/nnue.zig" },
        .{ .name = "engine_trace", .path = "src/shell/engine/trace.zig" },
        .{ .name = "engine_perft", .path = "src/shell/engine/perft.zig" },
        .{ .name = "engine_options", .path = "src/shell/engine/options.zig" },
        .{ .name = "uci_move", .path = "src/engine/board/uci_move.zig" },
        .{ .name = "movepick", .path = "src/engine/search/movepick.zig" },
        .{ .name = "search", .path = "src/engine/search/search.zig" },
        .{ .name = "thread", .path = "src/platform/thread.zig" },
        .{ .name = "tt", .path = "src/engine/search/tt.zig" },
        .{ .name = "tt_types", .path = "src/engine/state/tt_types.zig" },
        .{ .name = "option", .path = "src/shell/option.zig" },
        .{ .name = "bitboard", .path = "src/engine/board/bitboard.zig" },
        .{ .name = "position", .path = "src/engine/board/position.zig" },
        .{ .name = "position_snapshot", .path = "src/engine/board/position_snapshot.zig" },
        .{ .name = "runtime_hooks", .path = "src/platform/runtime_hooks.zig" },
        .{ .name = "movegen", .path = "src/engine/board/movegen.zig" },
        .{ .name = "nnue_feature", .path = "src/engine/eval/nnue_feature.zig" },
        .{ .name = "uci", .path = "src/shell/uci.zig" },
        .{ .name = "uci_strings", .path = "src/shell/uci_strings.zig" },
        .{ .name = "uci_format", .path = "src/shell/uci_format.zig" },
        .{ .name = "uci_parse", .path = "src/shell/uci_parse.zig" },
        .{ .name = "evaluate", .path = "src/engine/eval/evaluate.zig" },
        .{ .name = "nnue_accumulator", .path = "src/engine/eval/nnue_accumulator.zig" },
        .{ .name = "nnue_acc_rowops", .path = "src/engine/eval/nnue_acc_rowops.zig" },
        .{ .name = "nnue_ft", .path = "src/engine/eval/nnue_ft.zig" },
        .{ .name = "nnue_refresh_cache", .path = "src/engine/eval/nnue_refresh_cache.zig" },
        .{ .name = "network", .path = "src/engine/eval/network.zig" },
        .{ .name = "nnue_misc", .path = "src/engine/eval/nnue_misc.zig" },
        .{ .name = "state_list", .path = "src/engine/board/state_list.zig" },
        .{ .name = "position_storage", .path = "src/engine/state/position_storage.zig" },
        .{ .name = "page_alloc", .path = "src/engine/state/page_alloc.zig" },
        .{ .name = "option_source", .path = "src/engine/search/option_source.zig" },
        .{ .name = "tb_source", .path = "src/engine/search/tb_source.zig" },
        .{ .name = "thread_ops", .path = "src/engine/search/thread_ops.zig" },
        .{ .name = "output_sink", .path = "src/engine/search/output_sink.zig" },
        .{ .name = "shared_histories", .path = "src/engine/search/shared_histories.zig" },
        .{ .name = "headless_search", .path = "src/engine/search/headless_search.zig" },
        .{ .name = "shared_histories_map", .path = "src/engine/search/shared_histories_map.zig" },
        .{ .name = "worker_histories", .path = "src/engine/state/worker_histories.zig" },
        .{ .name = "position_types", .path = "src/engine/board/position_types.zig" },
        .{ .name = "fen", .path = "src/engine/board/fen.zig" },
        .{ .name = "board_core", .path = "src/engine/board/board_core.zig" },
        .{ .name = "legality", .path = "src/engine/board/legality.zig" },
        .{ .name = "zobrist", .path = "src/engine/board/zobrist.zig" },
        .{ .name = "repetition", .path = "src/engine/board/repetition.zig" },
        .{ .name = "position_query", .path = "src/engine/board/position_query.zig" },
        .{ .name = "state_setup", .path = "src/engine/board/state_setup.zig" },
        .{ .name = "move_do", .path = "src/engine/board/move_do.zig" },
        .{ .name = "fen_parse", .path = "src/engine/board/fen_parse.zig" },
        .{ .name = "search_types", .path = "src/engine/search/search_types.zig" },
        .{ .name = "correction_bundle", .path = "src/engine/state/correction_bundle.zig" },
        .{ .name = "shared_history_types", .path = "src/engine/state/shared_history_types.zig" },
        .{ .name = "search_ctx", .path = "src/engine/search/search_ctx.zig" },
        .{ .name = "search_id", .path = "src/engine/search/search_id.zig" },
        .{ .name = "search_acc", .path = "src/engine/search/search_acc.zig" },
        .{ .name = "search_setup", .path = "src/engine/search/search_setup.zig" },
        .{ .name = "search_driver", .path = "src/engine/search/search_driver.zig" },
        .{ .name = "search_emit", .path = "src/engine/search/search_emit.zig" },
        .{ .name = "time_source", .path = "src/engine/search/time_source.zig" },
        .{ .name = "position_lifecycle", .path = "src/engine/board/position_lifecycle.zig" },
        .{ .name = "shared_history", .path = "src/engine/search/shared_history.zig" },
        .{ .name = "search_common", .path = "src/engine/search/search_common.zig" },
        .{ .name = "history", .path = "src/engine/search/history.zig" },
        // Register search_manager and root_move_build as named modules (not path-imported
        // leaves) so they can be imported by module name from any directory. A path import
        // (@import("x.zig")) binds a file into its importer's module and directory; naming them
        // lets their location change without touching the importers.
        .{ .name = "search_manager", .path = "src/engine/search/search_manager.zig" },
        .{ .name = "root_move_build", .path = "src/engine/search/root_move_build.zig" },
    };
    var mods = std.StringHashMap(*std.Build.Module).init(b.allocator);
    for (module_specs) |spec| {
        mods.put(spec.name, b.createModule(.{
            .root_source_file = b.path(spec.path),
            .target = target,
            .optimize = optimize,
        })) catch @panic("OOM building module graph");
    }
    const Edge = struct { from: []const u8, imp: []const u8, to: []const u8 };
    const module_edges = [_]Edge{
        // Wire the import edges for the standalone named modules search_manager and root_move_build.
        .{ .from = "engine", .imp = "search_manager", .to = "search_manager" },
        // Construct the engine-zone Worker fields in worker_construct (moved out of shell; imports
        // only engine modules). main.zig + the headless search helper both drive it.
        .{ .from = "worker_construct", .imp = "worker_layout", .to = "worker_layout" },
        .{ .from = "worker_construct", .imp = "position", .to = "position" },
        .{ .from = "worker_construct", .imp = "search_driver", .to = "search_driver" },
        .{ .from = "worker_construct", .imp = "worker_histories", .to = "worker_histories" },
        .{ .from = "worker_construct", .imp = "search", .to = "search" },
        .{ .from = "worker_construct", .imp = "nnue_accumulator", .to = "nnue_accumulator" },
        .{ .from = "worker_construct", .imp = "network", .to = "network" },
        // Enter a single-worker shallow search in the engine zone via headless_search (the "search one
        // position at depth N" helper the platform ThreadPool otherwise gatekeeps).
        .{ .from = "headless_search", .imp = "worker_layout", .to = "worker_layout" },
        .{ .from = "headless_search", .imp = "worker_construct", .to = "worker_construct" },
        .{ .from = "headless_search", .imp = "search_driver", .to = "search_driver" },
        .{ .from = "headless_search", .imp = "root_move_build", .to = "root_move_build" },
        .{ .from = "headless_search", .imp = "page_alloc", .to = "page_alloc" },
        .{ .from = "headless_search", .imp = "tt_types", .to = "tt_types" },
        .{ .from = "headless_search", .imp = "network", .to = "network" },
        .{ .from = "headless_search", .imp = "movegen", .to = "movegen" },
        .{ .from = "headless_search", .imp = "position", .to = "position" },
        .{ .from = "headless_search", .imp = "option_source", .to = "option_source" },
        .{ .from = "headless_search", .imp = "nnue_accumulator", .to = "nnue_accumulator" },
        .{ .from = "thread", .imp = "root_move_build", .to = "root_move_build" },
        .{ .from = "root_move_build", .imp = "position", .to = "position" },
        .{ .from = "root_move_build", .imp = "state_list", .to = "state_list" },
        .{ .from = "root_move_build", .imp = "tb_source", .to = "tb_source" },
        .{ .from = "tablebase", .imp = "tb_source", .to = "tb_source" },
        .{ .from = "tb_source", .imp = "position_types", .to = "position_types" },
        .{ .from = "search_driver", .imp = "tb_source", .to = "tb_source" },
        // Probe Syzygy WDL: the platform tablebase module reaches down to the
        // headless engine (a legal platform->engine down-edge) for a scratch Position, its
        // material key, piece bitboards, and legal-capture movegen used by the probe.
        .{ .from = "tablebase", .imp = "position", .to = "position" },
        .{ .from = "tablebase", .imp = "state_list", .to = "state_list" },
        .{ .from = "tablebase", .imp = "movegen", .to = "movegen" },
        .{ .from = "tablebase", .imp = "board_core", .to = "board_core" },
        .{ .from = "root_move_build", .imp = "option_source", .to = "option_source" },
        .{ .from = "root_move_build", .imp = "movegen", .to = "movegen" },
        .{ .from = "root_move_build", .imp = "position_snapshot", .to = "position_snapshot" },
        // Import the owning search modules directly from consumers: search_driver's public
        // face, and the RootMove type in search_types.
        .{ .from = "engine", .imp = "search_driver", .to = "search_driver" },
        .{ .from = "thread", .imp = "search_driver", .to = "search_driver" },
        .{ .from = "thread", .imp = "search_types", .to = "search_types" },
        .{ .from = "root_move_build", .imp = "search_types", .to = "search_types" },
        .{ .from = "position", .imp = "worker_histories", .to = "worker_histories" },
        .{ .from = "worker_layout", .imp = "worker_histories", .to = "worker_histories" },
        .{ .from = "position", .imp = "position_types", .to = "position_types" },
        .{ .from = "worker_layout", .imp = "position_types", .to = "position_types" },
        .{ .from = "state_list", .imp = "position_types", .to = "position_types" },
        .{ .from = "worker_layout", .imp = "limits_type", .to = "limits_type" },
        .{ .from = "worker_layout", .imp = "root_move", .to = "root_move" },
        .{ .from = "worker_layout", .imp = "tt_types", .to = "tt_types" },
        .{ .from = "worker_layout", .imp = "state_list", .to = "state_list" },
        .{ .from = "runtime_hooks", .imp = "worker_layout", .to = "worker_layout" },
        .{ .from = "runtime_hooks", .imp = "position_types", .to = "position_types" },
        .{ .from = "search_types", .imp = "root_move", .to = "root_move" },
        .{ .from = "search_types", .imp = "worker_histories", .to = "worker_histories" },
        .{ .from = "search_types", .imp = "correction_bundle", .to = "correction_bundle" },
        .{ .from = "engine", .imp = "root_move", .to = "root_move" },
        .{ .from = "engine", .imp = "shared_state", .to = "shared_state" },
        .{ .from = "position", .imp = "fen", .to = "fen" },
        .{ .from = "position", .imp = "board_core", .to = "board_core" },
        .{ .from = "board_core", .imp = "position_types", .to = "position_types" },
        .{ .from = "position", .imp = "legality", .to = "legality" },
        .{ .from = "legality", .imp = "board_core", .to = "board_core" },
        .{ .from = "movegen", .imp = "board_core", .to = "board_core" },
        .{ .from = "uci_move", .imp = "board_core", .to = "board_core" },
        .{ .from = "movepick", .imp = "board_core", .to = "board_core" },
        .{ .from = "legality", .imp = "bitboard", .to = "bitboard" },
        .{ .from = "legality", .imp = "movegen", .to = "movegen" },
        .{ .from = "legality", .imp = "position_types", .to = "position_types" },
        .{ .from = "position", .imp = "zobrist", .to = "zobrist" },
        .{ .from = "zobrist", .imp = "bitboard", .to = "bitboard" },
        .{ .from = "zobrist", .imp = "board_core", .to = "board_core" },
        .{ .from = "position", .imp = "repetition", .to = "repetition" },
        .{ .from = "repetition", .imp = "bitboard", .to = "bitboard" },
        .{ .from = "repetition", .imp = "movegen", .to = "movegen" },
        .{ .from = "repetition", .imp = "board_core", .to = "board_core" },
        .{ .from = "repetition", .imp = "zobrist", .to = "zobrist" },
        .{ .from = "repetition", .imp = "position_types", .to = "position_types" },
        .{ .from = "position", .imp = "position_query", .to = "position_query" },
        .{ .from = "position_query", .imp = "board_core", .to = "board_core" },
        .{ .from = "position_query", .imp = "position_types", .to = "position_types" },
        .{ .from = "position_query", .imp = "position_snapshot", .to = "position_snapshot" },
        .{ .from = "position", .imp = "state_setup", .to = "state_setup" },
        .{ .from = "state_setup", .imp = "bitboard", .to = "bitboard" },
        .{ .from = "state_setup", .imp = "board_core", .to = "board_core" },
        .{ .from = "state_setup", .imp = "zobrist", .to = "zobrist" },
        .{ .from = "state_setup", .imp = "legality", .to = "legality" },
        .{ .from = "state_setup", .imp = "position_types", .to = "position_types" },
        .{ .from = "position", .imp = "move_do", .to = "move_do" },
        .{ .from = "move_do", .imp = "bitboard", .to = "bitboard" },
        .{ .from = "move_do", .imp = "board_core", .to = "board_core" },
        .{ .from = "move_do", .imp = "zobrist", .to = "zobrist" },
        .{ .from = "move_do", .imp = "state_setup", .to = "state_setup" },
        .{ .from = "move_do", .imp = "legality", .to = "legality" },
        .{ .from = "move_do", .imp = "position_types", .to = "position_types" },
        .{ .from = "position", .imp = "fen_parse", .to = "fen_parse" },
        .{ .from = "position", .imp = "search_types", .to = "search_types" },
        .{ .from = "position", .imp = "search_driver", .to = "search_driver" },
        .{ .from = "position", .imp = "position_lifecycle", .to = "position_lifecycle" },
        .{ .from = "position_lifecycle", .imp = "worker_layout", .to = "worker_layout" },
        .{ .from = "position_lifecycle", .imp = "move_do", .to = "move_do" },
        .{ .from = "position_lifecycle", .imp = "legality", .to = "legality" },
        .{ .from = "position_lifecycle", .imp = "fen_parse", .to = "fen_parse" },
        .{ .from = "position_lifecycle", .imp = "position_types", .to = "position_types" },
        .{ .from = "search_driver", .imp = "time_source", .to = "time_source" },
        .{ .from = "search_driver", .imp = "worker_layout", .to = "worker_layout" },
        .{ .from = "search_driver", .imp = "bitboard", .to = "bitboard" },
        .{ .from = "search_driver", .imp = "movegen", .to = "movegen" },
        .{ .from = "search_driver", .imp = "tt", .to = "tt" },
        .{ .from = "search_driver", .imp = "movepick", .to = "movepick" },
        .{ .from = "search_driver", .imp = "search", .to = "search" },
        .{ .from = "search_driver", .imp = "nnue_accumulator", .to = "nnue_accumulator" },
        .{ .from = "search_driver", .imp = "evaluate", .to = "evaluate" },
        .{ .from = "search_driver", .imp = "shared_histories", .to = "shared_histories" },
        .{ .from = "search_driver", .imp = "shared_histories_map", .to = "shared_histories_map" },
        .{ .from = "search_driver", .imp = "network", .to = "network" },
        .{ .from = "search_driver", .imp = "position_snapshot", .to = "position_snapshot" },
        .{ .from = "search_driver", .imp = "uci_wdl", .to = "uci_wdl" },
        .{ .from = "search_driver", .imp = "uci_move", .to = "uci_move" },
        .{ .from = "search_driver", .imp = "score", .to = "score" },
        .{ .from = "search_driver", .imp = "timeman", .to = "timeman" },
        .{ .from = "search_driver", .imp = "worker_histories", .to = "worker_histories" },
        .{ .from = "search_driver", .imp = "position_types", .to = "position_types" },
        .{ .from = "search_driver", .imp = "search_types", .to = "search_types" },
        .{ .from = "search_driver", .imp = "search_ctx", .to = "search_ctx" },
        .{ .from = "search_driver", .imp = "search_id", .to = "search_id" },
        .{ .from = "search_driver", .imp = "search_acc", .to = "search_acc" },
        .{ .from = "search_driver", .imp = "search_setup", .to = "search_setup" },
        .{ .from = "search_setup", .imp = "worker_layout", .to = "worker_layout" },
        .{ .from = "search_setup", .imp = "root_move", .to = "root_move" },
        .{ .from = "search_setup", .imp = "tt_types", .to = "tt_types" },
        .{ .from = "search_setup", .imp = "nnue_accumulator", .to = "nnue_accumulator" },
        .{ .from = "search_setup", .imp = "search_ctx", .to = "search_ctx" },
        .{ .from = "search_acc", .imp = "network", .to = "network" },
        .{ .from = "search_acc", .imp = "evaluate", .to = "evaluate" },
        .{ .from = "search_acc", .imp = "nnue_accumulator", .to = "nnue_accumulator" },
        .{ .from = "search_acc", .imp = "move_do", .to = "move_do" },
        .{ .from = "search_acc", .imp = "legality", .to = "legality" },
        .{ .from = "search_acc", .imp = "search_common", .to = "search_common" },
        .{ .from = "search_acc", .imp = "history", .to = "history" },
        .{ .from = "search_acc", .imp = "board_core", .to = "board_core" },
        .{ .from = "search_acc", .imp = "movegen", .to = "movegen" },
        .{ .from = "search_acc", .imp = "position_types", .to = "position_types" },
        .{ .from = "search_acc", .imp = "search_types", .to = "search_types" },
        .{ .from = "search_acc", .imp = "search_ctx", .to = "search_ctx" },
        .{ .from = "search_id", .imp = "worker_layout", .to = "worker_layout" },
        .{ .from = "search_id", .imp = "option_source", .to = "option_source" },
        .{ .from = "search_id", .imp = "timeman", .to = "timeman" },
        .{ .from = "search_id", .imp = "tt", .to = "tt" },
        .{ .from = "search_id", .imp = "thread_ops", .to = "thread_ops" },
        .{ .from = "thread_ops", .imp = "worker_layout", .to = "worker_layout" },
        .{ .from = "search_id", .imp = "nnue_accumulator", .to = "nnue_accumulator" },
        .{ .from = "search_id", .imp = "position_query", .to = "position_query" },
        .{ .from = "search_id", .imp = "time_source", .to = "time_source" },
        .{ .from = "search_id", .imp = "search_ctx", .to = "search_ctx" },
        .{ .from = "search_ctx", .imp = "worker_layout", .to = "worker_layout" },
        .{ .from = "search_ctx", .imp = "position_types", .to = "position_types" },
        .{ .from = "search_ctx", .imp = "root_move", .to = "root_move" },
        .{ .from = "search_ctx", .imp = "tt_types", .to = "tt_types" },
        .{ .from = "search_ctx", .imp = "nnue_accumulator", .to = "nnue_accumulator" },
        .{ .from = "search_driver", .imp = "fen", .to = "fen" },
        .{ .from = "search_driver", .imp = "board_core", .to = "board_core" },
        .{ .from = "search_driver", .imp = "legality", .to = "legality" },
        .{ .from = "search_driver", .imp = "zobrist", .to = "zobrist" },
        .{ .from = "search_driver", .imp = "repetition", .to = "repetition" },
        .{ .from = "search_driver", .imp = "position_query", .to = "position_query" },
        .{ .from = "search_driver", .imp = "state_setup", .to = "state_setup" },
        .{ .from = "search_driver", .imp = "move_do", .to = "move_do" },
        .{ .from = "search_driver", .imp = "shared_history", .to = "shared_history" },
        .{ .from = "search_driver", .imp = "search_common", .to = "search_common" },
        .{ .from = "search_driver", .imp = "history", .to = "history" },
        .{ .from = "search_driver", .imp = "search_emit", .to = "search_emit" },
        .{ .from = "search_emit", .imp = "time_source", .to = "time_source" },
        .{ .from = "search_emit", .imp = "worker_layout", .to = "worker_layout" },
        .{ .from = "search_emit", .imp = "tt", .to = "tt" },
        .{ .from = "search_emit", .imp = "score", .to = "score" },
        .{ .from = "search_emit", .imp = "uci_wdl", .to = "uci_wdl" },
        .{ .from = "search_emit", .imp = "output_sink", .to = "output_sink" },
        .{ .from = "search_emit", .imp = "uci_move", .to = "uci_move" },
        .{ .from = "search_emit", .imp = "position_query", .to = "position_query" },
        .{ .from = "search_emit", .imp = "option_source", .to = "option_source" },
        .{ .from = "search_emit", .imp = "search_types", .to = "search_types" },
        .{ .from = "history", .imp = "search", .to = "search" },
        .{ .from = "history", .imp = "search_common", .to = "search_common" },
        .{ .from = "history", .imp = "shared_history", .to = "shared_history" },
        .{ .from = "history", .imp = "worker_histories", .to = "worker_histories" },
        .{ .from = "history", .imp = "search_types", .to = "search_types" },
        .{ .from = "history", .imp = "position_types", .to = "position_types" },
        .{ .from = "history", .imp = "board_core", .to = "board_core" },
        .{ .from = "history", .imp = "worker_layout", .to = "worker_layout" },
        .{ .from = "search_common", .imp = "worker_layout", .to = "worker_layout" },
        .{ .from = "search_common", .imp = "worker_histories", .to = "worker_histories" },
        .{ .from = "search_common", .imp = "position_types", .to = "position_types" },
        .{ .from = "search_common", .imp = "board_core", .to = "board_core" },
        .{ .from = "shared_history", .imp = "page_alloc", .to = "page_alloc" },
        .{ .from = "shared_history", .imp = "shared_histories", .to = "shared_histories" },
        .{ .from = "shared_history", .imp = "shared_histories_map", .to = "shared_histories_map" },
        .{ .from = "shared_history", .imp = "worker_histories", .to = "worker_histories" },
        .{ .from = "shared_history", .imp = "search_types", .to = "search_types" },
        .{ .from = "shared_history", .imp = "position_types", .to = "position_types" },
        .{ .from = "shared_history", .imp = "shared_history_types", .to = "shared_history_types" },
        .{ .from = "shared_history_types", .imp = "correction_bundle", .to = "correction_bundle" },
        .{ .from = "worker_histories", .imp = "shared_history_types", .to = "shared_history_types" },
        .{ .from = "fen_parse", .imp = "board_core", .to = "board_core" },
        .{ .from = "fen_parse", .imp = "move_do", .to = "move_do" },
        .{ .from = "fen_parse", .imp = "state_setup", .to = "state_setup" },
        .{ .from = "fen_parse", .imp = "legality", .to = "legality" },
        .{ .from = "fen_parse", .imp = "position_types", .to = "position_types" },
        .{ .from = "engine", .imp = "engine_util", .to = "engine_util" },
        .{ .from = "engine_util", .imp = "libc", .to = "libc" },
        .{ .from = "engine", .imp = "engine_infofmt", .to = "engine_infofmt" },
        .{ .from = "engine_infofmt", .imp = "engine_util", .to = "engine_util" },
        .{ .from = "engine", .imp = "engine_nnue", .to = "engine_nnue" },
        .{ .from = "engine_nnue", .imp = "libc", .to = "libc" },
        .{ .from = "engine_nnue", .imp = "option", .to = "option" },
        .{ .from = "engine_nnue", .imp = "network", .to = "network" },
        .{ .from = "engine_nnue", .imp = "uci_output", .to = "uci_output" },
        .{ .from = "engine_nnue", .imp = "engine_object", .to = "engine_object" },
        .{ .from = "engine", .imp = "engine_trace", .to = "engine_trace" },
        .{ .from = "engine", .imp = "engine_perft", .to = "engine_perft" },
        .{ .from = "engine", .imp = "engine_options", .to = "engine_options" },
        .{ .from = "engine_options", .imp = "option", .to = "option" },
        .{ .from = "engine_perft", .imp = "worker_layout", .to = "worker_layout" },
        .{ .from = "engine_perft", .imp = "movegen", .to = "movegen" },
        .{ .from = "engine_perft", .imp = "position", .to = "position" },
        .{ .from = "engine_perft", .imp = "option", .to = "option" },
        .{ .from = "engine_perft", .imp = "uci_move", .to = "uci_move" },
        .{ .from = "engine_perft", .imp = "uci_output", .to = "uci_output" },
        .{ .from = "engine_perft", .imp = "engine_object", .to = "engine_object" },
        .{ .from = "engine_perft", .imp = "engine_nnue", .to = "engine_nnue" },
        .{ .from = "engine_perft", .imp = "engine_trace", .to = "engine_trace" },
        .{ .from = "engine_trace", .imp = "libc", .to = "libc" },
        .{ .from = "engine_trace", .imp = "position_snapshot", .to = "position_snapshot" },
        .{ .from = "engine_trace", .imp = "position", .to = "position" },
        .{ .from = "engine_trace", .imp = "uci_move", .to = "uci_move" },
        .{ .from = "engine_trace", .imp = "nnue_accumulator", .to = "nnue_accumulator" },
        .{ .from = "engine_trace", .imp = "evaluate", .to = "evaluate" },
        .{ .from = "engine_trace", .imp = "worker_layout", .to = "worker_layout" },
        .{ .from = "engine_trace", .imp = "tablebase", .to = "tablebase" },
        .{ .from = "engine_trace", .imp = "option", .to = "option" },
        .{ .from = "engine_trace", .imp = "state_list", .to = "state_list" },
        .{ .from = "engine_trace", .imp = "nnue_misc", .to = "nnue_misc" },
        .{ .from = "engine_trace", .imp = "uci_wdl", .to = "uci_wdl" },
        .{ .from = "engine_trace", .imp = "network", .to = "network" },
        .{ .from = "engine_trace", .imp = "engine_object", .to = "engine_object" },
        .{ .from = "engine_trace", .imp = "engine_util", .to = "engine_util" },
        .{ .from = "engine_trace", .imp = "engine_nnue", .to = "engine_nnue" },
        .{ .from = "engine", .imp = "position", .to = "position" },
        .{ .from = "engine", .imp = "position_snapshot", .to = "position_snapshot" },
        .{ .from = "position", .imp = "position_snapshot", .to = "position_snapshot" },
        .{ .from = "thread", .imp = "runtime_hooks", .to = "runtime_hooks" },
        .{ .from = "engine", .imp = "runtime_hooks", .to = "runtime_hooks" },
        .{ .from = "search_thread", .imp = "runtime_hooks", .to = "runtime_hooks" },
        .{ .from = "engine", .imp = "uci_move", .to = "uci_move" },
        .{ .from = "engine", .imp = "misc", .to = "misc" },
        .{ .from = "engine", .imp = "thread", .to = "thread" },
        .{ .from = "engine_object", .imp = "worker_layout", .to = "worker_layout" },
        .{ .from = "engine_object", .imp = "misc", .to = "misc" },
        .{ .from = "engine_object", .imp = "state_list", .to = "state_list" },
        .{ .from = "engine_object", .imp = "network", .to = "network" },
        .{ .from = "engine_object", .imp = "numa", .to = "numa" },
        .{ .from = "engine_object", .imp = "position_types", .to = "position_types" },
        .{ .from = "engine", .imp = "engine_object", .to = "engine_object" },
        .{ .from = "engine", .imp = "numa", .to = "numa" },
        .{ .from = "thread", .imp = "numa", .to = "numa" },
        .{ .from = "engine", .imp = "tt", .to = "tt" },
        .{ .from = "engine", .imp = "state_list", .to = "state_list" },
        .{ .from = "engine", .imp = "position_storage", .to = "position_storage" },
        .{ .from = "engine", .imp = "network", .to = "network" },
        .{ .from = "engine", .imp = "nnue_accumulator", .to = "nnue_accumulator" },
        .{ .from = "engine", .imp = "evaluate", .to = "evaluate" },
        .{ .from = "engine", .imp = "nnue_misc", .to = "nnue_misc" },
        .{ .from = "uci_move", .imp = "position_snapshot", .to = "position_snapshot" },
        .{ .from = "movepick", .imp = "position_snapshot", .to = "position_snapshot" },
        .{ .from = "movepick", .imp = "position_types", .to = "position_types" },
        .{ .from = "movepick", .imp = "bitboard", .to = "bitboard" },
        .{ .from = "movepick", .imp = "movegen", .to = "movegen" },
        .{ .from = "movepick", .imp = "legality", .to = "legality" },
        .{ .from = "movepick", .imp = "shared_history_types", .to = "shared_history_types" },
        .{ .from = "movegen", .imp = "position_snapshot", .to = "position_snapshot" },
        .{ .from = "movegen", .imp = "position_types", .to = "position_types" },
        .{ .from = "movegen", .imp = "bitboard", .to = "bitboard" },
        .{ .from = "position_snapshot", .imp = "position_types", .to = "position_types" },
        .{ .from = "nnue_accumulator", .imp = "position_snapshot", .to = "position_snapshot" },
        .{ .from = "nnue_accumulator", .imp = "nnue_acc_rowops", .to = "nnue_acc_rowops" },
        .{ .from = "nnue_accumulator", .imp = "nnue_ft", .to = "nnue_ft" },
        .{ .from = "nnue_accumulator", .imp = "nnue_refresh_cache", .to = "nnue_refresh_cache" },
        .{ .from = "nnue_accumulator", .imp = "nnue_feature", .to = "nnue_feature" },
        .{ .from = "nnue_accumulator", .imp = "position_types", .to = "position_types" },
        .{ .from = "position", .imp = "bitboard", .to = "bitboard" },
        .{ .from = "position", .imp = "movegen", .to = "movegen" },
        .{ .from = "engine", .imp = "movegen", .to = "movegen" },
        .{ .from = "position", .imp = "search", .to = "search" },
        .{ .from = "thread", .imp = "position_snapshot", .to = "position_snapshot" },
        .{ .from = "thread", .imp = "position", .to = "position" },
        .{ .from = "thread", .imp = "uci_move", .to = "uci_move" },
        .{ .from = "uci", .imp = "uci_strings", .to = "uci_strings" },
        .{ .from = "uci", .imp = "uci_format", .to = "uci_format" },
        .{ .from = "uci_format", .imp = "uci_strings", .to = "uci_strings" },
        .{ .from = "uci", .imp = "uci_parse", .to = "uci_parse" },
        .{ .from = "uci_parse", .imp = "uci_strings", .to = "uci_strings" },
        .{ .from = "uci", .imp = "benchmark", .to = "benchmark" },
        .{ .from = "uci", .imp = "misc", .to = "misc" },
        .{ .from = "uci", .imp = "engine", .to = "engine" },
        .{ .from = "uci", .imp = "option", .to = "option" },
        .{ .from = "benchmark", .imp = "libc", .to = "libc" },
        .{ .from = "misc", .imp = "libc", .to = "libc" },
        .{ .from = "thread", .imp = "libc", .to = "libc" },
        .{ .from = "engine", .imp = "uci_output", .to = "uci_output" },
        .{ .from = "uci", .imp = "uci_wdl", .to = "uci_wdl" },
        .{ .from = "uci", .imp = "uci_output", .to = "uci_output" },
        .{ .from = "uci", .imp = "engine_object", .to = "engine_object" },
        .{ .from = "uci", .imp = "worker_layout", .to = "worker_layout" },
        .{ .from = "uci", .imp = "clock", .to = "clock" },
        .{ .from = "engine", .imp = "uci_wdl", .to = "uci_wdl" },
        .{ .from = "tt", .imp = "page_alloc", .to = "page_alloc" },
        .{ .from = "tt", .imp = "tt_types", .to = "tt_types" },
        .{ .from = "position", .imp = "score", .to = "score" },
        .{ .from = "thread", .imp = "thread_vote", .to = "thread_vote" },
        .{ .from = "thread_vote", .imp = "worker_layout", .to = "worker_layout" },
        .{ .from = "search_thread", .imp = "worker_layout", .to = "worker_layout" },
        .{ .from = "search_thread", .imp = "thread_runtime", .to = "thread_runtime" },
        .{ .from = "thread", .imp = "search_thread", .to = "search_thread" },
        .{ .from = "thread", .imp = "thread_runtime", .to = "thread_runtime" },
        .{ .from = "misc", .imp = "memory", .to = "memory" },
        .{ .from = "tt", .imp = "worker_layout", .to = "worker_layout" },
        .{ .from = "tt", .imp = "thread_ops", .to = "thread_ops" },
        .{ .from = "thread", .imp = "worker_layout", .to = "worker_layout" },
        .{ .from = "engine", .imp = "worker_layout", .to = "worker_layout" },
        .{ .from = "thread", .imp = "movegen", .to = "movegen" },
        .{ .from = "uci_move", .imp = "movegen", .to = "movegen" },
        .{ .from = "uci_move", .imp = "position_types", .to = "position_types" },
        .{ .from = "thread", .imp = "tablebase", .to = "tablebase" },
        .{ .from = "thread", .imp = "option", .to = "option" },
        .{ .from = "thread", .imp = "state_list", .to = "state_list" },
        .{ .from = "engine", .imp = "tablebase", .to = "tablebase" },
        .{ .from = "engine", .imp = "option", .to = "option" },
        .{ .from = "position", .imp = "worker_layout", .to = "worker_layout" },
        .{ .from = "network", .imp = "page_alloc", .to = "page_alloc" },
        .{ .from = "network", .imp = "position_types", .to = "position_types" },
        .{ .from = "network", .imp = "nnue_accumulator", .to = "nnue_accumulator" },
    };
    for (module_edges) |e| mods.get(e.from).?.addImport(e.imp, mods.get(e.to).?);
    mods.get("misc").?.addImport("build_options", build_options_module);

    // Match upstream's codegen: its Makefile compiles `build` with -flto=full (Makefile:965)
    // while zfish shipped without it, so the two were never compiled alike. Measured on an
    // identical 178,029-node tree, bit-exact (bench stays 2466447): 4,065,662,391 ->
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
    const exe = b.addExecutable(.{
        .name = "stockfish",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/shell/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            // Omit .link_libcpp: the engine compiles zero C++ TUs (TU=0), so the C++
            // stdlib is dead weight.
        }),
    });
    exe.lto = if (want_lto) .full else .none;

    // Share a thin libc binding with the files that need C stdio etc.
    // Import as `libc` wherever a module says `const c = @import("libc")`.

    // Expose the aligned/large-page allocator as a shared module: consumers call it directly.

    // Provide typed engine-graph views (ThreadPool/Worker/... offset structs), imported
    // by the modules that read the engine graph.

    // Hold the bench positions (Defaults) and benchmark-command games (BenchmarkPositions)
    // as Zig arrays in benchmark.zig. Fetch the only external artifact, the NNUE net,
    // into net/.
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
    exe.root_module.addImport("worker_histories", mods.get("worker_histories").?);
    exe.root_module.addImport("worker_construct", mods.get("worker_construct").?);
    // Single-source default_eval_file_name in engine.zig from network.zig
    // (network has no engine dep, so this edge is acyclic).

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
    const graph_test_step = b.step("test-graph", "Run the native-graph (cut) unit tests");
    addTestRun(b, graph_test_step, graph_test, cov_dir, &cov_idx);
    // Test the sharedHists map container (std-only generic) with a mock
    // entry. board/position.zig instantiates it with the real SharedHistories.
    const sh_map_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/engine/search/shared_histories_map.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    addTestRun(b, graph_test_step, sh_map_test, cov_dir, &cov_idx);

    exe.root_module.addImport("benchmark", mods.get("benchmark").?);
    exe.root_module.addImport("bitboard", mods.get("bitboard").?);
    exe.root_module.addImport("engine", mods.get("engine").?);
    exe.root_module.addImport("evaluate", mods.get("evaluate").?);
    exe.root_module.addImport("misc", mods.get("misc").?);
    exe.root_module.addImport("movegen", mods.get("movegen").?);
    exe.root_module.addImport("movepick", mods.get("movepick").?);
    exe.root_module.addImport("nnue_accumulator", mods.get("nnue_accumulator").?);
    exe.root_module.addImport("network", mods.get("network").?);
    exe.root_module.addImport("nnue_feature", mods.get("nnue_feature").?);
    exe.root_module.addImport("nnue_misc", mods.get("nnue_misc").?);
    exe.root_module.addImport("state_list", mods.get("state_list").?);
    exe.root_module.addImport("position_storage", mods.get("position_storage").?);
    exe.root_module.addImport("option", mods.get("option").?);
    exe.root_module.addImport("position", mods.get("position").?);
    exe.root_module.addImport("position_snapshot", mods.get("position_snapshot").?);
    exe.root_module.addImport("search", mods.get("search").?);
    exe.root_module.addImport("timeman", mods.get("timeman").?);
    exe.root_module.addImport("thread", mods.get("thread").?);
    exe.root_module.addImport("tt", mods.get("tt").?);
    exe.root_module.addImport("uci", mods.get("uci").?);
    exe.root_module.addImport("uci_move", mods.get("uci_move").?);

    // Import the thin libc binding as `const c = @import("libc")` in main.zig.
    exe.root_module.addImport("libc", mods.get("libc").?);

    // Wire the direct callers of the aligned/large-page allocator.
    exe.root_module.addImport("memory", mods.get("memory").?);
    exe.root_module.addImport("worker_layout", mods.get("worker_layout").?);
    exe.root_module.addImport("position_types", mods.get("position_types").?);
    exe.root_module.addImport("clock", mods.get("clock").?);
    exe.root_module.addImport("uci_output", mods.get("uci_output").?);
    exe.root_module.addImport("uci_wdl", mods.get("uci_wdl").?);
    exe.root_module.addImport("score", mods.get("score").?);
    // Keep network free of a position import: its two Position field reads go through the
    // leaf worker_layout, which frees position -> network for the direct eval call below.

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

    // Fetch the net the Zig binary actually loads (network.zig's default_eval_file_name -- the single
    // source of truth engine.zig imports), not the net named in the stale upstream src/evaluate.h. After
    // an upstream net bump the two diverge, and the upstream scripts/net.sh would fetch the wrong file ->
    // the binary can't load its net and crashes.
    // Compile the fetcher as a Zig tool (tools/fetch_net.zig), not a `sh` script -- it
    // reads the net name from network.zig's authoritative constant, sha256-validates, and downloads
    // via std.http.Client. Build it for the host (it runs at build time). argv[1] = the net-name source.
    const fetch_net_exe = b.addExecutable(.{
        .name = "fetch_net",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/fetch_net.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseFast,
        }),
    });
    const net_cmd = b.addRunArtifact(fetch_net_exe);
    net_cmd.addFileArg(b.path("src/engine/eval/network.zig"));
    net_cmd.setCwd(b.path("net"));
    // Always run (the tool is idempotent: it validates an existing net and no-ops), so a deleted or
    // corrupt net is re-fetched.
    net_cmd.has_side_effects = true;

    const net_step = b.step(
        "net",
        "Download the default NNUE net into net/ for external-net Zig parity",
    );
    net_step.dependOn(&net_cmd.step);

    // Fetch the 3-man Syzygy tablebases (tools/fetch_tb.zig): download the ~26 KB 3-man set into
    // net/syzygy/ for the Syzygy load/probe gates. The tables are NEVER committed (see .gitignore);
    // like the net they are fetched + cached. link_libc: it uses libc mkdir (Io.Dir has no makeDir).
    const fetch_tb_exe = b.addExecutable(.{
        .name = "fetch_tb",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/fetch_tb.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseFast,
            .link_libc = true,
        }),
    });
    const tb_cmd = b.addRunArtifact(fetch_tb_exe);
    tb_cmd.setCwd(b.path("net"));
    tb_cmd.has_side_effects = true; // idempotent: skips files already present
    const tb_step = b.step(
        "tb",
        "Download the 3-man Syzygy tablebases into net/syzygy/ (for the Syzygy gates)",
    );
    tb_step.dependOn(&tb_cmd.step);

    // Drive the built engine over UCI with the pure-Zig parity harness and diff the
    // deterministic fingerprints against the committed goldens -- the cross-platform
    // replacement for the bash golden scripts (output_parity/search_parity/search_modes/
    // perft/eval/misc), so `zig build parity` runs identically on Linux/Windows/macOS with
    // no shell/coreutils dependency. Build it for the HOST (it spawns the engine as a
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
    // only ran on Linux. Default to the 2466447 arch/OS invariant; -Dsignature-ref overrides.
    const signature_reference = signature_ref orelse "2466447";
    const signature_cmd = addHarnessRun(b, harness_exe, exe, install_step, &net_cmd.step, "signature", signature_reference, "check");

    const signature_step = b.step(
        "signature",
        "Verify the Zig-built Stockfish bench signature (== 2466447 by default; -Dsignature-ref to override) via the pure-Zig parity harness",
    );
    signature_step.dependOn(&signature_cmd.step);

    // Run the per-position search-fingerprint differential harness. Localize a
    // bench-signature mismatch to a single position + drifted field.
    const search_parity_golden = repoPath(b, "tools/search_parity.golden");

    const search_parity_cmd = addHarnessRun(b, harness_exe, exe, install_step, &net_cmd.step, "search-parity", search_parity_golden, "check");

    const search_parity_step = b.step(
        "search-parity",
        "Diff per-position bench search fingerprints against the committed golden",
    );
    search_parity_step.dependOn(&search_parity_cmd.step);

    const search_parity_update_cmd = addHarnessRun(b, harness_exe, exe, install_step, &net_cmd.step, "search-parity", search_parity_golden, "update");

    const search_parity_update_step = b.step(
        "search-parity-update",
        "Regenerate tools/search_parity.golden from the current binary",
    );
    search_parity_update_step.dependOn(&search_parity_update_cmd.step);

    // Run the deterministic non-bench search-mode harness (node-limit / MultiPV /
    // searchmoves) -- validate iterative_deepening control flow beyond bench.
    const search_modes_golden = repoPath(b, "tools/search_modes.golden");

    const search_modes_cmd = addHarnessRun(b, harness_exe, exe, install_step, &net_cmd.step, "search-modes", search_modes_golden, "check");

    const search_modes_step = b.step(
        "search-modes",
        "Diff deterministic non-bench search modes against the committed golden",
    );
    search_modes_step.dependOn(&search_modes_cmd.step);

    const search_modes_update_cmd = addHarnessRun(b, harness_exe, exe, install_step, &net_cmd.step, "search-modes", search_modes_golden, "update");

    const search_modes_update_step = b.step(
        "search-modes-update",
        "Regenerate tools/search_modes.golden from the current binary",
    );
    search_modes_update_step.dependOn(&search_modes_update_cmd.step);

    // Pin the FEN-validation diagnostics (piece/pawn/king counts, side-to-move, castling,
    // en-passant, board length) and the terminate-on-critical-error behaviour -- byte-exact
    // with upstream's position.cpp messages. Regenerate on an upstream sync.
    const fen_errors_golden = repoPath(b, "tools/fen_errors.golden");

    const fen_errors_cmd = addHarnessRun(b, harness_exe, exe, install_step, &net_cmd.step, "fen-errors", fen_errors_golden, "check");

    const fen_errors_step = b.step(
        "fen-errors",
        "Diff the FEN-validation error diagnostics against the committed golden",
    );
    fen_errors_step.dependOn(&fen_errors_cmd.step);

    const fen_errors_update_cmd = addHarnessRun(b, harness_exe, exe, install_step, &net_cmd.step, "fen-errors", fen_errors_golden, "update");

    const fen_errors_update_step = b.step(
        "fen-errors-update",
        "Regenerate tools/fen_errors.golden from the current binary",
    );
    fen_errors_update_step.dependOn(&fen_errors_update_cmd.step);

    // Assert via the worktree-based upstream oracle gate that the default (Zig)
    // bench == the PRISTINE upstream Stockfish at UPSTREAM_BASE, built in a persistent
    // git worktree with ZERO vendored C++. It pins to the exact upstream sha we claim to
    // be at, and the oracle build is a cached no-op in steady state (upstream_oracle.sh
    // only rebuilds when BASE moves). Run standalone at sync time.
    const upstream_base_sha = runAndTrimOrNull(b, &.{
        "cat",
        repoPath(b, "tools/upstream/UPSTREAM_BASE"),
    }) orelse "";
    const upstream_parity_cmd = b.addSystemCommand(&.{
        "bash",
        repoPath(b, "tools/upstream_parity.sh"),
    });
    // Pass the engine binary as an artifact arg (the build supplies its path), then the
    // upstream base sha. Keep the binary out of the string array above -- an artifact arg
    // cannot live in it.
    upstream_parity_cmd.addArtifactArg(exe);
    upstream_parity_cmd.addArg(upstream_base_sha);
    upstream_parity_cmd.step.dependOn(install_step);
    upstream_parity_cmd.step.dependOn(&net_cmd.step);
    const upstream_parity_step = b.step(
        "upstream-parity",
        "Assert default (Zig) bench == pristine upstream@UPSTREAM_BASE (git worktree, no vendored C++)",
    );
    upstream_parity_step.dependOn(&upstream_parity_cmd.step);

    // Pin the stripped bench info+bestmove text against a committed golden (the full-output
    // GOLDEN gate).
    const output_golden = repoPath(b, "tools/output_parity.golden");
    const output_golden_cmd = addHarnessRun(b, harness_exe, exe, install_step, &net_cmd.step, "output-golden", output_golden, "check");

    const output_golden_step = b.step(
        "output-golden",
        "Assert the default (Zig) bench info-line output matches the committed golden",
    );
    output_golden_step.dependOn(&output_golden_cmd.step);

    const output_golden_update_cmd = addHarnessRun(b, harness_exe, exe, install_step, &net_cmd.step, "output-golden", output_golden, "update");

    const output_golden_update_step = b.step(
        "output-golden-update",
        "Regenerate tools/output_parity.golden from the current binary",
    );
    output_golden_update_step.dependOn(&output_golden_update_cmd.step);

    // Pin the search-manager driver + its emit callbacks bit-exact (driver-golden;
    // multipv/wdl/ponder/no-moves).
    const driver_golden = repoPath(b, "tools/driver.golden");
    const driver_golden_cmd = addHarnessRun(b, harness_exe, exe, install_step, &net_cmd.step, "driver-golden", driver_golden, "check");
    const driver_golden_step = b.step(
        "driver-golden",
        "Assert the search-driver + emit-callback UCI output matches the committed golden",
    );
    driver_golden_step.dependOn(&driver_golden_cmd.step);

    const driver_golden_update_cmd = addHarnessRun(b, harness_exe, exe, install_step, &net_cmd.step, "driver-golden", driver_golden, "update");
    const driver_golden_update_step = b.step(
        "driver-golden-update",
        "Regenerate tools/driver.golden from the current binary",
    );
    driver_golden_update_step.dependOn(&driver_golden_update_cmd.step);

    // Stress the thread runtime for liveness.
    // Hammer (ucinewgame -> setoption Threads -> go/stop) cycles across thread
    // counts + a construct/destroy churn, under a wall-clock watchdog. Gate on liveness
    // (no hang / crash / lost search), not determinism. Keep it out
    // of the core `parity` aggregate (slower, wall-clock-timed); run explicitly
    // for any thread-runtime slice.
    const stress_cmd = addHarnessRun(b, harness_exe, exe, install_step, &net_cmd.step, "stress", "-", "check");

    const stress_step = b.step(
        "parity-stress",
        "Thread-runtime stress/liveness: go/stop storms + construct/destroy churn",
    );
    stress_step.dependOn(&stress_cmd.step);

    // Gate memory errors / leaks: run Valgrind memcheck
    // over short multi-thread sessions, asserting no invalid access / bad free /
    // definite leak (uninit-value checking off -- NNUE SIMD makes it false-noisy).
    // Provide the ASan/LSan-equivalent net for the Worker/large-page lifecycle. Keep out of the
    // core `parity` aggregate (slow).
    const valgrind_cmd = b.addSystemCommand(&.{
        "bash",
        repoPath(b, "tools/valgrind.sh"),
    });
    valgrind_cmd.addArtifactArg(exe);
    valgrind_cmd.step.dependOn(install_step);
    valgrind_cmd.step.dependOn(&net_cmd.step);
    valgrind_cmd.setCwd(b.path("net"));

    const valgrind_step = b.step(
        "parity-valgrind",
        "Valgrind memcheck (leak / invalid-access / bad-free) across thread counts",
    );
    valgrind_step.dependOn(&valgrind_cmd.step);

    // Check multi-thread search sanity. Multi-threaded
    // search is non-deterministic (Lazy SMP), so this is a tolerance gate, not a
    // bit-exact golden: at fixed depth on calm positions, Threads {2,4} must emit
    // a well-formed bestmove and a score of the same kind/sign within a generous
    // cp band of the deterministic single-thread reference. Catch a runtime that
    // runs but corrupts result aggregation. Keep out of the core `parity` aggregate
    // (non-deterministic, sleep-paced).
    const mt_golden = repoPath(b, "tools/mt_sanity.golden");

    const mt_cmd = addHarnessRun(b, harness_exe, exe, install_step, &net_cmd.step, "mt-sanity", mt_golden, "check");

    const mt_step = b.step(
        "parity-mt",
        "Multi-thread search sanity: Threads {2,4} score-band vs single-thread golden",
    );
    mt_step.dependOn(&mt_cmd.step);

    const mt_update_cmd = addHarnessRun(b, harness_exe, exe, install_step, &net_cmd.step, "mt-sanity", mt_golden, "update");

    const mt_update_step = b.step(
        "parity-mt-update",
        "Regenerate tools/mt_sanity.golden (single-thread reference)",
    );
    mt_update_step.dependOn(&mt_update_cmd.step);

    // Gate leaks for the searchmoves / rootMoves vector lifecycle:
    // run Valgrind memcheck over a `go searchmoves` + ucinewgame churn, asserting no
    // definite leak / bad free of limits.searchmoves and worker.rootMoves -- the
    // path bench never exercises. Read the verdict from valgrind's summary and
    // tolerate the known post-exit thread-join hang under memcheck. Keep out of the
    // core `parity` aggregate (slow).
    const teardown_cmd = b.addSystemCommand(&.{
        "bash",
        repoPath(b, "tools/teardown.sh"),
    });
    teardown_cmd.addArtifactArg(exe);
    teardown_cmd.step.dependOn(install_step);
    teardown_cmd.step.dependOn(&net_cmd.step);
    teardown_cmd.setCwd(b.path("net"));

    const teardown_step = b.step(
        "parity-teardown",
        "Valgrind leak gate for searchmoves/rootMoves vector lifecycle + Worker clear",
    );
    teardown_step.dependOn(&teardown_cmd.step);

    // Check wall-clock time-management sanity: the ONLY gate over `go
    // movetime` / `go wtime` / TimeManagement.startTime -- the whole rest of the
    // battery is depth/node-limited and never consults the clock, which is how the
    // startTime=0 bug (fbcefd0d6) shipped. Base it on invariants (no golden): reported
    // elapsed must track the movetime budget and scale with it. Keep it its own step
    // (like parity-mt) since it is non-deterministic and sleep-paced, outside the core
    // deterministic `parity` aggregate; the CI workflow runs it explicitly.
    const time_cmd = addHarnessRun(b, harness_exe, exe, install_step, &net_cmd.step, "time-mgmt", "-", "check");

    const time_step = b.step(
        "parity-time",
        "Wall-clock time management: go movetime/wtime budget + clock-scaling invariants",
    );
    time_step.dependOn(&time_cmd.step);

    // Gate metamorphic TT/history reset (reset-determinism; no golden -- assert internal
    // relations in one process): a second no-reset search reuses the TT (node count changes),
    // Clear Hash removes that reuse, and ucinewgame restores the exact clean search (no stale
    // state bleed). Single-thread deterministic, so it joins the portable aggregate.
    const reset_cmd = addHarnessRun(b, harness_exe, exe, install_step, &net_cmd.step, "reset-determinism", "-", "check");

    const reset_step = b.step(
        "parity-reset",
        "Metamorphic TT/history reset: ucinewgame + Clear Hash restore state, TT reuse is live",
    );
    reset_step.dependOn(&reset_cmd.step);

    // Gate the metamorphic Skill Level (skill; no golden -- the path is RNG-seeded). Skill 20 is
    // deterministic (handicap off -> one move), Skill 0 varies (>= 2 distinct, all legal). The
    // PRNG persists per process, so K searches in one process give robust variance (measured
    // min 3 over 25 seeds). Single-thread, relations are platform-agnostic, so it joins the
    // portable aggregate.
    const skill_cmd = addHarnessRun(b, harness_exe, exe, install_step, &net_cmd.step, "skill", "-", "check");

    const skill_step = b.step(
        "parity-skill",
        "Metamorphic Skill Level gate: Skill 20 deterministic, Skill 0 random + legal",
    );
    skill_step.dependOn(&skill_cmd.step);

    // Exercise the ponder handshake (ponder; no golden -- N-time). `go ... ponder` then `ponderhit` must
    // emit a legal bestmove, `stop` during ponder must emit the best-so-far, and the process must
    // exit cleanly. Liveness + legality, platform-agnostic, so it joins the portable aggregate.
    const ponder_cmd = addHarnessRun(b, harness_exe, exe, install_step, &net_cmd.step, "ponder", "-", "check");

    const ponder_step = b.step(
        "parity-ponder",
        "Ponder handshake: go ponder -> ponderhit/stop yields a legal bestmove, clean exit",
    );
    ponder_step.dependOn(&ponder_cmd.step);

    // Exercise the binary WITHOUT the net beside it -- the ONLY gate that does (net-missing).
    // Every other gate here runs with cwd=net/ (addHarnessRun's setCwd), which hands the
    // engine the very precondition it must check -- so a startup that dies without a net
    // is invisible to all of them, and did ship that way. The harness spawns the child in
    // a scratch subdir holding no net and asserts a named diagnostic + a clean non-zero
    // exit, never a signal. Startup contract only, no search: portable, so it joins the
    // portable aggregate.
    const net_missing_cmd = addHarnessRun(b, harness_exe, exe, install_step, &net_cmd.step, "net-missing", "-", "check");

    const net_missing_step = b.step(
        "parity-net-missing",
        "Missing-net startup: a named diagnostic + clean non-zero exit, never a signal",
    );
    net_missing_step.dependOn(&net_missing_cmd.step);

    // Diff perft against a golden -- the ONLY gate over
    // do_move/undo_move + the legal movegen + the UCI move formatter (bench never runs
    // perft; search-modes only checks bestmoves), pinned against the committed golden.
    const perft_golden = repoPath(b, "tools/perft.golden");
    const perft_cmd = addHarnessRun(b, harness_exe, exe, install_step, &net_cmd.step, "perft", perft_golden, "check");

    const perft_step = b.step(
        "perft",
        "Diff perft divide counts + totals against the committed golden (do_move/undo_move/movegen)",
    );
    perft_step.dependOn(&perft_cmd.step);

    const perft_update_cmd = addHarnessRun(b, harness_exe, exe, install_step, &net_cmd.step, "perft", perft_golden, "update");

    const perft_update_step = b.step(
        "perft-update",
        "Regenerate tools/perft.golden from the current binary",
    );
    perft_update_step.dependOn(&perft_update_cmd.step);

    // Pin the NNUE `eval` trace block against a golden
    // (buildNnueTrace + the network-ptr / accumulator-cache trace path) — bench covers the eval
    // value but not this formatting path.
    const eval_golden = repoPath(b, "tools/eval.golden");
    const eval_cmd = addHarnessRun(b, harness_exe, exe, install_step, &net_cmd.step, "eval", eval_golden, "check");

    const eval_step = b.step(
        "eval-trace",
        "Diff the NNUE eval trace block against the committed golden (buildNnueTrace path)",
    );
    eval_step.dependOn(&eval_cmd.step);

    const eval_update_cmd = addHarnessRun(b, harness_exe, exe, install_step, &net_cmd.step, "eval", eval_golden, "update");

    const eval_update_step = b.step(
        "eval-trace-update",
        "Regenerate tools/eval.golden from the current binary",
    );
    eval_update_step.dependOn(&eval_update_cmd.step);

    // Gate the UCI misc commands (coverage tail): d/flip Fen+Key+Checkers — the
    // Position fen/flip/zobrist/gives_check read paths no other gate touches.
    const misc_golden = repoPath(b, "tools/misc.golden");
    const misc_cmd = addHarnessRun(b, harness_exe, exe, install_step, &net_cmd.step, "misc", misc_golden, "check");

    const misc_step = b.step(
        "misc",
        "Diff d/flip (Fen/Key/Checkers) against the committed golden (fen/flip/zobrist/gives_check)",
    );
    misc_step.dependOn(&misc_cmd.step);

    const misc_update_cmd = addHarnessRun(b, harness_exe, exe, install_step, &net_cmd.step, "misc", misc_golden, "update");

    const misc_update_step = b.step(
        "misc-update",
        "Regenerate tools/misc.golden from the current binary",
    );
    misc_update_step.dependOn(&misc_update_cmd.step);

    // Pin the length + FNV-1a of the net produced by `export_net` (export-net golden). The
    // serializer (write_parameters) must reproduce the canonical .nnue byte-for-byte;
    // upstream round-trips to the input net exactly, so a matching hash is a
    // differential-vs-upstream check (zfish export == oracle export == distributed net).
    // The net bytes are arch/OS-invariant, so the golden is portable. Regenerate on a net
    // bump alongside the other goldens.
    const export_net_golden = repoPath(b, "tools/export_net.golden");
    const export_net_cmd = addHarnessRun(b, harness_exe, exe, install_step, &net_cmd.step, "export-net", export_net_golden, "check");

    const export_net_step = b.step(
        "export-net",
        "Diff the export_net (write_parameters) net fingerprint against the committed golden",
    );
    export_net_step.dependOn(&export_net_cmd.step);

    const export_net_update_cmd = addHarnessRun(b, harness_exe, exe, install_step, &net_cmd.step, "export-net", export_net_golden, "update");

    const export_net_update_step = b.step(
        "export-net-update",
        "Regenerate tools/export_net.golden from the current binary",
    );
    export_net_update_step.dependOn(&export_net_update_cmd.step);

    // Pin the nodestime allocation (nodestime golden): `nodestime` converts wall-clock budgets into a NODE budget, so the
    // time-management allocation path is deterministic (bit-exact) rather than the reported-ms
    // band the `parity-time` gate checks. Pin depth/score/nodes/bestmove across the allocation
    // branches (sudden-death / movestogo / increment / movetime). Node budgets are
    // arch/OS-invariant, so the golden is portable.
    const nodestime_golden = repoPath(b, "tools/nodestime.golden");
    const nodestime_cmd = addHarnessRun(b, harness_exe, exe, install_step, &net_cmd.step, "nodestime", nodestime_golden, "check");

    const nodestime_step = b.step(
        "nodestime",
        "Diff the nodestime time-management allocation (node budget) against the committed golden",
    );
    nodestime_step.dependOn(&nodestime_cmd.step);

    const nodestime_update_cmd = addHarnessRun(b, harness_exe, exe, install_step, &net_cmd.step, "nodestime", nodestime_golden, "update");

    const nodestime_update_step = b.step(
        "nodestime-update",
        "Regenerate tools/nodestime.golden from the current binary",
    );
    nodestime_update_step.dependOn(&nodestime_update_cmd.step);

    // Pin the `uci` handshake `option name ...` lines (uci-options golden; the GUI compatibility
    // surface). Pin only the option lines -- the id name / author + banner carry the
    // git sha/date and are volatile. Defaults/min/max are static constants (machine-invariant),
    // so the golden is portable; EvalFile's default is the net name, regenerated on a net bump.
    const uci_options_golden = repoPath(b, "tools/uci_options.golden");
    const uci_options_cmd = addHarnessRun(b, harness_exe, exe, install_step, &net_cmd.step, "uci-options", uci_options_golden, "check");

    const uci_options_step = b.step(
        "uci-options",
        "Diff the `uci` option-list handshake against the committed golden",
    );
    uci_options_step.dependOn(&uci_options_cmd.step);

    const uci_options_update_cmd = addHarnessRun(b, harness_exe, exe, install_step, &net_cmd.step, "uci-options", uci_options_golden, "update");

    const uci_options_update_step = b.step(
        "uci-options-update",
        "Regenerate tools/uci_options.golden from the current binary",
    );
    uci_options_update_step.dependOn(&uci_options_update_cmd.step);

    // Pin `go mate N` (mate golden; mate-distance search mode). Pin the reported mate DISTANCE
    // (score mate N) and the mating move+ponder across three verified forced mates (mate in
    // 1/2/3) -- a bestmove-only check would miss a wrong-distance regression. Single-thread and
    // mate-distance-deterministic, so arch/OS-invariant and portable.
    const mate_golden = repoPath(b, "tools/mate.golden");
    const mate_cmd = addHarnessRun(b, harness_exe, exe, install_step, &net_cmd.step, "mate", mate_golden, "check");

    const mate_step = b.step(
        "mate",
        "Diff `go mate N` (mate distance + move) against the committed golden",
    );
    mate_step.dependOn(&mate_cmd.step);

    const mate_update_cmd = addHarnessRun(b, harness_exe, exe, install_step, &net_cmd.step, "mate", mate_golden, "update");

    const mate_update_step = b.step(
        "mate-update",
        "Regenerate tools/mate.golden from the current binary",
    );
    mate_update_step.dependOn(&mate_update_cmd.step);

    // Pin UCI_Chess960 search + castling encoding + eval (chess960 golden). perft covers FRC
    // movegen counts; this pins FRC castling made/unmade in a real search, the played
    // king-to-rook-square castling move (f1g1 = O-O) via `d`, and the NNUE eval on FRC king
    // placements. Single-thread + node budget -> arch/OS-invariant, so the golden is portable.
    const chess960_golden = repoPath(b, "tools/chess960.golden");
    const chess960_cmd = addHarnessRun(b, harness_exe, exe, install_step, &net_cmd.step, "chess960", chess960_golden, "check");

    const chess960_step = b.step(
        "chess960",
        "Diff UCI_Chess960 search + castling + eval against the committed golden",
    );
    chess960_step.dependOn(&chess960_cmd.step);

    const chess960_update_cmd = addHarnessRun(b, harness_exe, exe, install_step, &net_cmd.step, "chess960", chess960_golden, "update");

    const chess960_update_step = b.step(
        "chess960-update",
        "Regenerate tools/chess960.golden from the current binary",
    );
    chess960_update_step.dependOn(&chess960_update_cmd.step);

    // Pin bench node counts for non-default configs (bench-matrix golden; hash size / shallow
    // depth / node limit / bench-perft) -- distinct deterministic code paths the default
    // signature (2466447) never exercises, each verified equal to the upstream oracle.
    // Keep Linux-only (`parity`, not `parity-portable`): verified bit-exact on x86 in both build
    // modes, but the node-limited config's cross-arch equality is not locally verifiable, and
    // the default bench already gates cross-OS signature. Regenerate on an upstream bump.
    const bench_matrix_golden = repoPath(b, "tools/bench_matrix.golden");
    const bench_matrix_cmd = addHarnessRun(b, harness_exe, exe, install_step, &net_cmd.step, "bench-matrix", bench_matrix_golden, "check");

    const bench_matrix_step = b.step(
        "bench-matrix",
        "Diff non-default bench node counts (hash/depth/nodes/perft configs) against the golden",
    );
    bench_matrix_step.dependOn(&bench_matrix_cmd.step);

    const bench_matrix_update_cmd = addHarnessRun(b, harness_exe, exe, install_step, &net_cmd.step, "bench-matrix", bench_matrix_golden, "update");

    const bench_matrix_update_step = b.step(
        "bench-matrix-update",
        "Regenerate tools/bench_matrix.golden from the current binary",
    );
    bench_matrix_update_step.dependOn(&bench_matrix_update_cmd.step);

    // Pin the Syzygy load report (tb-init golden; M-SZ-1). Set SyzygyPath to the fetched 3-man set
    // (net/syzygy/) and pin the `info string Found N WDL and N DTZ ... (up to M-man)` line ==
    // upstream oracle. Depend on the `tb` fetch too. Keep Linux-only (`parity`, not portable): the
    // fetched tables + libc file-check are verified on Linux; cross-OS Syzygy comes with M-SZ-4.
    const tb_init_golden = repoPath(b, "tools/tb_init.golden");
    const tb_init_cmd = addHarnessRun(b, harness_exe, exe, install_step, &net_cmd.step, "tb-init", tb_init_golden, "check");
    tb_init_cmd.step.dependOn(&tb_cmd.step);

    const tb_init_step = b.step(
        "tb-init",
        "Diff the Syzygy load report (Found N WDL/DTZ, up to M-man) against the golden",
    );
    tb_init_step.dependOn(&tb_init_cmd.step);

    const tb_init_update_cmd = addHarnessRun(b, harness_exe, exe, install_step, &net_cmd.step, "tb-init", tb_init_golden, "update");
    tb_init_update_cmd.step.dependOn(&tb_cmd.step);

    const tb_init_update_step = b.step(
        "tb-init-update",
        "Regenerate tools/tb_init.golden from the current binary",
    );
    tb_init_update_step.dependOn(&tb_init_update_cmd.step);

    // Pin the Syzygy WDL probe (tb-wdl golden; M-SZ-2c). Set SyzygyPath to net/syzygy and pin the
    // `d`-command `Tablebases WDL: N (state)` line == upstream oracle for a curated 3-man battery
    // (all five piece types, win/loss/draw, wtm/btm, pawn + blackStronger flips, and the
    // search<false> capture recursion). Keep Linux-only (like tb-init); depend on the `tb` fetch.
    const tb_wdl_golden = repoPath(b, "tools/tb_wdl.golden");
    const tb_wdl_cmd = addHarnessRun(b, harness_exe, exe, install_step, &net_cmd.step, "tb-wdl", tb_wdl_golden, "check");
    tb_wdl_cmd.step.dependOn(&tb_cmd.step);

    const tb_wdl_step = b.step(
        "tb-wdl",
        "Diff the Syzygy WDL probe (KQvK/KPvK/... == oracle) against the golden",
    );
    tb_wdl_step.dependOn(&tb_wdl_cmd.step);

    const tb_wdl_update_cmd = addHarnessRun(b, harness_exe, exe, install_step, &net_cmd.step, "tb-wdl", tb_wdl_golden, "update");
    tb_wdl_update_cmd.step.dependOn(&tb_cmd.step);

    const tb_wdl_update_step = b.step(
        "tb-wdl-update",
        "Regenerate tools/tb_wdl.golden from the current binary",
    );
    tb_wdl_update_step.dependOn(&tb_wdl_update_cmd.step);

    // Pin the Syzygy DTZ probe (tb-dtz golden; M-SZ-3a). Reuse the tb-wdl 3-man battery but pin the
    // `d`-command `Tablebases DTZ: N (state)` line == upstream oracle -- exercising do_probe_table
    // <DTZ>, the DTZ value map, and the CHANGE_STM 1-ply search (KQvK-btm). Keep Linux-only; needs `tb`.
    const tb_dtz_golden = repoPath(b, "tools/tb_dtz.golden");
    const tb_dtz_cmd = addHarnessRun(b, harness_exe, exe, install_step, &net_cmd.step, "tb-dtz", tb_dtz_golden, "check");
    tb_dtz_cmd.step.dependOn(&tb_cmd.step);

    const tb_dtz_step = b.step(
        "tb-dtz",
        "Diff the Syzygy DTZ probe (KQvK/KPvK/... == oracle) against the golden",
    );
    tb_dtz_step.dependOn(&tb_dtz_cmd.step);

    const tb_dtz_update_cmd = addHarnessRun(b, harness_exe, exe, install_step, &net_cmd.step, "tb-dtz", tb_dtz_golden, "update");
    tb_dtz_update_cmd.step.dependOn(&tb_cmd.step);

    const tb_dtz_update_step = b.step(
        "tb-dtz-update",
        "Regenerate tools/tb_dtz.golden from the current binary",
    );
    tb_dtz_update_step.dependOn(&tb_dtz_update_cmd.step);

    // Pin the Syzygy root DTZ ranking (tb-root golden; M-SZ-3b). Run `go` on TB wins and pin
    // bestmove + tbScore + tbHits == upstream oracle, first-validating rankRootMovesDtz end to end.
    const tb_root_golden = repoPath(b, "tools/tb_root.golden");
    const tb_root_cmd = addHarnessRun(b, harness_exe, exe, install_step, &net_cmd.step, "tb-root", tb_root_golden, "check");
    tb_root_cmd.step.dependOn(&tb_cmd.step);

    const tb_root_step = b.step(
        "tb-root",
        "Diff the Syzygy root DTZ ranking (bestmove/score/tbhits == oracle) against the golden",
    );
    tb_root_step.dependOn(&tb_root_cmd.step);

    const tb_root_update_cmd = addHarnessRun(b, harness_exe, exe, install_step, &net_cmd.step, "tb-root", tb_root_golden, "update");
    tb_root_update_cmd.step.dependOn(&tb_cmd.step);

    const tb_root_update_step = b.step(
        "tb-root-update",
        "Regenerate tools/tb_root.golden from the current binary",
    );
    tb_root_update_step.dependOn(&tb_root_update_cmd.step);

    // Pin the in-search Step 6 WDL probe (tb-search golden; M-SZ-4). Bench a 4-man EPD; the node
    // count with Step 6 on (SyzygyPath set) and off both pin == upstream oracle -- bit-exact
    // node-count parity that the in-tree probe shapes. Keep Linux-only; depend on the `tb` fetch.
    const tb_search_golden = repoPath(b, "tools/tb_search.golden");
    const tb_search_cmd = addHarnessRun(b, harness_exe, exe, install_step, &net_cmd.step, "tb-search", tb_search_golden, "check");
    tb_search_cmd.step.dependOn(&tb_cmd.step);

    const tb_search_step = b.step(
        "tb-search",
        "Diff the in-search Step 6 node count (with/without TB == oracle) against the golden",
    );
    tb_search_step.dependOn(&tb_search_cmd.step);

    const tb_search_update_cmd = addHarnessRun(b, harness_exe, exe, install_step, &net_cmd.step, "tb-search", tb_search_golden, "update");
    tb_search_update_cmd.step.dependOn(&tb_cmd.step);

    const tb_search_update_step = b.step(
        "tb-search-update",
        "Regenerate tools/tb_search.golden from the current binary",
    );
    tb_search_update_step.dependOn(&tb_search_update_cmd.step);

    // Pin cursed-win / blessed-loss / 50-move (tb-cursed golden; M-SZ-5). Run LOCAL ONLY -- needs ~40 MB of
    // 5-man tables staged into net/syzygy5/ (see buildTbCursed's comment), which the 3-man CI set
    // never contains, so this is NOT wired into `parity`. Pin WDL+DTZ of a KNNvKP cursed win
    // (+1/122) and its blessed-loss mirror (-1/-115) == the upstream oracle.
    const tb_cursed_golden = repoPath(b, "tools/tb_cursed.golden");
    const tb_cursed_cmd = addHarnessRun(b, harness_exe, exe, install_step, &net_cmd.step, "tb-cursed", tb_cursed_golden, "check");

    const tb_cursed_step = b.step(
        "tb-cursed",
        "LOCAL: diff cursed-win/blessed-loss WDL+DTZ (needs net/syzygy5/ 5-man tables) vs golden",
    );
    tb_cursed_step.dependOn(&tb_cursed_cmd.step);

    const tb_cursed_update_cmd = addHarnessRun(b, harness_exe, exe, install_step, &net_cmd.step, "tb-cursed", tb_cursed_golden, "update");
    const tb_cursed_update_step = b.step(
        "tb-cursed-update",
        "LOCAL: regenerate tools/tb_cursed.golden from the current binary",
    );
    tb_cursed_update_step.dependOn(&tb_cursed_update_cmd.step);

    // Assert via the src-free / TU=0 structural gate that the
    // shipped binary contains zero C++ TUs (no Stockfish:: / libc++ runtime symbols) and still
    // benches 2466447. Keep it a permanent invariant in the `parity` aggregate below, guarding
    // against any C++ TU being reintroduced into the default binary.
    const src_free_cmd = b.addSystemCommand(&.{
        "bash",
        repoPath(b, "tools/src_free.sh"),
    });
    src_free_cmd.addArtifactArg(exe);
    src_free_cmd.step.dependOn(install_step);
    src_free_cmd.step.dependOn(&net_cmd.step);
    src_free_cmd.setCwd(b.path("net"));

    const src_free_step = b.step(
        "src-free",
        "src-free structural gate: zero C++ Stockfish/libc++ symbols in the shipped binary",
    );
    src_free_step.dependOn(&src_free_cmd.step);

    // Gate the headless engine structurally: src/engine/ must import only engine/ modules,
    // never platform/ or shell/. The seams are injected one at a time, so the up-edge
    // count only ratchets down; the baseline is the currently-allowed maximum and the
    // gate fails if the real count exceeds it. Lower it as each seam is severed; at 0
    // the engine is a standalone search+eval library.
    const headless_baseline = "0";
    const headless_cmd = b.addSystemCommand(&.{
        "bash",
        repoPath(b, "tools/headless_lint.sh"),
    });
    headless_cmd.setEnvironmentVariable("HEADLESS_BASELINE", headless_baseline);
    const headless_step = b.step(
        "headless",
        "headless-engine structural gate: engine/ imports only engine/ (ratchets to 0)",
    );
    headless_step.dependOn(&headless_cmd.step);

    // Gate god-files structurally: ratchet on the count of .zig files >= 500 lines across ALL
    // repo-owned code (src/ + build.zig + tools/), so the "no god-files" property is enforced
    // repo-wide, not just claimed. An earlier src/-only scan was blind to the two LARGEST files:
    // build.zig (2245, the declarative module graph) and tools/parity_harness.zig (1888, the gate
    // driver). Both are cohesive-not-god (a build script, a test harness), so they are waived at
    // baseline 2 -- but a THIRD (or growth of a smaller file past the line) fails the gate. Two
    // earlier splits ratcheted this down: syzygy/wdl.zig 832 -> wdl 490 + registry 371, and
    // shell/engine.zig 505 -> the engine.zig face (116) + engine/session.zig driver (413).
    const loc_baseline = "2";
    const loc_cmd = b.addSystemCommand(&.{
        "bash",
        repoPath(b, "tools/loc_lint.sh"),
    });
    loc_cmd.setEnvironmentVariable("LOC_BASELINE", loc_baseline);
    const loc_step = b.step(
        "loc",
        "god-file structural gate: no new .zig file >= 500 lines (ratchets down)",
    );
    loc_step.dependOn(&loc_cmd.step);

    // Gate docs/ against the tree it describes. Docs are accurate when written and rot where
    // the code moves under them: a hostile audit found a path pointing at a split-away module,
    // the bench anchor quoted as 2067208 in five places while build.zig said 2466447, and link
    // targets that broke on a renumber. All three are mechanical, and all three shipped because
    // nothing checked. This does NOT check whether a sentence is true -- "numa_context is a
    // never-dereferenced stub handle" parsed, linked, and was false for weeks; only reading the
    // code finds that. It buys the cheap half so review can spend attention on the expensive half.
    const docs_cmd = b.addSystemCommand(&.{
        "bash",
        repoPath(b, "tools/docs_lint.sh"),
    });
    const docs_step = b.step(
        "docs-lint",
        "docs rot gate: every link resolves, every named src/tools path exists, the bench anchor matches build.zig",
    );
    docs_step.dependOn(&docs_cmd.step);

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
    const hook_lint_exe = b.addExecutable(.{
        .name = "hook_lint",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/hook_lint.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const hook_lint_cmd = b.addRunArtifact(hook_lint_exe);
    hook_lint_cmd.setCwd(b.path("."));
    const hook_lint_step = b.step(
        "hook-lint",
        "Cycle-break hooks: ratcheted at 30, each declaring a failure mode + class, all registered",
    );
    hook_lint_step.dependOn(&hook_lint_cmd.step);

    // Report Lakos coupling at BOTH granularities + the two tripwires the
    // compiler will not give (arch-report; G1). REPORT the numbers, never gate them -- Lakos's
    // NCCD ~1.0 assumes cycles cost compile time, and zfish compiles as one LLVM
    // module where they cost nothing measurable. The GATEABLE properties are binary:
    // the module graph is a DAG (Zig permits cycles -- spike), and every file SCC is
    // a declared component. Report unused declared edges, do not gate them.
    // Choose .Debug: see hook_lint_exe above -- the checking allocator is the point.
    const arch_report_exe = b.addExecutable(.{
        .name = "arch_report",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/arch_report.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const arch_report_cmd = b.addRunArtifact(arch_report_exe);
    arch_report_cmd.setCwd(b.path("."));
    const arch_report_step = b.step(
        "arch-report",
        "Coupling report (module + file graphs) + DAG / undeclared-SCC tripwires",
    );
    arch_report_step.dependOn(&arch_report_cmd.step);

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
        addTestRun(b, test_step, unit_test, cov_dir, &cov_idx);
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
    addTestRun(b, test_step, numa_test, cov_dir, &cov_idx);

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
    addTestRun(b, test_step, option_test, cov_dir, &cov_idx);

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
    addTestRun(b, test_step, board_props_test, cov_dir, &cov_idx);

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
    addTestRun(b, test_step, uci_parse_test, cov_dir, &cov_idx);

    // Build the coverage-guided fuzz targets (std.testing.fuzz). Wire them to their OWN
    // `zig build fuzz` step, deliberately NOT test_step -- these are meant to be run
    // with `zig build fuzz --fuzz` (the fuzzer), and run once as a smoke otherwise.
    // Build under -Doptimize=ReleaseSafe so a found crash trips a safety check.
    const fuzz_targets_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/engine/board/fuzz_targets.zig"),
            .target = target,
            .optimize = optimize,
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
    const fuzz_step = b.step("fuzz", "Run the coverage-guided fuzz targets (add --fuzz to fuzz)");
    fuzz_step.dependOn(&b.addRunArtifact(fuzz_targets_test).step);

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
        "tools/parity_harness.zig",
    }) |src_path| {
        const file_test = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(src_path),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }),
        });
        addTestRun(b, test_step, file_test, cov_dir, &cov_idx);
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
            @panic("module_unit_test_names references an unknown module");
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
        const tm_test = b.addTest(.{ .root_module = tm });
        addTestRun(b, test_step, tm_test, cov_dir, &cov_idx);
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
        .{ .path = "src/engine/search/search_control.zig", .deps = &.{ "time_source", "search_ctx", "search_types" } },
        .{ .path = "src/shell/engine/control.zig", .deps = &.{ "libc", "worker_layout", "engine_object", "tt", "thread", "option", "tablebase" } },
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
        addTestRun(b, test_step, t, cov_dir, &cov_idx);
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
    addTestRun(b, test_step, state_list_test, cov_dir, &cov_idx);

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
    addTestRun(b, test_step, thread_pool_test, cov_dir, &cov_idx);

    const parity_step = b.step(
        "parity",
        "Run the current bench, UCI, and signature checks through the Zig build entry",
    );
    // Assemble the per-push `parity` aggregate: whole-engine regression is caught by `signature`
    // (== 2466447) and the GOLDEN gates (output-golden / perft / eval-trace / misc /
    // search-parity / search-modes), all in-repo. The authoritative
    // differential-vs-real-upstream check is `upstream-parity` (worktree oracle), run at
    // sync time where upstream is already fetched -- per push it would only re-assert the
    // same 2466447 the signature checks.
    parity_step.dependOn(&bench_run.step);
    parity_step.dependOn(&uci_run.step);
    parity_step.dependOn(&signature_cmd.step);
    parity_step.dependOn(&search_parity_cmd.step);
    parity_step.dependOn(&search_modes_cmd.step);
    parity_step.dependOn(&fen_errors_cmd.step);
    parity_step.dependOn(&output_golden_cmd.step);
    parity_step.dependOn(&driver_golden_cmd.step);
    parity_step.dependOn(&perft_cmd.step);
    parity_step.dependOn(&eval_cmd.step);
    parity_step.dependOn(&misc_cmd.step);
    parity_step.dependOn(&export_net_cmd.step);
    parity_step.dependOn(&nodestime_cmd.step);
    parity_step.dependOn(&uci_options_cmd.step);
    parity_step.dependOn(&mate_cmd.step);
    parity_step.dependOn(&chess960_cmd.step);
    parity_step.dependOn(&reset_cmd.step);
    parity_step.dependOn(&skill_cmd.step);
    parity_step.dependOn(&ponder_cmd.step);
    parity_step.dependOn(&net_missing_cmd.step);
    parity_step.dependOn(&hook_lint_cmd.step);
    parity_step.dependOn(&arch_report_cmd.step);
    parity_step.dependOn(&bench_matrix_cmd.step);
    parity_step.dependOn(&tb_init_cmd.step);
    parity_step.dependOn(&tb_wdl_cmd.step);
    parity_step.dependOn(&tb_dtz_cmd.step);
    parity_step.dependOn(&tb_root_cmd.step);
    parity_step.dependOn(&tb_search_cmd.step);
    // Join the interactive concurrency/timing gates to the core aggregate: they run in
    // the pure-Zig harness.
    parity_step.dependOn(&mt_cmd.step);
    parity_step.dependOn(&stress_cmd.step);
    parity_step.dependOn(&time_cmd.step);
    // Gate every push on the permanent src-free structural invariant.
    parity_step.dependOn(&src_free_cmd.step);
    parity_step.dependOn(&headless_cmd.step);
    parity_step.dependOn(&loc_cmd.step);
    parity_step.dependOn(&docs_cmd.step);

    // Assemble the cross-OS aggregate: the platform-independent subset of `parity` -- bench,
    // the UCI handshake, the bench signature, and all six golden checks, every one driven by
    // the pure-Zig harness (no bash / no nm). This is what the Windows and macOS lanes run;
    // the Linux-only structural gates (src-free via `nm`, arch-determinism) stay in `parity`.
    // Reuse the same harness `signature_cmd` `parity` uses for the bench signature (2466447 invariant).
    const parity_portable_step = b.step(
        "parity-portable",
        "Cross-OS parity via the pure-Zig harness: signature + seven golden gates + mt/stress/time",
    );
    parity_portable_step.dependOn(&bench_run.step);
    parity_portable_step.dependOn(&uci_run.step);
    parity_portable_step.dependOn(&signature_cmd.step);
    parity_portable_step.dependOn(&search_parity_cmd.step);
    parity_portable_step.dependOn(&search_modes_cmd.step);
    parity_portable_step.dependOn(&fen_errors_cmd.step);
    parity_portable_step.dependOn(&output_golden_cmd.step);
    // Include driver-golden: it is node-deterministic (its depth-limited info/bestmove lines are
    // bit-exact like bench, not wall-clock-gated), so it is OS/arch-invariant like the other
    // golden gates -- its earlier absence here was an oversight.
    parity_portable_step.dependOn(&driver_golden_cmd.step);
    parity_portable_step.dependOn(&perft_cmd.step);
    parity_portable_step.dependOn(&eval_cmd.step);
    parity_portable_step.dependOn(&misc_cmd.step);
    parity_portable_step.dependOn(&export_net_cmd.step);
    parity_portable_step.dependOn(&nodestime_cmd.step);
    parity_portable_step.dependOn(&uci_options_cmd.step);
    parity_portable_step.dependOn(&mate_cmd.step);
    parity_portable_step.dependOn(&chess960_cmd.step);
    parity_portable_step.dependOn(&reset_cmd.step);
    parity_portable_step.dependOn(&skill_cmd.step);
    parity_portable_step.dependOn(&ponder_cmd.step);
    parity_portable_step.dependOn(&net_missing_cmd.step);
    parity_portable_step.dependOn(&hook_lint_cmd.step);
    parity_portable_step.dependOn(&arch_report_cmd.step);
    // Add the concurrency + timing gates -- the cross-OS payoff: these exercise the
    // sync primitives (futex / RtlWaitOnAddress / __ulock) under real threading and the
    // steady clock (QueryPerformanceCounter on Windows) on every OS, not just Linux.
    parity_portable_step.dependOn(&mt_cmd.step);
    parity_portable_step.dependOn(&stress_cmd.step);
    parity_portable_step.dependOn(&time_cmd.step);

    const stockfish_step = b.step(
        "stockfish",
        "Build the Zig-owned Stockfish engine for Linux x86_64 / aarch64",
    );
    stockfish_step.dependOn(install_step);
}

// Wire a unit-test artifact into `step` for coverage. Without coverage this is the plain
// `b.addRunArtifact`. With `-Dtest-coverage` (cov_dir set) the binary runs under kcov into its
// OWN subdir `kcov-out/cov-N` -- unique per artifact so the parallel test runs never write the
// same directory -- and CI merges the subdirs afterwards. `--include-path=src` scopes coverage
// to the owned source. Verified locally with a stub `kcov` (arg order + every artifact runs);
// CI installs the real kcov.
fn addTestRun(b: *std.Build, step: *std.Build.Step, artifact: *std.Build.Step.Compile, cov_dir: ?[]const u8, cov_idx: *usize) void {
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

// Wire one pure-Zig parity-harness invocation: run the harness (host) with the
// engine binary, golden path, and mode, from net/ so the spawned engine finds the net.
// Resolve a repo-root-relative path to an absolute string. Read the build root from
// whichever field the running std.Build exposes -- 0.16 build_root: Cache.Directory,
// 0.17 root: Cache.Path -- so this compiles on both; the comptime @hasField branch
// prunes the absent field.
fn repoPath(b: *std.Build, sub: []const u8) []const u8 {
    const root: []const u8 = if (@hasField(std.Build, "build_root"))
        (b.build_root.path orelse ".")
    else
        (b.root.root_dir.path orelse ".");
    return b.pathResolve(&.{ root, sub });
}

fn addHarnessRun(
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
    // Build the harness argv as <check> <engine binary> <golden-or-expected> <mode>.
    // Pass the binary as an artifact arg (the build supplies its path), splitting it out
    // of the surrounding string args.
    run.addArg(check_name);
    run.addArtifactArg(stockfish);
    run.addArgs(&.{ golden_or_expected, mode });
    run.setCwd(b.path("net"));
    run.step.dependOn(install_step);
    run.step.dependOn(net_step);
    return run;
}

fn applyMacros(module: *std.Build.Module, macros: []const Macro) void {
    for (macros) |macro|
        module.addCMacro(macro.name, macro.value);
}

// Map the native CPU -> best Stockfish ARCH tier in pure, unit-tested Zig (tools/native_arch.zig).
// Use the host CPU features Zig's build graph already resolved via cpuid -- no
// /proc/cpuinfo grep, no `sh`.
const native_arch = @import("tools/native_arch.zig");

fn resolveArch(b: *std.Build, requested_arch: []const u8) ArchConfig {
    const arch_name = if (std.mem.eql(u8, requested_arch, "native"))
        native_arch.detectArchFromCpu(b.graph.host.result.cpu)
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

    // Map the non-x86 tiers. The pure-Zig @Vector NNUE lowers to NEON with no source
    // changes, so these just map the aarch64 CPU features to a Zig aarch64 target.
    // NEON is mandatory in AArch64 (baseline has it); dotprod (sdot) is added where
    // present. Runtime-validated under qemu-user in CI (bench == 2466447), matching
    // upstream's arm_compilation.yml.
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
    const repo_root = repoPath(b, ".");

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
