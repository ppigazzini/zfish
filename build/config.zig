//! Resolve the build's inputs: every `-D` option, the ISA tier, the target and the
//! generated build_options module.
//!
//! This is the front half of `build()` -- option parsing and target resolution, before a
//! single module or step exists. It is one job and it answers one question ("what are we
//! building, for what, with which flags"), so it moves out whole and `build()` starts at the
//! module graph instead.
//!
//! Everything the rest of the build needs comes back in `Config`; nothing here reaches
//! forward into steps.

const std = @import("std");
const arch_cfg = @import("arch.zig");

const Macro = arch_cfg.Macro;
const ArchConfig = arch_cfg.ArchConfig;
const hasMacro = arch_cfg.hasMacro;
const resolveArch = arch_cfg.resolveArch;
const native_arch = arch_cfg.native_arch;

/// Resolve a repo-root-relative path to an absolute string. Read the build root from
/// whichever field the running std.Build exposes -- 0.16 `build_root: Cache.Directory`,
/// 0.17 `root: Cache.Path` -- so this compiles on both; the comptime @hasField branch
/// prunes the absent field. The whole build shares this one definition.
///
/// THIS FILE IS THE ONLY PLACE THAT MAY NAME EITHER FIELD. A `std.Build` field break is a
/// CONFIGURE error, so it takes down every step of the 0.17 lane at once -- exe, test,
/// fuzz, all tiers -- rather than the one step that touched it. Two sites bypassed these
/// shims and reached for `b.build_root` directly, and the lane was red on both from the
/// commit that added them. `zig build build-version-lint` now refuses a third.
pub fn repoPath(b: *std.Build, sub: []const u8) []const u8 {
    if (@hasField(std.Build, "build_root")) {
        return b.pathResolve(&.{ b.build_root.path orelse ".", sub });
    }
    // 0.17's root is a Cache.Path: a directory plus a sub-path within it, and the sub-path
    // is "" only when the build root IS the directory. Carry it rather than assume.
    return b.pathResolve(&.{ b.root.root_dir.path orelse ".", b.root.sub_path, sub });
}

/// Hand back the build root as an open directory, for the reads that want a handle rather
/// than a path. Same two fields, same comptime branch, same single owner -- `handle` is an
/// `Io.Dir` on both versions, so only the field name differs.
pub fn repoDir(b: *std.Build) std.Io.Dir {
    if (@hasField(std.Build, "build_root")) return b.build_root.handle;
    return b.root.root_dir.handle;
}

const TargetOs = enum { linux, windows, macos };

const GitInfo = struct {
    sha: ?[]const u8,
    date: ?[]const u8,
};

pub const Config = struct {
    os_tag: std.Target.Os.Tag,
    abi: std.Target.Abi,
    optimize: std.builtin.OptimizeMode,
    target: std.Build.ResolvedTarget,
    arch: ArchConfig,
    os_choice: TargetOs,
    git_info: GitInfo,
    stub_eval: bool,
    signature_ref: ?[]const u8,
    walk_args: ?[]const u8,
    build_options: *std.Build.Step.Options,
    build_options_module: *std.Build.Module,
};

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

pub fn runAndTrimOrNull(b: *std.Build, argv: []const []const u8) ?[]const u8 {
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

pub fn resolve(b: *std.Build) Config {
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Prioritize performance, safety, or binary size",
    ) orelse .ReleaseFast;
    const signature_ref = b.option(
        []const u8,
        "signature-ref",
        "Expected bench signature for the `signature` step; defaults to the 2497913 invariant",
    );
    const walk_args = b.option(
        []const u8,
        "walk-args",
        "Extra flags for the `upstream-walk` step, space separated (e.g. \"--positions 40 --depth 13\")",
    );
    const requested_arch = b.option(
        []const u8,
        "arch",
        "Stockfish ARCH value (e.g. x86-64-avx2), or 'native' to auto-detect the host CPU tier in Zig",
    ) orelse "native";
    const arch = resolveArch(b, requested_arch);
    // Target the owned runtimes: Linux (default), Windows, and macOS. The pure-Zig
    // engine is OS-portable behind a thin platform seam -- sync (thread_runtime.zig futex
    // seam), aligned/large-page allocation (memory.zig), the steady clock and CPU-affinity
    // string (main.zig). Windows uses the self-contained mingw (gnu) ABI so no MSVC/SDK is
    // needed; macOS uses its native ABI. The integer-exact NNUE eval is arch/OS-invariant,
    // so bench must be 2497913 on every (arch, os) tier -- the parity lanes assert it.
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
    // Spine isolation: swap the NNUE forward pass + eval blend for material alone, in BOTH
    // engines (tools/material_eval.sh drives it and patches the oracle to match). Changes the
    // bench node count by construction, so it is never part of a parity run -- the gate it
    // answers to is "do the two engines still search the SAME tree", not the anchor.
    const stub_eval = b.option(bool, "stub-eval", "Replace the NNUE eval with material count (spine isolation; NOT bit-exact, bench moves)") orelse false;
    // Two accumulator-architecture ablations, for measuring what the incremental path is
    // worth against a rebuild-per-evaluation design (the shape the Rust sibling port uses).
    // Both stay BIT-EXACT -- a refresh from the board and an incremental chain compute the
    // same accumulator, which is the invariant the whole design rests on -- so the node
    // count is unchanged and the two builds are the same work, which is the precondition
    // `tools/perf_counters.zig` enforces before it will report a ratio.
    const acc_refresh_only = b.option(bool, "acc-refresh-only", "Ablation: refresh the accumulator from the board every evaluation, never incrementally (bit-exact; measures what the incremental path buys)") orelse false;
    const no_threat_record = b.option(bool, "no-threat-record", "Ablation: compile out do_move's dirty-threat recording. Only sound WITH -Dacc-refresh-only, which never reads the records") orelse false;
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
    build_options.addOption(bool, "stub_eval", stub_eval);
    build_options.addOption(bool, "acc_refresh_only", acc_refresh_only);
    build_options.addOption(bool, "no_threat_record", no_threat_record);
    build_options.addOption(bool, "has_ndebug", true);
    const build_options_module = build_options.createModule();

    // Emit C instead of an object, for the correctness oracle in docs/10-tooling-ci.md. The C
    // backend lowers @Vector and friends differently from LLVM, so a construct that depends on
    // a representation Zig leaves target-defined diverges here and nowhere else. Requires
    // -Dlto=false (the C backend cannot use LLD).
    const emit_c = b.option(bool, "emit-c", "Emit C source instead of a binary (correctness oracle; needs -Dlto=false)") orelse false;
    const target = b.resolveTargetQuery(.{
        .ofmt = if (emit_c) .c else null,
        .cpu_arch = arch.cpu_arch,
        .cpu_model = .baseline,
        .cpu_features_add = arch.target_features,
        .os_tag = os_tag,
        .abi = abi,
    });

    return .{
        .os_tag = os_tag,
        .abi = abi,
        .optimize = optimize,
        .target = target,
        .arch = arch,
        .os_choice = os_choice,
        .git_info = git_info,
        .stub_eval = stub_eval,
        .signature_ref = signature_ref,
        .walk_args = walk_args,
        .build_options = build_options,
        .build_options_module = build_options_module,
    };
}
