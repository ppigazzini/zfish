# zfish

**zfish** is a [Zig][zig] port of the [Stockfish][stockfish] chess engine. The
shipped engine is **pure Zig** — the default `zig build` compiles zero C++ — and is
**bit-exact** to upstream: it reproduces the identical `bench` node signature. Like
Stockfish, it is a UCI engine, not a GUI.

## Build

Requires **Zig 0.16.0**, no other dependencies.

```
zig build          # build the engine (ReleaseFast) -> zig-out/bin/stockfish
zig build net      # download the external NNUE network (~50 MB) into net/
zig build bench    # run bench and print the node signature
```

The NNUE network is external, not embedded. `zig build --help` lists the full
target set.

## Documentation

- [docs/](docs/0-README.md) — developer docs: the architecture and the Zig patterns.
- [CONTRIBUTING.md](CONTRIBUTING.md) — the bench gate, validation, tracking upstream.

## License

zfish is a derivative of Stockfish and is distributed under the **GNU General Public
License v3** — see [Copying.txt](Copying.txt). All chess strength and the NNUE
networks come from the [Stockfish project][stockfish]; see [AUTHORS](AUTHORS). The
networks are trained on [Leela Chess Zero data][lc0-data] under the
[ODbL][odbl].

[zig]:        https://ziglang.org
[stockfish]:  https://github.com/official-stockfish/Stockfish
[lc0-data]:   https://storage.lczero.org/files/training_data
[odbl]:       https://opendatacommons.org/licenses/odbl/odbl-10.txt
