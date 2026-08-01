//! Fetch the runtime inputs the gates need: the NNUE net and the 3-man Syzygy set.
//!
//! Both are Zig tools rather than shell scripts, and both are build-time downloads with a
//! sha256 check, so they belong together and out of `build()`. The net one matters most: it
//! reads the net NAME from network.zig's authoritative constant, not from upstream's stale
//! src/evaluate.h -- after an upstream net bump those diverge and the wrong file lands, and
//! the binary then crashes on a net it cannot load.

const std = @import("std");

pub const Fetches = struct {
    /// Run step that guarantees the net is present; nearly every gate depends on it.
    net: *std.Build.Step.Run,
    /// Run step for the 3-man tablebases; only the tb-* gates depend on it.
    tb: *std.Build.Step.Run,
    net_step: *std.Build.Step,
    tb_step: *std.Build.Step,
};

pub fn register(b: *std.Build) Fetches {
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
    net_cmd.setCwd(b.path("resources"));
    // Always run (the tool is idempotent: it validates an existing net and no-ops), so a deleted or
    // corrupt net is re-fetched.
    net_cmd.has_side_effects = true;

    const net_step = b.step(
        "net",
        "Download the default NNUE net into resources/ for external-net Zig parity",
    );
    net_step.dependOn(&net_cmd.step);

    // Fetch the 3-man Syzygy tablebases (tools/fetch_tb.zig): download the ~26 KB 3-man set into
    // resources/syzygy/ for the Syzygy load/probe gates. The tables are NEVER committed (see .gitignore);
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
    tb_cmd.setCwd(b.path("resources"));
    tb_cmd.has_side_effects = true; // idempotent: skips files already present
    const tb_step = b.step(
        "tb",
        "Download the 3-man Syzygy tablebases into resources/syzygy/ (for the Syzygy gates)",
    );
    tb_step.dependOn(&tb_cmd.step);

    return .{ .net = net_cmd, .tb = tb_cmd, .net_step = net_step, .tb_step = tb_step };
}
