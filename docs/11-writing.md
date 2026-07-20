# Writing these docs

How this set is organised, what a doc here must be true about, and what the gate does and
does not check. Read it before adding or editing a page.

## The set

`README.md` is the index — GitHub renders it for the folder, so it is what a reader lands on.
The rest are `00-`…`11-`, numbered by **reading order**, not importance: a contributor works
down from the architecture into a zone. The prefix is the only ordinal; nothing else numbers
them.

Each page owns one subsystem and names its **audience** in the index table. A page describes
**what the codebase does** — not what upstream does, not what a chess engine does in general.
Anything a reader could learn from Stockfish's wiki belongs in [10-references](10-references.md)
as a link.

## The rules

Each one is here because breaking it shipped a defect in this repo.

**Name the owner and the invariant — not just the mechanism.** Say which file and symbol
owns the behaviour, and what must stay true about it. `entryPenalize` was documented as
"decrements a stored depth", which is accurate and useless: it omitted that the decrement
**saturates at zero**. `depth8` is a `u8` and `depth8 != 0` is the occupancy test, so a
wrapping decrement turns a penalised shallow entry into the deepest entry in the table. The
prose described the mechanism and hid the constraint, leaving the clamp looking like a
removable nicety. Write the sentence a reader needs before they delete your line.

**Verify the claim against the tree; drive the binary when it is behavioural.** Not "read it
carefully" — run it. Seven claims here were false, and each took seconds to disprove:
`grep -c std.debug.print` for one, `printf 'uci\n' | stockfish 2>/dev/null | grep uciok` for
another.

**Describe a gap as a gap, never as a design.** *"zfish runs single-node"* read like an
architectural choice. It was a `u8` placeholder the whole NUMA surface dereferenced nothing
of, so every function was forced to return a constant. Framing the hole as a decision is what
kept it alive: nobody fixes a design. If something is unimplemented, say unimplemented, and
say what it costs.

**Never rationalise a defect into a convention.** A gate here asserted the UCI handshake on
stderr, with the comment *"the engine routes UCI output to stderr (same convention as the
bench signature)"*. It was not a convention — it was a P0 that made the engine unusable by
any GUI, and that sentence is why it survived for months. When you find yourself explaining
why the odd thing is fine, check whether it is.

**State the limit.** A doc that omits its own boundary invites over-trust. The rule for
regenerating a golden said it "belongs to an upstream resync, not to a failing gate" — which
forbids the case that actually occurs (a fidelity fix leaves the golden stale) and never said
how to tell a correction from laundering a bug. Say what the thing does *not* cover.

**Never pin a number a gate computes.** Module and edge counts, hook counts, the bench anchor:
quote `zig build arch-report`, `hook-lint`, `signature`. Every figure written into prose here
went stale within days — several from the same session that wrote them.

**Separate upstream fact from zfish decision.** "Upstream does X" is checkable against a
pinned sha; "zfish does Y because Z" is a choice someone must be able to revisit. Blur them
and a reader cannot tell which they are allowed to change.

**No history.** "Used to be X", "fixed in Y", "previously a stub" is out of date the day after
and tells a reader nothing about the code in front of them. The before/after belongs in the
commit message — that, plus the code, is the durable record.

**Show the command.** "It is faster" is not a claim. `nps_ab.sh` output is. A performance or
behaviour claim ships with what produced it, so the next reader can re-run it instead of
trusting you.

**One example beats three paragraphs**, and **pair every prohibition with an alternative**.
"Don't call X" leaves a reader stuck; "Don't call X — use Y, which holds the mutex" does not.

**Cut anything that does not help implement or verify.** Background a reader could get from
Stockfish's wiki belongs in [10-references](10-references.md) as a link. Length is not
thoroughness; it is where rot hides.

## Hot and cold

These pages do not age alike, and treating them the same is why they rot. A page is **hot**
when it describes code that moves: it is a running claim about a tree someone is changing
today. It is **cold** when what it describes barely moves — the rules here, external links,
patterns.

**Change hot code, re-read its page in the same commit.** Not "later": a doc is wrong from the
moment the code lands, and nobody knows which claim broke better than the person who broke it.

| page | owns | temperature |
|---|---|---|
| [00-architecture](00-architecture.md) | `build.zig`'s module graph, the zone rule | hot |
| [01-engine-board](01-engine-board.md) | `src/engine/board/` | hot |
| [02-engine-search](02-engine-search.md) | `src/engine/search/` | hot |
| [03-engine-eval](03-engine-eval.md) | `src/engine/eval/` | hot |
| [04-multithreading](04-multithreading.md) | `src/engine/state/`, the thread/NUMA path | hot |
| [05-tablebases](05-tablebases.md) | `src/platform/syzygy/`, `src/engine/search/tb_*.zig` | hot |
| [06-platform](06-platform.md) | `src/platform/` | hot |
| [07-shell](07-shell.md) | `src/shell/` | hot |
| [09-tooling-ci](09-tooling-ci.md) | `build.zig` steps, `tools/`, `.github/workflows/` | hot |
| [08-idiomatic-zig](08-idiomatic-zig.md) | patterns and the measurement discipline | cold |
| [10-references](10-references.md) | external links | cold |
| this page | the rules | cold |

The hot rows are where every false claim in this set has been found: a handler's output stream,
a facade's return value, a struct's size, a gate's assertion. All of them landed the same way —
a commit changed the code and left the page describing the code it replaced.

Cold does not mean unowned. It means the claim outlives a release, so when it *is* wrong it has
usually been wrong for a long time.

## Code comments

Same rules, plus these. Apply them to every comment you write or touch — no gate
enforces comment style, so the tree stays clean only by review.

**Imperative mood, leading with a verb.** "Resolve the path", not "Returns the path", "This
resolves…", or "Function to resolve…". PEP 257's rule, applied to Zig: a comment is an order
to the reader, not a description of the author.

```zig
// Track root-search bookkeeping and time/stop control.   <- house style
// Read the POOL's node count, not this worker's.
```

**Write only the constraint the code cannot show.** Never restate the next line. Never say
where the code came from, or why your change is right — that is the commit message's job, and
it is noise the moment the PR merges. If the line reads plainly, say nothing.

**Name the invariant, and what breaks without it.**

```zig
// Saturate at 0 (upstream tt.cpp:146). depth8 is a u8 and `depth8 != 0` is the
// occupancy test, so `-%=` turns a penalised shallow entry into the DEEPEST entry.
```

That comment survives a refactor; "decrement the depth" does not.

**Cite upstream as `file:line` when mirroring it.** `search.cpp:2088` is checkable against the
pinned sha. "upstream does this too" is not.

**No history, no meta.** Not "was a stub", not "changed in M17", not "the following block
does". A comment describes the code as it is, to someone who has never seen it before.

**Never explain an oddity into a convention.** A gate here asserted the UCI handshake on
stderr because a comment called it *"the same convention as the bench signature"*. It was a
P0. If you are writing a sentence that makes a strange thing sound intended, stop and check
whether it is a bug — that sentence is load-bearing for the next reader who might have fixed it.

## The gate

`zig build docs-lint` (inside `zig build parity`) fails on:

- a dead internal link,
- a `src/…` or `tools/…` path named in prose that does not exist (a **bare** filename like
  `uci.zig` is not checked — write the path if you want the gate to hold it),
- a bench signature quoted here that disagrees with `build.zig`.

**It cannot tell you a sentence is false.** *"`numa_context` is a never-dereferenced stub
handle"* parsed, linked, named no dead path — and was false for weeks, because the code had
moved and the prose had not. The gate buys the mechanical half so review can spend its
attention on the half that needs a reader.

That is the failure mode to write against: docs here are accurate when written and rot where
the code moves under them. A page is a claim with a shelf life, so prefer the claim that stays
true — name the owner and the invariant, point at the gate for the number.
