# AGENTS.md

zfish is a pure-Zig port of Stockfish. The default `zig build` compiles zero C++ and the
binary is **bit-exact** to upstream: same nodes, same move.

Read [CONTRIBUTING.md](CONTRIBUTING.md) for the workflow and [docs/](docs/README.md) for how
the code works. This file is only what those don't say and an agent gets wrong.

## Setup

```sh
zig build                  # binary is `stockfish` (NOT `zfish`), at zig-out/bin/
zig build bench            # fetches the NNUE net into net/, runs from there
```

The net is a runtime input, not embedded. **Don't** run the binary from the repo root — it
SIGSEGVs on a null net. **Do** run it from `net/`, or use `zig build bench`.

## The anchor

`bench` prints a node count. It must equal `signature_reference` in `build.zig` — today
`2466447`, but **read it from build.zig, never from memory or a doc**: it moves on every
bench-moving upstream sync.

**A byte-changing edit is not done until a gate says so.**

```sh
zig build parity           # the aggregate — run before calling anything done
zig build signature        # just the anchor
```

## Goldens are photographs of us, not references

Nearly every gate records zfish's own output, so a golden pins a defect as faithfully as
correct behaviour — the gate then passes *because* the engine is wrong. This has happened:
`driver.golden` pinned a MultiPV tree upstream never searches.

**Don't** run `zig build <gate>-update` to make a red gate green. **Do** drive the upstream
oracle first and match its bytes:

```sh
bash tools/upstream_oracle.sh --verify    # --verify is NOT optional: it checks the built
                                          # binary against the commit's declared `Bench:`
```

## Measuring against upstream

Two oracles, different jobs. **Don't** take an instruction/cost ratio from
`upstream_oracle.sh` — it builds `COMP=gcc` while zfish is LLVM, so the ratio measures the
compiler. **Do** build the perf oracle with `zig c++` and match zfish's `-Darch`; the full
sequence is in [docs/09-tooling-ci.md](docs/09-tooling-ci.md#measuring-against-upstream-the-runnable-process).

nps cannot resolve anything under ~5% on this hardware — use `tools/perf_callgrind.sh` and
attribute with `tools/perf_fingerprint.py compare` (it sums across origin files and
reconciles; reading one profile line per side is a lie).

## Gotchas

- **Never pin a number a gate computes** (module/edge/hook counts, the anchor). Quote
  `zig build arch-report` / `hook-lint` / `signature` instead — such figures go stale in days.
- `zig fmt --check` is CI's first gate; a deletion often leaves a blank line it rejects.
- Valgrind must be arch-pinned (`-Darch=x86-64`); the default AVX-512 build SIGILLs under it.

## Commits

Conventional subject ≤72 chars, blank line, body wrapped at 80 with the evidence: the gate
output and exit code, not "should work". **Don't** `git push` — commit locally and stop
unless asked. **Don't** add co-author or generated-by trailers.
