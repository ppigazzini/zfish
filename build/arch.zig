//! Own the ISA tier: what each `-Darch=` name means, and how it reaches a module.
//!
//! The `Macro`/`ArchConfig` types, the native-CPU resolver and `archConfigFor` -- 364 lines
//! of pure per-tier configuration that build.zig carried inline. Nothing here touches a step
//! or a golden: it answers only "which flags, macros and CPU features does this tier mean",
//! which is why it is one cohesive file rather than a spread through `build()`.
//!
//! Shape follows Ghostty's build package (a thin build.zig delegating to cohesive units,
//! re-exported through build/main.zig so build.zig keeps ONE build-package import). It sits
//! at build/ rather than src/build/ because src/ here is the SHIPPED program and its three
//! zones are themselves gated -- build tooling under src/ would muddy that.

const std = @import("std");

pub const Macro = struct {
    name: []const u8,
    value: []const u8,
};
pub const ArchConfig = struct {
    name: []const u8,
    flags: []const []const u8,
    macros: []const Macro,
    target_features: std.Target.Cpu.Feature.Set,
    // Default the owned runtime to x86_64; non-x86 tiers set this so the pure
    // Zig @Vector NNUE cross-compiles to that ISA (LLVM lowers to NEON/etc).
    cpu_arch: std.Target.Cpu.Arch = .x86_64,
};
pub fn applyMacros(module: *std.Build.Module, macros: []const Macro) void {
    for (macros) |macro|
        module.addCMacro(macro.name, macro.value);
}

// Map the native CPU -> best Stockfish ARCH tier in pure, unit-tested Zig (tools/native_arch.zig).
// Use the host CPU features Zig's build graph already resolved via cpuid -- no
// /proc/cpuinfo grep, no `sh`.
pub const native_arch = @import("../tools/native_arch.zig");

pub fn resolveArch(b: *std.Build, requested_arch: []const u8) ArchConfig {
    const arch_name = if (std.mem.eql(u8, requested_arch, "native"))
        native_arch.detectArchFromCpu(b.graph.host.result.cpu)
    else
        requested_arch;

    return archConfigFor(arch_name);
}
pub fn archConfigFor(arch_name: []const u8) ArchConfig {
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
    // present. Runtime-validated under qemu-user in CI (bench == 2508687), matching
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
pub fn hasMacro(macros: []const Macro, name: []const u8) bool {
    for (macros) |macro| {
        if (std.mem.eql(u8, macro.name, name)) {
            return true;
        }
    }

    return false;
}
