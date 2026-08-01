//! The build package: everything `build()` used to carry inline.
//!
//! build.zig imports THIS file and nothing else under build/, so the package can be
//! reorganised without touching the build script's import list -- the shape Ghostty's
//! build package uses (`const buildpkg = @import("src/build/main.zig")`), which is the
//! established answer to a build script that has outgrown one file.
//!
//! Why a package and not a longer build.zig: `build()` had reached 2085 lines, and this
//! repo gates god-files (`tools/loc_lint.sh`). Waiving the build script while forbidding
//! every other file is the same laundering the gate exists to prevent, one level up.
//!
//! TWO OF THESE FILES ARE PARSED AS TEXT by tools that gate the tree -- `arch_report.zig`
//! and `headless_lint.sh` read `modules.zig`, `docs_lint.sh` reads the step names. Those
//! parsers fail QUIETLY (an empty graph still exits 0), so each carries a vacuity guard and
//! each file says so in its own header. Re-run them after reshaping any literal here, and
//! read their COUNTS, not their exit codes.

pub const modules = @import("modules.zig");
pub const arch = @import("arch.zig");
pub const gates = @import("gates.zig");
pub const structural = @import("structural.zig");
pub const tests = @import("tests.zig");
pub const checks = @import("checks.zig");
pub const fetch = @import("fetch.zig");
pub const config = @import("config.zig");
