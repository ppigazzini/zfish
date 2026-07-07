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

    // Module graph as data (M17.1): each engine module is a uniform {name, path}
    // spec, and import edges are a table -- replacing 41 createModule blocks + the
    // 142 hand-written addImport lines.
    const ModuleSpec = struct { name: []const u8, path: []const u8 };
    const module_specs = [_]ModuleSpec{
        .{ .name = "libc", .path = "src/libc.zig" },
        .{ .name = "memory", .path = "src/memory.zig" },
        .{ .name = "tablebase", .path = "src/support/tablebase.zig" },
        .{ .name = "clock", .path = "src/support/clock.zig" },
        .{ .name = "uci_output", .path = "src/support/uci_output.zig" },
        .{ .name = "uci_wdl", .path = "src/support/uci_wdl.zig" },
        .{ .name = "score", .path = "src/score.zig" },
        .{ .name = "thread_vote", .path = "src/support/thread_vote.zig" },
        .{ .name = "thread_runtime", .path = "src/support/thread_runtime.zig" },
        .{ .name = "native_thread", .path = "src/support/native_thread.zig" },
        .{ .name = "numa", .path = "src/support/numa.zig" },
        .{ .name = "graph_layout", .path = "src/graph_layout.zig" },
        .{ .name = "native_engine", .path = "src/native_engine.zig" },
        .{ .name = "timeman", .path = "src/time/timeman.zig" },
        .{ .name = "benchmark", .path = "src/bench/benchmark.zig" },
        .{ .name = "misc", .path = "src/support/misc.zig" },
        .{ .name = "engine", .path = "src/support/engine.zig" },
        .{ .name = "uci_move", .path = "src/support/uci_move.zig" },
        .{ .name = "movepick", .path = "src/support/movepick.zig" },
        .{ .name = "search", .path = "src/support/search.zig" },
        .{ .name = "thread", .path = "src/support/thread.zig" },
        .{ .name = "tt", .path = "src/support/tt.zig" },
        .{ .name = "option", .path = "src/uci/option.zig" },
        .{ .name = "bitboard", .path = "src/board/bitboard.zig" },
        .{ .name = "position", .path = "src/board/position.zig" },
        .{ .name = "position_snapshot", .path = "src/board/position_snapshot.zig" },
        .{ .name = "native_hooks", .path = "src/support/native_hooks.zig" },
        .{ .name = "movegen", .path = "src/board/movegen.zig" },
        .{ .name = "nnue_feature", .path = "src/eval/nnue_feature.zig" },
        .{ .name = "uci", .path = "src/uci/uci.zig" },
        .{ .name = "evaluate", .path = "src/eval/evaluate.zig" },
        .{ .name = "nnue_accumulator", .path = "src/eval/nnue_accumulator.zig" },
        .{ .name = "network", .path = "src/eval/network.zig" },
        .{ .name = "nnue_misc", .path = "src/eval/nnue_misc.zig" },
        .{ .name = "state_list", .path = "src/board/state_list.zig" },
        .{ .name = "numa_config", .path = "src/support/numa_config.zig" },
        .{ .name = "numa_replication", .path = "src/support/numa_replication.zig" },
        .{ .name = "position_storage", .path = "src/board/position_storage.zig" },
        .{ .name = "shared_histories", .path = "src/support/shared_histories.zig" },
        .{ .name = "shared_histories_map", .path = "src/support/shared_histories_map.zig" },
        .{ .name = "network_holder", .path = "src/support/network_holder.zig" },
        .{ .name = "worker_histories", .path = "src/board/worker_histories.zig" },
        .{ .name = "position_types", .path = "src/board/position_types.zig" },
        .{ .name = "fen", .path = "src/board/fen.zig" },
        .{ .name = "board_core", .path = "src/board/board_core.zig" },
        .{ .name = "legality", .path = "src/board/legality.zig" },
        .{ .name = "zobrist", .path = "src/board/zobrist.zig" },
        .{ .name = "repetition", .path = "src/board/repetition.zig" },
        .{ .name = "position_query", .path = "src/board/position_query.zig" },
        .{ .name = "state_setup", .path = "src/board/state_setup.zig" },
        .{ .name = "move_do", .path = "src/board/move_do.zig" },
        .{ .name = "fen_parse", .path = "src/board/fen_parse.zig" },
        .{ .name = "search_types", .path = "src/board/search_types.zig" },
        .{ .name = "search_driver", .path = "src/board/search_driver.zig" },
        .{ .name = "shared_history", .path = "src/board/shared_history.zig" },
        .{ .name = "search_common", .path = "src/board/search_common.zig" },
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
        .{ .from = "numa_replication", .imp = "numa_config", .to = "numa_config" },
        .{ .from = "position", .imp = "nnue_accumulator", .to = "nnue_accumulator" },
        .{ .from = "position", .imp = "evaluate", .to = "evaluate" },
        .{ .from = "position", .imp = "shared_histories", .to = "shared_histories" },
        .{ .from = "position", .imp = "shared_histories_map", .to = "shared_histories_map" },
        .{ .from = "position", .imp = "worker_histories", .to = "worker_histories" },
        .{ .from = "graph_layout", .imp = "worker_histories", .to = "worker_histories" },
        .{ .from = "position", .imp = "position_types", .to = "position_types" },
        .{ .from = "graph_layout", .imp = "position_types", .to = "position_types" },
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
        .{ .from = "search_driver", .imp = "clock", .to = "clock" },
        .{ .from = "search_driver", .imp = "graph_layout", .to = "graph_layout" },
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
        .{ .from = "search_driver", .imp = "native_thread", .to = "native_thread" },
        .{ .from = "search_driver", .imp = "option", .to = "option" },
        .{ .from = "search_driver", .imp = "timeman", .to = "timeman" },
        .{ .from = "search_driver", .imp = "worker_histories", .to = "worker_histories" },
        .{ .from = "search_driver", .imp = "position_types", .to = "position_types" },
        .{ .from = "search_driver", .imp = "search_types", .to = "search_types" },
        .{ .from = "search_driver", .imp = "fen", .to = "fen" },
        .{ .from = "search_driver", .imp = "board_core", .to = "board_core" },
        .{ .from = "search_driver", .imp = "legality", .to = "legality" },
        .{ .from = "search_driver", .imp = "zobrist", .to = "zobrist" },
        .{ .from = "search_driver", .imp = "repetition", .to = "repetition" },
        .{ .from = "search_driver", .imp = "position_query", .to = "position_query" },
        .{ .from = "search_driver", .imp = "state_setup", .to = "state_setup" },
        .{ .from = "search_driver", .imp = "move_do", .to = "move_do" },
        .{ .from = "search_driver", .imp = "fen_parse", .to = "fen_parse" },
        .{ .from = "search_driver", .imp = "shared_history", .to = "shared_history" },
        .{ .from = "search_driver", .imp = "search_common", .to = "search_common" },
        .{ .from = "search_common", .imp = "graph_layout", .to = "graph_layout" },
        .{ .from = "search_common", .imp = "worker_histories", .to = "worker_histories" },
        .{ .from = "search_common", .imp = "position_types", .to = "position_types" },
        .{ .from = "search_common", .imp = "board_core", .to = "board_core" },
        .{ .from = "shared_history", .imp = "memory", .to = "memory" },
        .{ .from = "shared_history", .imp = "shared_histories", .to = "shared_histories" },
        .{ .from = "shared_history", .imp = "shared_histories_map", .to = "shared_histories_map" },
        .{ .from = "shared_history", .imp = "worker_histories", .to = "worker_histories" },
        .{ .from = "shared_history", .imp = "search_types", .to = "search_types" },
        .{ .from = "shared_history", .imp = "position_types", .to = "position_types" },
        .{ .from = "fen_parse", .imp = "board_core", .to = "board_core" },
        .{ .from = "fen_parse", .imp = "move_do", .to = "move_do" },
        .{ .from = "fen_parse", .imp = "state_setup", .to = "state_setup" },
        .{ .from = "fen_parse", .imp = "legality", .to = "legality" },
        .{ .from = "fen_parse", .imp = "position_types", .to = "position_types" },
        .{ .from = "engine", .imp = "position", .to = "position" },
        .{ .from = "engine", .imp = "position_snapshot", .to = "position_snapshot" },
        .{ .from = "position", .imp = "position_snapshot", .to = "position_snapshot" },
        .{ .from = "thread", .imp = "native_hooks", .to = "native_hooks" },
        .{ .from = "engine", .imp = "native_hooks", .to = "native_hooks" },
        .{ .from = "native_thread", .imp = "native_hooks", .to = "native_hooks" },
        .{ .from = "engine", .imp = "uci_move", .to = "uci_move" },
        .{ .from = "engine", .imp = "misc", .to = "misc" },
        .{ .from = "engine", .imp = "thread", .to = "thread" },
        .{ .from = "native_engine", .imp = "graph_layout", .to = "graph_layout" },
        .{ .from = "native_engine", .imp = "misc", .to = "misc" },
        .{ .from = "native_engine", .imp = "state_list", .to = "state_list" },
        .{ .from = "native_engine", .imp = "network", .to = "network" },
        .{ .from = "engine", .imp = "native_engine", .to = "native_engine" },
        .{ .from = "engine", .imp = "numa", .to = "numa" },
        .{ .from = "thread", .imp = "numa", .to = "numa" },
        .{ .from = "engine", .imp = "tt", .to = "tt" },
        .{ .from = "engine", .imp = "state_list", .to = "state_list" },
        .{ .from = "engine", .imp = "numa_config", .to = "numa_config" },
        .{ .from = "engine", .imp = "numa_replication", .to = "numa_replication" },
        .{ .from = "engine", .imp = "position_storage", .to = "position_storage" },
        .{ .from = "engine", .imp = "network", .to = "network" },
        .{ .from = "engine", .imp = "nnue_accumulator", .to = "nnue_accumulator" },
        .{ .from = "engine", .imp = "evaluate", .to = "evaluate" },
        .{ .from = "engine", .imp = "nnue_misc", .to = "nnue_misc" },
        .{ .from = "uci_move", .imp = "position_snapshot", .to = "position_snapshot" },
        .{ .from = "movepick", .imp = "position_snapshot", .to = "position_snapshot" },
        .{ .from = "movepick", .imp = "bitboard", .to = "bitboard" },
        .{ .from = "movepick", .imp = "movegen", .to = "movegen" },
        .{ .from = "movegen", .imp = "position_snapshot", .to = "position_snapshot" },
        .{ .from = "movegen", .imp = "bitboard", .to = "bitboard" },
        .{ .from = "nnue_accumulator", .imp = "position_snapshot", .to = "position_snapshot" },
        .{ .from = "nnue_accumulator", .imp = "nnue_feature", .to = "nnue_feature" },
        .{ .from = "position", .imp = "bitboard", .to = "bitboard" },
        .{ .from = "position", .imp = "movegen", .to = "movegen" },
        .{ .from = "engine", .imp = "movegen", .to = "movegen" },
        .{ .from = "position", .imp = "tt", .to = "tt" },
        .{ .from = "position", .imp = "movepick", .to = "movepick" },
        .{ .from = "position", .imp = "search", .to = "search" },
        .{ .from = "thread", .imp = "position_snapshot", .to = "position_snapshot" },
        .{ .from = "thread", .imp = "position", .to = "position" },
        .{ .from = "thread", .imp = "uci_move", .to = "uci_move" },
        .{ .from = "uci", .imp = "benchmark", .to = "benchmark" },
        .{ .from = "uci", .imp = "misc", .to = "misc" },
        .{ .from = "uci", .imp = "engine", .to = "engine" },
        .{ .from = "uci", .imp = "option", .to = "option" },
        .{ .from = "benchmark", .imp = "libc", .to = "libc" },
        .{ .from = "uci", .imp = "libc", .to = "libc" },
        .{ .from = "misc", .imp = "libc", .to = "libc" },
        .{ .from = "engine", .imp = "libc", .to = "libc" },
        .{ .from = "thread", .imp = "libc", .to = "libc" },
        .{ .from = "uci_output", .imp = "libc", .to = "libc" },
        .{ .from = "engine", .imp = "uci_output", .to = "uci_output" },
        .{ .from = "uci", .imp = "uci_wdl", .to = "uci_wdl" },
        .{ .from = "uci", .imp = "uci_output", .to = "uci_output" },
        .{ .from = "uci", .imp = "native_engine", .to = "native_engine" },
        .{ .from = "uci", .imp = "graph_layout", .to = "graph_layout" },
        .{ .from = "uci", .imp = "clock", .to = "clock" },
        .{ .from = "engine", .imp = "uci_wdl", .to = "uci_wdl" },
        .{ .from = "position", .imp = "uci_wdl", .to = "uci_wdl" },
        .{ .from = "tt", .imp = "memory", .to = "memory" },
        .{ .from = "position", .imp = "memory", .to = "memory" },
        .{ .from = "position", .imp = "option", .to = "option" },
        .{ .from = "position", .imp = "timeman", .to = "timeman" },
        .{ .from = "position", .imp = "uci_move", .to = "uci_move" },
        .{ .from = "position", .imp = "uci_output", .to = "uci_output" },
        .{ .from = "position", .imp = "score", .to = "score" },
        .{ .from = "position", .imp = "thread_vote", .to = "thread_vote" },
        .{ .from = "thread", .imp = "thread_vote", .to = "thread_vote" },
        .{ .from = "thread_vote", .imp = "graph_layout", .to = "graph_layout" },
        .{ .from = "native_thread", .imp = "graph_layout", .to = "graph_layout" },
        .{ .from = "native_thread", .imp = "thread_runtime", .to = "thread_runtime" },
        .{ .from = "thread", .imp = "native_thread", .to = "native_thread" },
        .{ .from = "thread", .imp = "thread_runtime", .to = "thread_runtime" },
        .{ .from = "position", .imp = "native_thread", .to = "native_thread" },
        .{ .from = "misc", .imp = "memory", .to = "memory" },
        .{ .from = "tt", .imp = "graph_layout", .to = "graph_layout" },
        .{ .from = "tt", .imp = "thread", .to = "thread" },
        .{ .from = "thread", .imp = "graph_layout", .to = "graph_layout" },
        .{ .from = "engine", .imp = "graph_layout", .to = "graph_layout" },
        .{ .from = "thread", .imp = "movegen", .to = "movegen" },
        .{ .from = "uci_move", .imp = "movegen", .to = "movegen" },
        .{ .from = "thread", .imp = "tablebase", .to = "tablebase" },
        .{ .from = "thread", .imp = "option", .to = "option" },
        .{ .from = "thread", .imp = "state_list", .to = "state_list" },
        .{ .from = "engine", .imp = "tablebase", .to = "tablebase" },
        .{ .from = "engine", .imp = "option", .to = "option" },
        .{ .from = "position", .imp = "clock", .to = "clock" },
        .{ .from = "position", .imp = "graph_layout", .to = "graph_layout" },
        .{ .from = "network", .imp = "libc", .to = "libc" },
        .{ .from = "network", .imp = "memory", .to = "memory" },
        .{ .from = "network", .imp = "graph_layout", .to = "graph_layout" },
        .{ .from = "network", .imp = "nnue_accumulator", .to = "nnue_accumulator" },
        .{ .from = "position", .imp = "network", .to = "network" },
        .{ .from = "nnue_misc", .imp = "libc", .to = "libc" },
        .{ .from = "evaluate", .imp = "libc", .to = "libc" },
    };
    for (module_edges) |e| mods.get(e.from).?.addImport(e.imp, mods.get(e.to).?);
    mods.get("misc").?.addImport("build_options", build_options_module);

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

    // Aligned/large-page allocator as a shared module (REPORT-16 M16.5): consumers call it
    // directly instead of round-tripping through main.zig's C-ABI `zfish_aligned_large_pages_*`
    // exports (dead scaffolding now the C++ oracle is retired).

    // M16.2b/M16.5: typed engine-graph views (ThreadPool/Worker/... offset structs), imported
    // by the modules that used to reach the graph through main.zig C-ABI glue.

    // The bench positions (Defaults) and benchmark-command games (BenchmarkPositions)
    // are native Zig arrays in benchmark.zig, so the build depends on nothing from the
    // old src/ tree. The only external artifact is the NNUE net, fetched into net/.
    // Native StateList (the post-src/ `states` deque replacement, native-graph cut);
    // its own module so engine_graph.zig can hold it as a typed member.
    // Native NumaConfig (the post-src/ numaContext member, native-graph cut).
    // Native NumaReplicationContext (the `numa_context` member; B2 switch).
    // Native PositionStorage (post-src/ owner of the `pos` member's 1032B block).
    // Native SharedHistories sizing (the `shared_histories` member, pure count logic).
    // Native sharedHists map container (the `sharedHists` member type), instantiated in
    // position.zig with the real SharedHistories.
    // Native network holder (the `network` member: LazyNumaReplicated<Network> shape +
    // replica-count shadow verifier).

    // For the native engine-graph scaffolding (engine_graph.zig) compiled via the
    // engine module: it binds the native ThreadPool and TranspositionTable.
    exe.root_module.addImport("native_hooks", mods.get("native_hooks").?);
    exe.root_module.addImport("native_engine", mods.get("native_engine").?);
    // engine.zig single-sources default_eval_file_name from network.zig
    // (network has no engine dep, so this edge is acyclic).

    // Native-graph cut: run the EngineGraph + member-module unit tests (construction,
    // lifetime, SharedState binding) with their module deps. `zig build test-graph`.
    const graph_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/support/engine_graph.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    graph_test.root_module.addImport("thread", mods.get("thread").?);
    graph_test.root_module.addImport("tt", mods.get("tt").?);
    graph_test.root_module.addImport("state_list", mods.get("state_list").?);
    graph_test.root_module.addImport("numa_config", mods.get("numa_config").?);
    graph_test.root_module.addImport("numa_replication", mods.get("numa_replication").?);
    graph_test.root_module.addImport("position_storage", mods.get("position_storage").?);
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
    numa_repl_test.root_module.addImport("numa_config", mods.get("numa_config").?);
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
    exe.root_module.addImport("numa_config", mods.get("numa_config").?);
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

    // REPORT-16: the thin libc binding, for every module that replaced an @cImport with
    // `const c = @import("libc")` (main + the 8 files below; misc keeps its own @cImport
    // until its compiler-macro reads are ported to Zig build info).
    exe.root_module.addImport("libc", mods.get("libc").?);

    // M16.5: direct callers of the aligned/large-page allocator.
    exe.root_module.addImport("memory", mods.get("memory").?);
    exe.root_module.addImport("graph_layout", mods.get("graph_layout").?);
    exe.root_module.addImport("clock", mods.get("clock").?);
    exe.root_module.addImport("uci_output", mods.get("uci_output").?);
    exe.root_module.addImport("uci_wdl", mods.get("uci_wdl").?);
    exe.root_module.addImport("score", mods.get("score").?);
    // network no longer imports position (broke the network->position cycle, M16.7):
    // its two Position field reads go through the leaf graph_layout. That frees
    // position -> network for the direct eval call below.

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
        mods.get("position_storage").?,
        mods.get("state_list").?,
        mods.get("numa_config").?,
        mods.get("tt").?,
        mods.get("network_holder").?,
        mods.get("shared_histories").?,
        mods.get("native_thread").?,
        mods.get("thread_runtime").?,
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

    // M17.0c: standalone test artifacts for the tested sub-files that were
    // path-imported into larger modules (so their `test {}` blocks never ran in
    // the aggregate). These depend only on std (+ libc for c_allocator) or on a
    // sibling path import, so they build in isolation.
    inline for (.{
        "src/board/position_types.zig",
        "src/board/fen.zig",
        "src/board/board_core.zig",
        "src/board/state_list.zig",
        "src/support/root_move.zig",
        "src/support/search_manager.zig",
        "src/support/shared_state.zig",
        "src/eval/nnue_parse.zig",
        "src/eval/nnue_hash.zig",
    }) |src_path| {
        const file_test = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(src_path),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }),
        });
        test_step.dependOn(&b.addRunArtifact(file_test).step);
    }

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
