# AGENTS.md

zfish is a pure-Zig port of Stockfish. The default `zig build` compiles zero C++ and the
binary is **bit-exact** to upstream: same nodes, same move.

**Read [docs/](docs/README.md) before changing code** — the architecture, each subsystem, the
tooling. [CONTRIBUTING.md](CONTRIBUTING.md) has the workflow. This file is only what an agent
gets wrong before it has read either.

**Docs are part of the change, not after it.** Each zone's page is a live claim about the code
you are touching — [docs/11-writing.md](docs/11-writing.md) maps every page to the source it
owns and marks which run hot. Change hot code, re-read its page and fix it in the SAME commit:
a doc is wrong from the moment the code lands, and every false claim ever found here got there
that way. `zig build docs-lint` catches a dead link, path or anchor; it cannot tell you a
sentence has become false. That part is yours.

## Setup

```sh
zig build                  # binary is `stockfish` (NOT `zfish`), at zig-out/bin/
zig build bench            # fetches the NNUE net into resources/, runs from there
```

The net is a runtime input, not embedded. **Don't** run the binary from the repo root — it
SIGSEGVs on a null net. **Do** run it from `resources/`, or use `zig build bench`.

## The anchor

`bench` prints a node count that must equal `signature_reference` in `build.zig`. **Read it
from build.zig, never from memory or a doc** — it moves on every bench-moving upstream sync.

**A byte-changing edit is not done until a gate says so.**

```sh
zig build parity           # the aggregate — run before calling anything done
zig build signature        # just the anchor
```

Cross-compile before committing anything under `src/platform/`, `std.Io`, or startup:
`zig build -Dos=windows` and `-Dos=macos`. CI has caught an eager `File.stdout()` here.

## Traps that cost real time

Pointers, not explanations — each is documented where it belongs.

| trap | where |
|---|---|
| A golden can pin a **defect**: `<gate>-update` on a red gate launders a bug. Drive the oracle, match its bytes. | [docs/09-tooling-ci.md](docs/09-tooling-ci.md) |
| Two oracles. A cost ratio off the `COMP=gcc` one measures **the compiler**, not zfish. | [docs/09-tooling-ci.md](docs/09-tooling-ci.md) |
| nps cannot resolve <5%; callgrind cost must be summed across origin files. | [docs/08-idiomatic-zig.md](docs/08-idiomatic-zig.md) |
| Comments are **imperative mood**; never pin a number a gate computes. | [docs/11-writing.md](docs/11-writing.md) |

## Commits

Conventional subject ≤72 chars, blank line, body wrapped at 80 carrying the evidence: gate
output and exit code, not "should work". **Don't** `git push` — commit locally and stop unless
asked. **Don't** add co-author or generated-by trailers.
