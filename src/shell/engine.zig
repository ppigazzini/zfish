//! The shell engine facade: one flat `engine.` namespace over the `shell/engine/` leaves.
//!
//! This file is a pure *face*. It re-exports the state-owning leaves (shared_histories,
//! pending, info, control, nnue, infofmt, trace, perft, options) and the session driver
//! (engine/session.zig) so the shell's C-ABI layer reaches everything as `engine.X`. The
//! driver's command-handler call graph -- option registration + on-change dispatch,
//! position setup, `go`/perft, the thread/NUMA/SharedState reconfigure chain -- lives in
//! engine/session.zig; here we only present it. The layout-critical engine-graph leaves
//! are force-compiled below so their @sizeOf asserts are build-verified, not dead source.

const std = @import("std");

// The side shared-histories map is its own state-owning leaf.
const engine_shared_histories = @import("engine/shared_histories.zig");
pub const sharedHistoriesPtr = engine_shared_histories.sharedHistoriesPtr;
pub const sharedHistoriesClear = engine_shared_histories.sharedHistoriesClear;
pub const sharedHistoriesInsert = engine_shared_histories.sharedHistoriesInsert;
pub const sharedHistoriesAt = engine_shared_histories.sharedHistoriesAt;
pub const freeSharedHistories = engine_shared_histories.freeSharedHistories;

// The pending-state registry is its own state-owning leaf.
const engine_pending = @import("engine/pending.zig");
pub const PendingStateStorage = engine_pending.PendingStateStorage;
pub const ensurePendingStateStorage = engine_pending.ensurePendingStateStorage;
pub const pendingStatesAvailable = engine_pending.pendingStatesAvailable;
pub const handoffPendingStates = engine_pending.handoffPendingStates;
pub const releasePendingStateSlot = engine_pending.releasePendingStateSlot;

// The info-string builders live in a leaf; re-export for uci + core.
const engine_info = @import("engine/info.zig");
pub const numaConfigStringEngine = engine_info.numaConfigStringEngine;
pub const numaConfigInformationEngine = engine_info.numaConfigInformationEngine;
pub const threadBindingInformationEngine = engine_info.threadBindingInformationEngine;
pub const threadAllocationInformationEngine = engine_info.threadAllocationInformationEngine;
pub const threadBindingInformation = engine_info.threadBindingInformation;
pub const threadAllocationInformation = engine_info.threadAllocationInformation;

// Engine runtime control (TT resize/clear, tt-size/ponderhit/search-clear/
// hashfull + *Engine unwrappers) lives in the engine_control leaf now;
// re-export its surface so the C-ABI callers + staying code are unchanged.
const engine_control = @import("engine/control.zig");
pub const setTtSize = engine_control.setTtSize;
pub const setTtSizeEngine = engine_control.setTtSizeEngine;
pub const setPonderhit = engine_control.setPonderhit;
pub const setPonderhitEngine = engine_control.setPonderhitEngine;
pub const searchClear = engine_control.searchClear;
pub const searchClearEngine = engine_control.searchClearEngine;
pub const hashfullEngine = engine_control.hashfullEngine;
pub const stop = engine_control.stop;
pub const stopEngine = engine_control.stopEngine;
pub const waitForSearchFinishedEngine = engine_control.waitForSearchFinishedEngine;

// NNUE network lifecycle lives in the engine_nnue leaf; re-export the external surface
// (saveNetworkEngine is external port surface; verify/load funnel the go/perft/option-apply
// callers). printInfoString stays internal to the driver.
const engine_nnue = @import("engine_nnue");
pub const verifyNetwork = engine_nnue.verifyNetwork;
pub const loadNetworkEngine = engine_nnue.loadNetworkEngine;
pub const saveNetworkEngine = engine_nnue.saveNetworkEngine;

// NUMA/thread info formatters live in the engine_infofmt leaf; force-compiled here so
// the leaf's layout is build-verified (engine_info funnels through these).
const engine_infofmt = @import("engine_infofmt");
comptime {
    _ = engine_infofmt;
}

// String/format helpers + ByteView/CountPair live in the engine_util base leaf;
// ByteView/CountPair re-exported (external surface).
const engine_util = @import("engine_util");
pub const ByteView = engine_util.ByteView;
pub const CountPair = engine_util.CountPair;

// Eval-trace / visualize / snapshot cluster lives in the engine_trace leaf;
// the external entry points + pub trace types are re-exported.
const engine_trace = @import("engine_trace");
pub const PositionSummary = engine_trace.PositionSummary;
pub const TablebaseProbe = engine_trace.TablebaseProbe;
pub const EvalInput = engine_trace.EvalInput;
pub const EvalOutput = engine_trace.EvalOutput;
pub const TraceOutput = engine_trace.TraceOutput;
pub const EvalTraceInput = engine_trace.EvalTraceInput;
pub const NnueTraceInput = engine_trace.NnueTraceInput;
pub const traceEvalEngine = engine_trace.traceEvalEngine;
pub const visualizeEngine = engine_trace.visualizeEngine;
pub const fenEngine = engine_trace.fenEngine;
pub const accumulatorCachesCreate = engine_trace.accumulatorCachesCreate;

// Perft driver lives in the engine_perft leaf; re-exported for uci `go perft`.
const engine_perft = @import("engine_perft");
pub const perftEngine = engine_perft.perftEngine;

// The session driver: the command-handler call graph that runs one UCI session. Its
// SharedState instantiation + entry points are re-exported so the shell's C-ABI layer
// reaches them as engine.initBody / engine.goEngine / engine.SharedState unchanged.
const session = @import("engine/session.zig");
pub const SharedState = session.SharedState;
pub const initBody = session.initBody;
pub const optionOnChange = session.optionOnChange;
pub const setPosition = session.setPosition;
pub const setPositionEngine = session.setPositionEngine;
pub const applySetOptionEngine = session.applySetOptionEngine;
pub const goEngine = session.goEngine;
pub const setNumaConfigFromOptionEngine = session.setNumaConfigFromOptionEngine;
pub const resizeThreads = session.resizeThreads;
pub const resizeThreadsEngine = session.resizeThreadsEngine;
pub const flipEngine = session.flipEngine;

// Force-compile the self-contained engine-graph leaf nodes so their layout asserts
// (RootMove 552B, the search-manager dispatch, the SharedState bundle) are build-verified
// rather than dead source. These are the vtable-free, callback-free engine-graph nodes.
comptime {
    _ = @import("engine/graph.zig");
    _ = @import("search_manager");
    _ = @import("root_move");
}
