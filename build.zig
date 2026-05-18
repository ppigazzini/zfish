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

    const timeman_rewrites = b.createModule(.{
        .root_source_file = b.path("zig_build/time/timeman_rewrites.zig"),
        .target = target,
        .optimize = optimize,
    });
    const benchmark_source_files = b.addWriteFiles();
    _ = benchmark_source_files.addCopyFile(b.path("src/benchmark.cpp"), "benchmark.cpp");
    const benchmark_source_module = benchmark_source_files.add(
        "benchmark_source_data.zig",
        "pub const source = @embedFile(\"benchmark.cpp\");\n",
    );
    const benchmark_rewrites = b.createModule(.{
        .root_source_file = b.path("zig_build/bench/benchmark_rewrites.zig"),
        .target = target,
        .optimize = optimize,
    });
    benchmark_rewrites.addAnonymousImport("benchmark_source_data", .{
        .root_source_file = benchmark_source_module,
    });
    const misc_rewrites = b.createModule(.{
        .root_source_file = b.path("zig_build/support/misc_rewrites.zig"),
        .target = target,
        .optimize = optimize,
    });
    const tt_rewrites = b.createModule(.{
        .root_source_file = b.path("zig_build/support/tt_rewrites.zig"),
        .target = target,
        .optimize = optimize,
    });
    const option_rewrites = b.createModule(.{
        .root_source_file = b.path("zig_build/uci/option_rewrites.zig"),
        .target = target,
        .optimize = optimize,
    });
    const bitboard_rewrites = b.createModule(.{
        .root_source_file = b.path("zig_build/board/bitboard_rewrites.zig"),
        .target = target,
        .optimize = optimize,
    });
    const movegen_rewrites = b.createModule(.{
        .root_source_file = b.path("zig_build/board/movegen_rewrites.zig"),
        .target = target,
        .optimize = optimize,
    });
    const nnue_feature_rewrites = b.createModule(.{
        .root_source_file = b.path("zig_build/eval/nnue_feature_rewrites.zig"),
        .target = target,
        .optimize = optimize,
    });
    const uci_rewrites = b.createModule(.{
        .root_source_file = b.path("zig_build/uci/uci_rewrites.zig"),
        .target = target,
        .optimize = optimize,
    });
    const evaluate_rewrites = b.createModule(.{
        .root_source_file = b.path("zig_build/eval/evaluate_rewrites.zig"),
        .target = target,
        .optimize = optimize,
    });
    const nnue_misc_rewrites = b.createModule(.{
        .root_source_file = b.path("zig_build/eval/nnue_misc_rewrites.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("benchmark_rewrites", benchmark_rewrites);
    exe.root_module.addImport("bitboard_rewrites", bitboard_rewrites);
    exe.root_module.addImport("evaluate_rewrites", evaluate_rewrites);
    exe.root_module.addImport("misc_rewrites", misc_rewrites);
    exe.root_module.addImport("movegen_rewrites", movegen_rewrites);
    exe.root_module.addImport("nnue_feature_rewrites", nnue_feature_rewrites);
    exe.root_module.addImport("nnue_misc_rewrites", nnue_misc_rewrites);
    exe.root_module.addImport("option_rewrites", option_rewrites);
    exe.root_module.addImport("timeman_rewrites", timeman_rewrites);
    exe.root_module.addImport("tt_rewrites", tt_rewrites);
    exe.root_module.addImport("uci_rewrites", uci_rewrites);

    var compile_flags = std.ArrayList([]const u8).empty;
    compile_flags.appendSlice(b.allocator, &.{
        "-std=c++17",
        "-O3",
        "-funroll-loops",
        "-fno-exceptions",
        "-Wno-date-time",
    }) catch @panic("OOM");
    compile_flags.appendSlice(b.allocator, arch.flags) catch @panic("OOM");

    const stockfish_sources = &.{
        "movepick.cpp",
        "position.cpp",
        "search.cpp",
        "thread.cpp",
        "syzygy/tbprobe.cpp",
        "nnue/nnue_accumulator.cpp",
        "nnue/network.cpp",
        "engine.cpp",
    };

    const zig_compat_sources = &.{
        "benchmark_bridge.cpp",
        "bitboard_bridge.cpp",
        "main_bridge.cpp",
        "memory_bridge.cpp",
        "misc_bridge.cpp",
        "movegen_bridge.cpp",
        "nnue_features_bridge.cpp",
        "score_bridge.cpp",
        "timeman_bridge.cpp",
        "tt_bridge.cpp",
        "tune_bridge.cpp",
        "uci_bridge.cpp",
        "ucioption_bridge.cpp",
        "evaluate_bridge.cpp",
        "nnue_misc_bridge.cpp",
    };

    exe.root_module.addIncludePath(b.path("src"));
    exe.root_module.addCMacro("NDEBUG", "1");
    exe.root_module.addCMacro("DIS_64BIT", "1");
    exe.root_module.addCMacro("USE_PTHREADS", "1");
    exe.root_module.addCMacro("NNUE_EMBEDDING_OFF", "1");
    exe.root_module.addCMacro("ARCH", arch.name);
    applyMacros(exe.root_module, arch.macros);
    if (git_info.sha) |sha|
        exe.root_module.addCMacro("GIT_SHA", sha);
    if (git_info.date) |date|
        exe.root_module.addCMacro("GIT_DATE", date);
    exe.root_module.addCSourceFiles(.{
        .root = b.path("src"),
        .files = stockfish_sources,
        .flags = compile_flags.items,
    });
    exe.root_module.addCSourceFiles(.{
        .root = b.path("zig_compat"),
        .files = zig_compat_sources,
        .flags = compile_flags.items,
    });
    exe.root_module.linkSystemLibrary("pthread", .{});
    exe.root_module.linkSystemLibrary("rt", .{});

    b.installArtifact(exe);

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
    uci_run.expectStdOutMatch("id name Stockfish");
    uci_run.expectStdOutMatch("uciok");

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

    const parity_step = b.step(
        "parity",
        "Run the current bench, UCI, and signature checks through the Zig build entry",
    );
    parity_step.dependOn(&bench_run.step);
    parity_step.dependOn(&uci_run.step);
    parity_step.dependOn(&signature_cmd.step);

    const stockfish_step = b.step(
        "stockfish",
        "Build the imported Stockfish C++ engine for Linux x86_64",
    );
    stockfish_step.dependOn(install_step);
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
