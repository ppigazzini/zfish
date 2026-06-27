#pragma once
// REPORT-11 E3 Step 0 — opaque forward declarations of the 9 frozen src/ types for the TU=0 cut.
//
// Once every remaining default-build dereference of these types (track with
// `python3 zig_build/tools/frozen_refs.py zig_compat/uci_bridge.cpp`) is routed to native or
// guarded legacy-only, the default compile of uci_bridge.cpp replaces its `#include "engine.h"` /
// "uci.h" / "thread.h" / "search.h" / "position.h" / ... with this header (Step 1, the supervised
// RED moment). Pointers/references to these incomplete types are then all that remains, which
// forward-declaration permits.
//
// The sizes mirror zig_build/.. graph_layout.zig (the native layout authority). At the cut the
// compile-time `static_assert(sizeof(T) == N)` cross-checks are guarded legacy-only; in the default
// build the equivalent guarantee comes from bench 2336177 + the H9 gate (any size drift moves the
// bench signature). While the legacy oracle still exists, oracle-parity proves these equal sizeof(T).
//
// NB this header is intentionally NOT included anywhere yet — it is the prepared Step 0 artifact.

#include <cstddef>

namespace Stockfish {

class Engine;
class UCIEngine;
class ThreadPool;
class Position;
class Thread;
struct StateInfo;

namespace Search {
class Worker;
class SearchManager;
struct SharedState;
}  // namespace Search

// Frozen-type sizes — MUST equal graph_layout.zig. (which / value / name there:)
inline constexpr std::size_t kWorkerSize        = 13882816;  // which=0  Search::Worker
inline constexpr std::size_t kThreadPoolSize    = 64;        // which=3  ThreadPool
inline constexpr std::size_t kUCIEngineSize     = 1696;      // which=5  UCIEngine
inline constexpr std::size_t kSearchManagerSize = 120;       // which=7  Search::SearchManager
inline constexpr std::size_t kPositionSize      = 1032;      // which=8  Position
inline constexpr std::size_t kStateInfoSize     = 192;       // which=9  StateInfo

}  // namespace Stockfish
