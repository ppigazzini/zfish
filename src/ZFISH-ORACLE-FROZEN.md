# This `src/` tree is a FROZEN differential oracle — not a live upstream mirror

The Stockfish → Zig runtime port is **complete**. The default `zig build` compiles
**zero** C++ translation units; the whole engine runtime lives in `zig_build/` +
`zig_src/` and is bit-exact to upstream at **bench 2067208**
(upstream HEAD `6088838` "Yeet psqt weights").

This `src/` tree no longer builds the shipping engine. It survives only as the
**behavioral oracle**: `zig build stockfish-legacy-cpp` compiles a small set of
first-party C++ owners
(`timeman` / `evaluate` / `movepick` / `tt` / `thread` / `tbprobe`) against the
Zig objects, and `zig build parity` benches it against the default Zig binary to
prove they still agree. Everything else here is Zig-owned at link time.

## What "frozen" means

- **It is NOT an upstream mirror.** Do not treat a difference between this tree
  and `official-stockfish/master` as upstream truth. The real upstream reference
  is a *separate pristine worktree* checked out and built by
  `zig_build/tools/upstream_oracle.sh` (and the sync toolkit under
  `zig_build/tools/upstream/`). Upstream drift is tracked by
  `zig_build/tools/upstream_sync.sh --check` and the `zfish_upstream_check`
  scheduled CI job — never by editing files here.
- **The net name is Zig-owned.** The `.nnue` this repo loads is pinned in
  `zig_build/eval/network.zig` (`default_eval_file_name`) and surfaced as the
  `EvalFile` UCI-option default in `zig_build/uci/option.zig`. `evaluate.h`'s
  `EvalFileDefaultName` macro is **overridden by that option** in both binaries;
  it is pinned to the same value only so this file stops advertising a stale net.
- **Only the oracle-compiled C++ remains as source.** The C++ files that are
  fully Zig-owned in both builds (their symbols come from Zig) carry no live
  source here; deleting them cannot change engine behavior and is verified by
  `zig build parity` staying at bench 2067208.

## If you are syncing upstream

Follow `zig_build/tools/upstream_sync.sh` and the log under
`zig_build/tools/upstream/`. Port changes land in the Zig runtime; this oracle is
re-synced deliberately as part of that human-gated process, not by drive-by edits.
