# Contributing to zfish

zfish is a [Zig][zig] port of [Stockfish][stockfish] that stays **bit-exact** to
upstream. This guide covers the essentials.

## Building

See the [README](README.md#build): install **Zig 0.16.0** and run `zig build`
(then `zig build net` for the NNUE network). There are no other dependencies.

## The golden rule: preserve the bench signature

The shipped engine must reproduce upstream Stockfish's exact `bench` node count
for the current sync. Any change that touches engine behavior must hold
that signature, proven by the gates:

```
zig build signature
zig build parity          # signature + in-repo golden gates
zig build upstream-parity # differential vs pristine upstream (worktree oracle)
zig build test            # Zig unit tests
```

A byte-changing engine edit that cannot show a green `signature`/`parity` is not
complete. Behavior drift in UCI, bench, NNUE, or Syzygy is not accepted. An
architecture change must hold the signature on **every** tier — the x86 tiers and
aarch64 (see the CI parity workflow).

## What counts as a change

- **Upstream sync** — port a real upstream change (a bench-mover or NNUE-arch
  change) and land bit-exact at that commit's `Bench:`. See
  `tools/upstream/`.
- **Zig debt** — improve reviewability or maintainability with the bench signature
  unchanged.
- **CI / tooling** — strengthen a gate without weakening an existing one.

## Code style

Zig code is formatted with `zig fmt`. The repo vendors no Stockfish C++; parity
against upstream is a pristine git-worktree build (`zig build upstream-parity`).

The Python scripts under `tools/` are linted and formatted by ruff and
type-checked by ty, configured in `pyproject.toml`. `pre-commit install` wires
all of it (plus `zig fmt --check` and the docs lint) to run on each commit;
`pre-commit run --all-files` runs the same set on demand. CI does not run
pre-commit — the parity workflow's own gates stay the authority.

For git blame, ignore the formatting-only revisions:

```
git config blame.ignoreRevsFile .git-blame-ignore-revs
```

## Scope

The owned runtime targets are Linux, Windows, and macOS on x86-64 and aarch64. zfish does not add chess
features; it reproduces Stockfish's behavior. Engine strength and the NNUE
networks come from the [Stockfish project][stockfish].

## License

By contributing you agree that your contributions are licensed under the **GNU
General Public License v3** — see [Copying.txt](Copying.txt) — the same license as
Stockfish, of which zfish is a derivative.

[zig]:       https://ziglang.org
[stockfish]: https://github.com/official-stockfish/Stockfish
