// Map the native CPU -> best Stockfish ARCH tier, in pure Zig, standing in for upstream's
// scripts/get_native_properties.sh shell-out. Keep it a pure function of std.Target.Cpu, so it is
// unit-testable against synthetic feature sets; build.zig calls detectArchFromCpu on the host CPU
// that Zig's build graph already resolved via cpuid -- no /proc/cpuinfo grep, no `sh`, works on
// every OS. Mirror get_native_properties.sh's set_arch_x86_64 table in tier order + predicates
// (strongest -> weakest, first match wins), and archConfigFor in build.zig maps each returned name
// to its -mcpu feature set.
const std = @import("std");

fn hasX86(cpu: std.Target.Cpu, f: std.Target.x86.Feature) bool {
    return std.Target.x86.featureSetHas(cpu.features, f);
}
fn hasAllX86(cpu: std.Target.Cpu, fs: []const std.Target.x86.Feature) bool {
    for (fs) |f| {
        if (!hasX86(cpu, f)) return false;
    }
    return true;
}

pub fn detectArchFromCpu(cpu: std.Target.Cpu) []const u8 {
    if (cpu.arch == .aarch64) {
        return if (std.Target.aarch64.featureSetHas(cpu.features, .dotprod)) "armv8-dotprod" else "armv8";
    }
    // Scope the owned native path to x86_64 (aarch64 handled above); send any other host to the
    // generic baseline (non-x86 CI lanes always pass an explicit -Darch, never `native`).
    if (cpu.arch != .x86_64) return "x86-64";

    if (hasAllX86(cpu, &.{ .avx512f, .avx512cd, .avx512vl, .avx512dq, .avx512bw, .avx512ifma, .avx512vbmi, .avx512vbmi2, .avx512vpopcntdq, .avx512bitalg, .avx512vnni, .vpclmulqdq, .gfni, .vaes })) return "x86-64-avx512icl";
    if (hasAllX86(cpu, &.{ .avx512vnni, .avx512dq, .avx512f, .avx512bw, .avx512vl })) return "x86-64-vnni512";
    if (hasAllX86(cpu, &.{ .avx512f, .avx512bw })) return "x86-64-avx512";
    if (hasX86(cpu, .avxvnni)) return "x86-64-avxvnni";
    // Exclude AMD Zen1/Zen2 from the bmi2 tier -- their BMI2 PEXT/PDEP is slow (as the script does).
    const znver12 = cpu.model == &std.Target.x86.cpu.znver1 or cpu.model == &std.Target.x86.cpu.znver2;
    if (!znver12 and hasX86(cpu, .bmi2)) return "x86-64-bmi2";
    if (hasX86(cpu, .avx2)) return "x86-64-avx2";
    if (hasAllX86(cpu, &.{ .sse4_1, .popcnt })) return "x86-64-sse41-popcnt";
    if (hasX86(cpu, .ssse3)) return "x86-64-ssse3";
    if (hasX86(cpu, .sse3) and hasX86(cpu, .popcnt)) return "x86-64-sse3-popcnt";
    return "x86-64";
}

fn x86Cpu(model: *const std.Target.Cpu.Model, feats: []const std.Target.x86.Feature) std.Target.Cpu {
    return .{ .arch = .x86_64, .model = model, .features = std.Target.x86.featureSet(feats) };
}

test "full AVX-512-ICL feature set -> avx512icl" {
    const cpu = x86Cpu(&std.Target.x86.cpu.x86_64, &.{ .avx512f, .avx512cd, .avx512vl, .avx512dq, .avx512bw, .avx512ifma, .avx512vbmi, .avx512vbmi2, .avx512vpopcntdq, .avx512bitalg, .avx512vnni, .vpclmulqdq, .gfni, .vaes });
    try std.testing.expectEqualStrings("x86-64-avx512icl", detectArchFromCpu(cpu));
}

test "AVX-512 VNNI subset -> vnni512 (not the full icl set)" {
    const cpu = x86Cpu(&std.Target.x86.cpu.x86_64, &.{ .avx512vnni, .avx512dq, .avx512f, .avx512bw, .avx512vl });
    try std.testing.expectEqualStrings("x86-64-vnni512", detectArchFromCpu(cpu));
}

test "plain AVX-512 F+BW -> avx512" {
    const cpu = x86Cpu(&std.Target.x86.cpu.x86_64, &.{ .avx512f, .avx512bw, .avx2, .bmi2 });
    try std.testing.expectEqualStrings("x86-64-avx512", detectArchFromCpu(cpu));
}

test "BMI2 on a non-Zen CPU -> bmi2 (before avx2)" {
    const cpu = x86Cpu(&std.Target.x86.cpu.haswell, &.{ .bmi2, .avx2, .sse4_1, .popcnt });
    try std.testing.expectEqualStrings("x86-64-bmi2", detectArchFromCpu(cpu));
}

test "Zen2 is excluded from the bmi2 tier -> falls to avx2" {
    const cpu = x86Cpu(&std.Target.x86.cpu.znver2, &.{ .bmi2, .avx2, .sse4_1, .popcnt });
    try std.testing.expectEqualStrings("x86-64-avx2", detectArchFromCpu(cpu));
}

test "SSE4.1 + POPCNT only -> sse41-popcnt" {
    const cpu = x86Cpu(&std.Target.x86.cpu.x86_64, &.{ .sse4_1, .popcnt, .sse3 });
    try std.testing.expectEqualStrings("x86-64-sse41-popcnt", detectArchFromCpu(cpu));
}

test "baseline x86_64 -> generic x86-64" {
    const cpu = x86Cpu(&std.Target.x86.cpu.x86_64, &.{});
    try std.testing.expectEqualStrings("x86-64", detectArchFromCpu(cpu));
}

test "aarch64 with dotprod -> armv8-dotprod" {
    const cpu = std.Target.Cpu{ .arch = .aarch64, .model = &std.Target.aarch64.cpu.generic, .features = std.Target.aarch64.featureSet(&.{.dotprod}) };
    try std.testing.expectEqualStrings("armv8-dotprod", detectArchFromCpu(cpu));
}
