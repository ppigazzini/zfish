//! The parity package: every gate `tools/parity_harness.zig` used to carry inline.
//!
//! The harness imports THIS file and nothing else under parity/, so the package can be
//! reorganised without touching the root's import list -- the shape `build/main.zig` already
//! uses for the build script.
//!
//! Why a package and not one file: `tools/loc_lint.sh` gates every repo-owned .zig at 500
//! lines with a baseline of 0, and waiving the gate driver while the gate forbids every other
//! file is the laundering it exists to prevent. The layering is forced, not chosen: `run` and
//! `structured_diff` are leaves, the gates sit above them, and the ROOT imports the gates --
//! so a shared helper left in the root would make the two import each other.
//!
//! THE GOLDENS ARE THIS PACKAGE'S REGRESSION TEST. Nothing here decides its own correctness:
//! a builder that returns a different fingerprint fails its committed golden, and `zig build
//! parity` runs all of them. Reshape a builder and read the gate, not the diff.

pub const run = @import("run.zig");
pub const structured_diff = @import("structured_diff.zig");
pub const session = @import("session.zig");
pub const golden_shell = @import("golden_shell.zig");
pub const golden_search = @import("golden_search.zig");
pub const golden_tb = @import("golden_tb.zig");
pub const gate_runtime = @import("gate_runtime.zig");
pub const gate_state = @import("gate_state.zig");
pub const gate_malformed = @import("gate_malformed.zig");
