const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .linux,
        .abi = .gnu,
    });

    const exe = b.addExecutable(.{
        .name = "stockfish",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = .ReleaseFast,
            .link_libc = true,
            .link_libcpp = true,
        }),
    });

    const compile_flags = &. {
        "-std=c++17",
        "-O3",
        "-funroll-loops",
        "-fno-exceptions",
        "-msse",
        "-msse2",
        "-Wno-date-time",
    };

    const stockfish_sources = &. {
        "benchmark.cpp",
        "bitboard.cpp",
        "evaluate.cpp",
        "main.cpp",
        "misc.cpp",
        "movegen.cpp",
        "movepick.cpp",
        "position.cpp",
        "search.cpp",
        "thread.cpp",
        "timeman.cpp",
        "tt.cpp",
        "uci.cpp",
        "ucioption.cpp",
        "tune.cpp",
        "syzygy/tbprobe.cpp",
        "nnue/nnue_accumulator.cpp",
        "nnue/nnue_misc.cpp",
        "nnue/network.cpp",
        "nnue/features/half_ka_v2_hm.cpp",
        "nnue/features/full_threats.cpp",
        "engine.cpp",
        "score.cpp",
        "memory.cpp",
    };

    exe.root_module.addIncludePath(b.path("src"));
    exe.root_module.addCMacro("NDEBUG", "1");
    exe.root_module.addCMacro("DIS_64BIT", "1");
    exe.root_module.addCMacro("USE_PTHREADS", "1");
    exe.root_module.addCMacro("USE_SSE2", "1");
    exe.root_module.addCMacro("NNUE_EMBEDDING_OFF", "1");
    exe.root_module.addCMacro("ARCH", "x86_64");
    exe.root_module.addCSourceFiles(.{
        .root = b.path("src"),
        .files = stockfish_sources,
        .flags = compile_flags,
    });
    exe.root_module.linkSystemLibrary("pthread", .{});
    exe.root_module.linkSystemLibrary("rt", .{});

    b.installArtifact(exe);

    const stockfish_step = b.step(
        "stockfish",
        "Build the imported Stockfish C++ engine for Linux x86_64",
    );
    stockfish_step.dependOn(b.getInstallStep());
}
