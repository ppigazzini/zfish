const std = @import("std");

const Macro = struct {
    name: []const u8,
    value: []const u8,
};

// Owned runtime OSes. Selected with -Dos=; each maps to an (os_tag, abi) pair
// in build(). Orthogonal to -Darch= (the ISA tier), so any arch tier can target any OS.
const TargetOs = enum { linux, windows, macos };

const ArchConfig = struct {
    name: []const u8,
    flags: []const []const u8,
    macros: []const Macro,
    target_features: std.Target.Cpu.Feature.Set,
    // Owned runtime is x86_64 by default; non-x86 tiers set this so the pure
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
        "Expected bench signature for the `signature` step; defaults to the 2067208 invariant",
    );
    const requested_arch = b.option(
        []const u8,
        "arch",
        "Stockfish ARCH value (e.g. x86-64-avx2), or 'native' to auto-detect the host CPU tier in Zig",
    ) orelse "native";
    const arch = resolveArch(b, requested_arch);
    // `-Dtest-coverage` runs each unit-test binary under kcov, merging line coverage
    // into ./kcov-out (one subdir per test artifact -> no parallel-write race). kcov
    // instruments the ELF at runtime, so no coverage rebuild flags are needed; default off
    // (every normal `zig build test` runs the artifact directly, unchanged). CI installs kcov,
    // merges the subdirs, and uploads the report. See addTestRun.
    const test_coverage = b.option(
        bool,
        "test-coverage",
        "Run the unit tests under kcov, merging line coverage into ./kcov-out (needs kcov on PATH)",
    ) orelse false;
    // Relative "kcov-out" (not b.pathFromRoot): the Run step's default cwd is the build root, so
    // kcov writes there -- and a plain string stays valid across Zig 0.16/0.17 (pathFromRoot was
    // removed in 0.17), which keeps the non-blocking nightly lane building instead of tripping here.
    const cov_dir: ?[]const u8 = if (test_coverage) "kcov-out" else null;
    var cov_idx: usize = 0;
    // Owned runtime targets: Linux (default), Windows, and macOS. The pure-Zig
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

    // Module graph as data: each engine module is a uniform {name, path}
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
        .{ .name = "shared_histories_map", .path = "src/engine/search/shared_histories_map.zig" },
        .{ .name = "network_holder", .path = "src/engine/eval/network_holder.zig" },
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
        // search_manager and root_move_build are registered as named modules (not path-imported
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
        // Import edges for the standalone named modules search_manager and root_move_build.
        .{ .from = "engine", .imp = "search_manager", .to = "search_manager" },
        .{ .from = "thread", .imp = "root_move_build", .to = "root_move_build" },
        .{ .from = "root_move_build", .imp = "position", .to = "position" },
        .{ .from = "root_move_build", .imp = "state_list", .to = "state_list" },
        .{ .from = "root_move_build", .imp = "tb_source", .to = "tb_source" },
        .{ .from = "tablebase", .imp = "tb_source", .to = "tb_source" },
        .{ .from = "root_move_build", .imp = "option_source", .to = "option_source" },
        .{ .from = "root_move_build", .imp = "movegen", .to = "movegen" },
        .{ .from = "root_move_build", .imp = "position_snapshot", .to = "position_snapshot" },
        // Consumers import the owning search modules directly: search_driver's public
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
        .{ .from = "search_driver", .imp = "memory", .to = "memory" },
        .{ .from = "search_driver", .imp = "network", .to = "network" },
        .{ .from = "search_driver", .imp = "position_snapshot", .to = "position_snapshot" },
        .{ .from = "search_driver", .imp = "uci_output", .to = "uci_output" },
        .{ .from = "search_driver", .imp = "uci_wdl", .to = "uci_wdl" },
        .{ .from = "search_driver", .imp = "uci_move", .to = "uci_move" },
        .{ .from = "search_driver", .imp = "score", .to = "score" },
        .{ .from = "search_driver", .imp = "thread_vote", .to = "thread_vote" },
        .{ .from = "search_driver", .imp = "search_thread", .to = "search_thread" },
        .{ .from = "search_driver", .imp = "option", .to = "option" },
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

    const exe = b.addExecutable(.{
        .name = "stockfish",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/shell/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            // No .link_libcpp: the engine compiles zero C++ TUs (TU=0), so the C++
            // stdlib is dead weight.
        }),
    });

    // Thin libc binding shared by the files that need C stdio etc.
    // Imported as `libc` wherever a module says `const c = @import("libc")`.

    // Aligned/large-page allocator as a shared module: consumers call it directly.

    // Typed engine-graph views (ThreadPool/Worker/... offset structs), imported
    // by the modules that read the engine graph.

    // The bench positions (Defaults) and benchmark-command games (BenchmarkPositions)
    // are Zig arrays in benchmark.zig. The only external artifact is the NNUE net,
    // fetched into net/.
    // StateList: its own module so engine_graph.zig can hold it as a typed member.
    // NumaConfig: the numaContext member.
    // NumaReplicationContext: the `numa_context` member.
    // PositionStorage: owner of the `pos` member's 1032B block.
    // SharedHistories sizing: the `shared_histories` member, pure count logic.
    // sharedHists map container: the `sharedHists` member type, instantiated in
    // position.zig with the real SharedHistories.
    // network holder: the `network` member (LazyNumaReplicated<Network> shape +
    // replica-count shadow verifier).

    // The engine graph (engine_graph.zig) is compiled via the engine module: it
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
    // main.zig and its worker-construction helper reach the search-history helpers directly.
    exe.root_module.addImport("search_driver", mods.get("search_driver").?);
    exe.root_module.addImport("worker_histories", mods.get("worker_histories").?);
    // engine.zig single-sources default_eval_file_name from network.zig
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
    // engine_graph.zig imports search_manager by name; this standalone test builds it as a fresh
    // root module (outside the module-edge table), so the dependency must be added explicitly.
    graph_test.root_module.addImport("search_manager", mods.get("search_manager").?);
    const graph_test_step = b.step("test-graph", "Run the native-graph (cut) unit tests");
    addTestRun(b, graph_test_step, graph_test, cov_dir, &cov_idx);
    // sharedHists map container (std-only generic; tested with a mock
    // entry). board/position.zig instantiates it with the real SharedHistories.
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
    exe.root_module.addImport("network_holder", mods.get("network_holder").?);
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

    // The thin libc binding, imported as `const c = @import("libc")` by main.zig.
    exe.root_module.addImport("libc", mods.get("libc").?);

    // Direct callers of the aligned/large-page allocator.
    exe.root_module.addImport("memory", mods.get("memory").?);
    exe.root_module.addImport("worker_layout", mods.get("worker_layout").?);
    exe.root_module.addImport("position_types", mods.get("position_types").?);
    exe.root_module.addImport("clock", mods.get("clock").?);
    exe.root_module.addImport("uci_output", mods.get("uci_output").?);
    exe.root_module.addImport("uci_wdl", mods.get("uci_wdl").?);
    exe.root_module.addImport("score", mods.get("score").?);
    // network does not import position: its two Position field reads go through the
    // leaf worker_layout, which frees position -> network for the direct eval call below.

    // The engine compiles zero C++ TUs (TU=0), so these addCMacro calls are dead
    // (no C TU consumes them) but harmless.
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
    // The fetcher is a compiled Zig tool (tools/fetch_net.zig), not a `sh` script -- it
    // reads the net name from network.zig's authoritative constant, sha256-validates, and downloads
    // via std.http.Client. Built for the host (it runs at build time). argv[1] = the net-name source.
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

    // Pure-Zig parity harness: drives the built engine over UCI and diffs the
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

    // The bench signature is verified by the pure-Zig parity harness (tools/parity_harness.zig
    // `signature` check), not tests/signature.sh -- one cross-OS gate instead of a bash wrapper that
    // only ran on Linux. Defaults to the 2067208 arch/OS invariant; -Dsignature-ref overrides.
    const signature_reference = signature_ref orelse "2067208";
    const signature_cmd = addHarnessRun(b, harness_exe, install_step, &net_cmd.step, "signature", signature_reference, "check");

    const signature_step = b.step(
        "signature",
        "Verify the Zig-built Stockfish bench signature (== 2067208 by default; -Dsignature-ref to override) via the pure-Zig parity harness",
    );
    signature_step.dependOn(&signature_cmd.step);

    // Per-position search-fingerprint differential harness. Localizes a
    // bench-signature mismatch to a single position + drifted field.
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

    // Worktree-based upstream oracle gate: assert the default (Zig)
    // bench == the PRISTINE upstream Stockfish at UPSTREAM_BASE, built in a persistent
    // git worktree with ZERO vendored C++. It pins to the exact upstream sha we claim to
    // be at, and the oracle build is a cached no-op in steady state (upstream_oracle.sh
    // only rebuilds when BASE moves). Run standalone at sync time.
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

    // Full-output GOLDEN gate: the stripped bench info+bestmove text pinned against a
    // committed golden.
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

    // driver-golden: pins the search-manager driver + its emit callbacks
    // (multipv/wdl/ponder/currmove/no-moves) bit-exact.
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

    // Thread-runtime stress / liveness harness.
    // Hammers (ucinewgame -> setoption Threads -> go/stop) cycles across thread
    // counts + a construct/destroy churn, under a wall-clock watchdog. A liveness
    // gate (no hang / crash / lost search), not a determinism gate. Kept out
    // of the core `parity` aggregate (slower, wall-clock-timed); run explicitly
    // for any thread-runtime slice.
    const stress_cmd = addHarnessRun(b, harness_exe, install_step, &net_cmd.step, "stress", "-", "check");

    const stress_step = b.step(
        "parity-stress",
        "Thread-runtime stress/liveness: go/stop storms + construct/destroy churn",
    );
    stress_step.dependOn(&stress_cmd.step);

    // Memory-error / leak gate: Valgrind memcheck
    // over short multi-thread sessions, asserting no invalid access / bad free /
    // definite leak (uninit-value checking off -- NNUE SIMD makes it false-noisy).
    // The ASan/LSan-equivalent net for the Worker/large-page lifecycle. Out of the
    // core `parity` aggregate (slow).
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

    // Multi-thread search sanity. Multi-threaded
    // search is non-deterministic (Lazy SMP), so this is a tolerance gate, not a
    // bit-exact golden: at fixed depth on calm positions, Threads {2,4} must emit
    // a well-formed bestmove and a score of the same kind/sign within a generous
    // cp band of the deterministic single-thread reference. Catches a runtime that
    // runs but corrupts result aggregation. Out of the core `parity` aggregate
    // (non-deterministic, sleep-paced).
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

    // Leak gate for the searchmoves / rootMoves vector lifecycle:
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

    // Wall-clock time-management sanity: the ONLY gate over `go
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

    // Perft differential + golden gate: the ONLY gate over
    // do_move/undo_move + the legal movegen + the UCI move formatter (bench never runs
    // perft; search-modes only checks bestmoves), pinned against the committed golden.
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

    // Eval-trace differential + golden gate: pins the NNUE `eval` trace block
    // (buildNnueTrace + the network-ptr / accumulator-cache trace path) — bench covers the eval
    // value but not this formatting path.
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

    // UCI misc-command gate (coverage tail): d/flip Fen+Key+Checkers — the
    // Position fen/flip/zobrist/gives_check read paths no other gate touches.
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

    // Src-free / TU=0 structural gate: asserts the
    // shipped binary contains zero C++ TUs (no Stockfish:: / libc++ runtime symbols) and still
    // benches 2067208. A permanent invariant in the `parity` aggregate below, guarding
    // against any C++ TU being reintroduced into the default binary.
    const src_free_cmd = b.addSystemCommand(&.{
        "bash",
        b.pathFromRoot("tools/src_free.sh"),
        b.getInstallPath(.bin, "stockfish"),
    });
    src_free_cmd.step.dependOn(install_step);
    src_free_cmd.step.dependOn(&net_cmd.step);
    src_free_cmd.setCwd(b.path("net"));

    const src_free_step = b.step(
        "src-free",
        "src-free structural gate: zero C++ Stockfish/libc++ symbols in the shipped binary",
    );
    src_free_step.dependOn(&src_free_cmd.step);

    // Headless-engine structural gate: src/engine/ must import only engine/ modules,
    // never platform/ or shell/. The seams are injected one at a time, so the up-edge
    // count only ratchets down; the baseline is the currently-allowed maximum and the
    // gate fails if the real count exceeds it. Lower it as each seam is severed; at 0
    // the engine is a standalone search+eval library.
    const headless_baseline = "0";
    const headless_cmd = b.addSystemCommand(&.{
        "bash",
        b.pathFromRoot("tools/headless_lint.sh"),
    });
    headless_cmd.setEnvironmentVariable("HEADLESS_BASELINE", headless_baseline);
    const headless_step = b.step(
        "headless",
        "headless-engine structural gate: engine/ imports only engine/ (ratchets to 0)",
    );
    headless_step.dependOn(&headless_cmd.step);

    // Engine-only build/test target: compile the entire engine module graph in
    // isolation via src/engine/headless.zig, which imports every engine-zone module.
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

    // Aggregate unit-test step: run the in-tree `test {}` blocks of
    // every named module that has them, reusing the already-wired modules so their
    // imports resolve, plus the engine-graph tests. Reachability
    // caveat: tests in a path-imported sub-file run only when a module built here
    // imports it; a file with no test-reachable importer is not yet covered.
    const test_step = b.step("test", "Run the Zig unit tests");
    test_step.dependOn(graph_test_step);
    // The engine graph must also compile + test standalone (the headless invariant).
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
        mods.get("network_holder").?,
        mods.get("shared_histories").?,
        mods.get("search_thread").?,
        mods.get("thread_runtime").?,
    }) |unit_module| {
        const unit_test = b.addTest(.{ .root_module = unit_module });
        addTestRun(b, test_step, unit_test, cov_dir, &cov_idx);
    }
    // The NUMA surface: numa.zig (configString uses c_allocator -> needs libc) plus the
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

    // option.zig uses std.heap.c_allocator, so its standalone test build needs libc
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

    // Board property tests (perft to known node counts) -- needs libc
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

    // uci_parse property + fuzz tests (needs libc for c_allocator + the
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

    // Coverage-guided fuzz targets (std.testing.fuzz). Wired to its OWN
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
    const fuzz_step = b.step("fuzz", "Run the coverage-guided fuzz targets (add --fuzz to fuzz)");
    fuzz_step.dependOn(&b.addRunArtifact(fuzz_targets_test).step);

    // Standalone test artifacts for the tested sub-files that were
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

    // Coverage: leaves that need a few module imports for their `test {}` /
    // refAllDecls to compile. Each entry lists the file's DIRECT imports; the modules
    // in `mods` already carry their own transitive imports.
    const DepTest = struct { path: []const u8, deps: []const []const u8 };
    for ([_]DepTest{
        .{ .path = "src/platform/tablebase.zig", .deps = &.{"tb_source"} },
        .{ .path = "src/shell/uci_format.zig", .deps = &.{"uci_strings"} },
        .{ .path = "src/shell/engine/infofmt.zig", .deps = &.{"engine_util"} },
        .{ .path = "src/shell/engine/options.zig", .deps = &.{"option"} },
        .{ .path = "src/engine/board/position_snapshot.zig", .deps = &.{"position_types"} },
        .{ .path = "src/engine/eval/nnue_acc_layout.zig", .deps = &.{ "position_snapshot", "position_types" } },
        .{ .path = "src/engine/eval/nnue_acc_update.zig", .deps = &.{ "position_snapshot", "position_types", "nnue_feature", "nnue_acc_rowops", "nnue_ft", "nnue_refresh_cache" } },
        .{ .path = "src/engine/state/worker_histories.zig", .deps = &.{"shared_history_types"} },
        .{ .path = "src/engine/state/shared_history_types.zig", .deps = &.{"correction_bundle"} },
        .{ .path = "src/platform/thread_vote.zig", .deps = &.{"worker_layout"} },
        .{ .path = "src/shell/thread_construct.zig", .deps = &.{"worker_layout"} },
        .{ .path = "src/platform/runtime_hooks.zig", .deps = &.{ "worker_layout", "position_types" } },
        .{ .path = "src/engine/search/search_types.zig", .deps = &.{ "correction_bundle", "root_move", "worker_histories" } },
        .{ .path = "src/engine/board/position_query.zig", .deps = &.{ "board_core", "position_snapshot", "position_types" } },
        .{ .path = "src/engine/board/zobrist.zig", .deps = &.{ "bitboard", "board_core" } },
        .{ .path = "src/engine/board/uci_move.zig", .deps = &.{ "movegen", "position_snapshot", "position_types" } },
        .{ .path = "src/engine/search/movepick_snapshot.zig", .deps = &.{ "bitboard", "position_snapshot" } },
        .{ .path = "src/engine/search/movepick_history.zig", .deps = &.{"position_snapshot"} },
        .{ .path = "src/shell/benchmark.zig", .deps = &.{"libc"} },
        .{ .path = "src/engine/board/movegen.zig", .deps = &.{ "bitboard", "position_snapshot", "position_types" } },
        .{ .path = "src/engine/eval/network.zig", .deps = &.{ "page_alloc", "nnue_accumulator", "position_types" } },
        .{ .path = "src/engine/eval/nnue_weight_storage.zig", .deps = &.{"page_alloc"} },
        .{ .path = "src/engine/eval/nnue_inference.zig", .deps = &.{ "page_alloc", "nnue_accumulator", "position_types" } },
        .{ .path = "src/engine/board/legality.zig", .deps = &.{ "bitboard", "board_core", "movegen", "position_types" } },
        .{ .path = "src/engine/search/search_common.zig", .deps = &.{ "board_core", "worker_layout", "position_types", "worker_histories" } },
        .{ .path = "src/engine/search/movepick.zig", .deps = &.{ "bitboard", "movegen", "position_snapshot", "position_types" } },
        .{ .path = "src/engine/search/movepick_score.zig", .deps = &.{ "bitboard", "movegen", "position_snapshot", "position_types" } },
        .{ .path = "src/engine/board/position_lifecycle.zig", .deps = &.{ "fen_parse", "worker_layout", "legality", "move_do", "position_types" } },
        .{ .path = "src/engine/search/search_setup.zig", .deps = &.{ "worker_layout", "nnue_accumulator", "root_move", "search_ctx", "tt_types" } },
        .{ .path = "src/engine/board/fen_parse.zig", .deps = &.{ "board_core", "legality", "move_do", "position_types", "state_setup" } },
        .{ .path = "src/engine/search/search_ctx.zig", .deps = &.{ "worker_layout", "nnue_accumulator", "position_types", "root_move", "tt_types" } },
        .{ .path = "src/engine/search/search_control.zig", .deps = &.{ "time_source", "search_ctx", "search_types" } },
        .{ .path = "src/engine/board/repetition.zig", .deps = &.{ "bitboard", "board_core", "movegen", "position_types", "zobrist" } },
        .{ .path = "src/engine/board/state_setup.zig", .deps = &.{ "bitboard", "board_core", "legality", "position_types", "zobrist" } },
        .{ .path = "src/engine/state/worker_layout.zig", .deps = &.{ "limits_type", "position_types", "root_move", "state_list", "tt_types", "worker_histories" } },
        .{ .path = "src/engine/board/move_do.zig", .deps = &.{ "bitboard", "board_core", "legality", "position_types", "state_setup", "zobrist" } },
        .{ .path = "src/engine/eval/nnue_accumulator.zig", .deps = &.{ "nnue_acc_rowops", "nnue_feature", "nnue_ft", "nnue_refresh_cache", "position_snapshot", "position_types" } },
        .{ .path = "src/shell/engine/object.zig", .deps = &.{ "worker_layout", "misc", "network", "position_types", "state_list" } },
        .{ .path = "src/shell/engine/nnue.zig", .deps = &.{ "libc", "engine_object", "network", "option", "uci_output" } },
        .{ .path = "src/shell/engine/control.zig", .deps = &.{ "libc", "worker_layout", "engine_object", "tt", "thread", "option", "tablebase" } },
        .{ .path = "src/engine/search/shared_history.zig", .deps = &.{ "page_alloc", "position_types", "search_types", "shared_histories", "shared_histories_map", "shared_history_types", "worker_histories" } },
        .{ .path = "src/engine/search/history.zig", .deps = &.{ "board_core", "worker_layout", "position_types", "search", "search_common", "search_types", "shared_history", "worker_histories" } },
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

    // state_list.zig holds a typed StateInfo, so its standalone test needs the
    // position_types module (unlike the std-only files in the loop above).
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

    // thread_pool.zig is path-imported into the (untested) `thread` module,
    // so its Pool footprint + bound-slice lifecycle `test {}` blocks never ran in any
    // step. Build it as a standalone test artifact (spawns real SearchThreads -> link_libc)
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

    // worker_construct.zig is path-imported only into main.zig (the exe
    // root, not a test root), so its lone test -- the WorkerLayout offset-invariant check
    // guarding constructFull's field placement against a Zig field reorder -- never ran.
    // Wire it standalone so `zig build test` exercises that layout contract under RF + RS.
    const worker_construct_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/shell/worker_construct.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    worker_construct_test.root_module.addImport("worker_layout", mods.get("worker_layout").?);
    worker_construct_test.root_module.addImport("position", mods.get("position").?);
    worker_construct_test.root_module.addImport("search", mods.get("search").?);
    worker_construct_test.root_module.addImport("nnue_accumulator", mods.get("nnue_accumulator").?);
    worker_construct_test.root_module.addImport("network", mods.get("network").?);
    // worker_construct.zig calls the search-history helpers directly (search_driver's
    // public face) and reads a worker_histories offset; this fresh test module needs both.
    worker_construct_test.root_module.addImport("search_driver", mods.get("search_driver").?);
    worker_construct_test.root_module.addImport("worker_histories", mods.get("worker_histories").?);
    addTestRun(b, test_step, worker_construct_test, cov_dir, &cov_idx);

    const parity_step = b.step(
        "parity",
        "Run the current bench, UCI, and signature checks through the Zig build entry",
    );
    // The per-push `parity` aggregate: whole-engine regression is caught by `signature`
    // (== 2067208) and the GOLDEN gates (output-golden / perft / eval-trace / misc /
    // search-parity / search-modes), all in-repo. The authoritative
    // differential-vs-real-upstream check is `upstream-parity` (worktree oracle), run at
    // sync time where upstream is already fetched -- per push it would only re-assert the
    // same 2067208 the signature checks.
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
    // The interactive concurrency/timing gates run in the pure-Zig harness, so
    // they join the core aggregate.
    parity_step.dependOn(&mt_cmd.step);
    parity_step.dependOn(&stress_cmd.step);
    parity_step.dependOn(&time_cmd.step);
    // The src-free structural invariant is permanent, so it gates every push.
    parity_step.dependOn(&src_free_cmd.step);
    parity_step.dependOn(&headless_cmd.step);

    // Cross-OS aggregate: the platform-independent subset of `parity` -- bench,
    // the UCI handshake, the bench signature, and all six golden checks, every one driven by
    // the pure-Zig harness (no bash / no nm). This is what the Windows and macOS lanes run;
    // the Linux-only structural gates (src-free via `nm`, arch-determinism) stay in `parity`.
    // The bench signature is the same harness `signature_cmd` `parity` uses (2067208 invariant).
    const parity_portable_step = b.step(
        "parity-portable",
        "Cross-OS parity via the pure-Zig harness: signature + six golden gates + mt/stress/time",
    );
    parity_portable_step.dependOn(&bench_run.step);
    parity_portable_step.dependOn(&uci_run.step);
    parity_portable_step.dependOn(&signature_cmd.step);
    parity_portable_step.dependOn(&search_parity_cmd.step);
    parity_portable_step.dependOn(&search_modes_cmd.step);
    parity_portable_step.dependOn(&output_golden_cmd.step);
    parity_portable_step.dependOn(&perft_cmd.step);
    parity_portable_step.dependOn(&eval_cmd.step);
    parity_portable_step.dependOn(&misc_cmd.step);
    // The concurrency + timing gates -- the cross-OS payoff: these exercise the
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

// Coverage: wire a unit-test artifact into `step`. Without coverage this is the plain
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

// Native CPU -> best Stockfish ARCH tier in pure, unit-tested Zig (tools/native_arch.zig).
// Uses the host CPU features Zig's build graph already resolved via cpuid -- no
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

    // Non-x86 tiers. The pure-Zig @Vector NNUE lowers to NEON with no source
    // changes, so these just map the aarch64 CPU features to a Zig aarch64 target.
    // NEON is mandatory in AArch64 (baseline has it); dotprod (sdot) is added where
    // present. Runtime-validated under qemu-user in CI (bench == 2067208), matching
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
