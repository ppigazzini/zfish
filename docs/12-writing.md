# Writing these docs

How this set is organised, what a doc here must be true about, and what the gate does and
does not check. Read it before adding or editing a page.

## The set

`README.md` is the index — GitHub renders it for the folder, so it is what a reader lands on.
The rest are `00-`…`13-`, numbered by **reading order**, not importance: a contributor works
down from the architecture into a zone. The prefix is the only ordinal; nothing else numbers
them.

Each page owns one subsystem and names its **audience** in the index table. A page describes
**what the codebase does** — not what upstream does, not what a chess engine does in general.
Anything a reader could learn from Stockfish's wiki belongs in [11-references](11-references.md)
as a link.

**Two surfaces, and only one of them ships.** `docs/`, [README](../README.md),
[CONTRIBUTING](../CONTRIBUTING.md) and [AGENTS.md](../AGENTS.md) are the shipped set, written
for a contributor reading the tree cold. Beside them sits an internal, gitignored surface
carrying the engineering contract, the campaign reports and the working notes a clone never
receives. **Do not converge the two.** A shipped page must not carry campaign history, and an
internal note must not be the only place a shipped fact lives. A shipped file must not name
that surface's **location** either: `.gitignore` excludes it, so the reference dangles for
every reader except the author who wrote it. `docs-lint` sweeps the whole tracked index for
one — not a list of directories, which is how two commits broke the same rule days apart in a
sibling port — because the path check beside it cannot help: an ignored path is exempt there
by design.

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

**Never pin a list a gate owns, either.** The gates `zig build parity` aggregates, the tiers,
the lanes: a list that has drifted by one entry reads exactly like one that has not, and
prose is where that drift is invisible. The parity aggregate has one owner — the `in_parity`
flag on the gate tables in `build/checks.zig`, `build/gates.zig` and `build/structural.zig`,
which `build.zig` reads to assemble the step and `build/lanes.zig` walks to hold every other
step to it. Name that owner beside the claim instead of transcribing what it currently
yields. Where a list is genuinely useful in prose — the CI lane table, the gate battery —
write it knowing nothing checks it, and expect it to rot.

**Separate upstream fact from zfish decision.** "Upstream does X" is checkable against a
pinned sha; "zfish does Y because Z" is a choice someone must be able to revisit. Blur them
and a reader cannot tell which they are allowed to change.

**No history.** "Used to be X", "fixed in Y", "previously a stub" is out of date the day after
and tells a reader nothing about the code in front of them. The before/after belongs in the
commit message — that, plus the code, is the durable record.

**One exemption, and only for the part that is a ledger.** A refutation is a fact about this
tree, not a story about the week it was measured: the "measured dead here" sections of
[08-idiomatic-zig](08-idiomatic-zig.md) and the falsified list in [AGENTS.md](../AGENTS.md)
exist so nobody re-derives them, and the accumulator's cost sections in
[03-engine-eval](03-engine-eval.md) exist so nobody deletes a component that pays. Write each
as the rule a reader applies now, with the number as its evidence — never as a narrative of
what was tried. Everything above the measurement in those pages describes the code as it is
and is bound by this rule like any other page; a ledger that grows upward through a
description leaves a reader who wanted to know how the thing works reading a campaign diary.

**Show the command.** "It is faster" is not a claim. `nps_ab.sh` output is. A performance or
behaviour claim ships with what produced it, so the next reader can re-run it instead of
trusting you.

**One example beats three paragraphs**, and **pair every prohibition with an alternative**.
"Don't call X" leaves a reader stuck; "Don't call X — use Y, which holds the mutex" does not.

**Cut anything that does not help implement or verify.** Background a reader could get from
Stockfish's wiki belongs in [11-references](11-references.md) as a link. Length is not
thoroughness; it is where rot hides. This binds a generated page exactly as it binds a
hand-written one — match the length to what the change needs, and add no section that exists
to look complete: a summary restating the section above it, a recap of what a gate prints, a
next-steps list nobody asked for.

## Hot and cold

These pages do not age alike, and treating them the same is why they rot. A page is **hot**
when it describes code that moves: it is a running claim about a tree someone is changing
today. It is **cold** when what it describes barely moves — the rules here, external links,
patterns. **Warm** is neither: the prose is stable, but a gate or a rename underneath it can
date a row without anyone editing the page.

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
| [10-tooling-ci](10-tooling-ci.md) | `build.zig` steps, `build/`, `tools/`, `.github/workflows/` | hot |
| [09-type-design](09-type-design.md) | the value domain: what the quantities mean and which are distinguishable | warm — the rules are cold, but `type-refusal` compiles what this page says is illegal, so a claim here that stops holding reddens a gate rather than merely rotting |
| [13-glossary](13-glossary.md) | the vocabulary, in tiers | warm — a definition outlives the file it points at, but every entry names an owning symbol and a rename dates it |
| [08-idiomatic-zig](08-idiomatic-zig.md) | patterns and the measurement discipline | cold |
| [11-references](11-references.md) | external links | cold |
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

## Commit messages

**The one surface where history is the subject rather than the contamination.** Two rules
above send the before/after here; this is where it lands, and for the `perf(...)` bodies it is
not a summary of the record — it *is* the record, and the only part of it a fresh clone gets.

**Subject: a conventional type, an optional scope, and the claim. 72 characters.** The scope
is the zone or module (`perf(nnue)`, `fix(syzygy)`, `refactor(history)`). State what is now
true rather than which area was touched.

**Body wrapped at 80, in three parts:** what the change is and why it is right, the witness,
then the gates.

**The witness is the part that has to be specific.** A behaviour claim is settled against the
oracle, quoted both sides. A gate claim is settled by naming the mutant that reddened it, per
`tools/negative_control.sh` — a gate is done when it has been *seen* to fail, and the body is
where that is recorded. A cost claim carries tool, rounds, ratio and node count, and it carries
them **per tier**: a change that moves one tier and not the other moved code layout, not work.
Quote an instrument that can resolve the size of the claim — nps cannot see under ~5% here,
and a sub-1% single-tier cycle figure sits inside this box's own run-to-run floor.

**The gates block names the command and its exit code, read from the gate.** Not a pipe:
`zig build parity | tail` prints green golden lines while a later step is red, and that
laundered a red aggregate twice in one session. Name the gate the edit actually earns —
`zig build parity` for a byte-changing one, `zig build tsan-race -Dtsan -Dlto=false` for
anything a second thread reads or writes, a `-Dos=windows`/`-Dos=macos` cross-compile under
`src/platform/`, and the pinned-snapshot build for `build.zig` or `build/`. **A gate skipped
for a missing tool is not a pass**, and a body reporting it as one is worse than a body with
no gates line at all.

**Record what was falsified.** The falsified lists in
[08-idiomatic-zig](08-idiomatic-zig.md) and AGENTS.md are assembled from commit bodies, and a
reverted experiment whose measurement is deleted is a session the next contributor spends
again. A commit that changes no code and writes down why is a legitimate commit here.

**A commit body MAY quote the anchor, and it is the one place that may.** The rule against
pinning a number a gate computes is about prose, which a reader takes as current; a commit is
timestamped by construction, so an anchor in a gates block is a fact about that commit and
cannot rot. Do not carry it back into a page.

**One logical change per commit.** A commit touching three modules cannot be bisected when
the node count moves. **No `Co-authored-by`, no generated-by trailers, and do not
`git push`** — commit locally and stop unless asked.

Upstream's own convention does not apply here and should not be copied across: its `Bench:` /
"No functional change" trailer and its SPRT result blocks exist because that project decides
functional changes on fishtest, which this port does not use. The equivalent evidence here is
a gate on one machine, and it belongs in the gates block where a reader can re-run it.

## The gate, and what it cannot see

`zig build docs-lint` (inside `zig build parity`) reads every shipped `*.md` and fails on:

- **a dead internal link**, resolved against `git ls-files` rather than your checkout, so a
  file a rename left behind fails here instead of in a fresh clone. A trailing `#anchor` is
  stripped first and is **not** verified: a link to a heading that no longer exists passes.
- **a path named in prose that is not in the tree** — any `src/`, `tools/`, `docs/`, `build/`
  or `.github/` path; a path `.gitignore` names is exempt, since a doc naming the tool that
  *writes* a file is not making a claim about a tracked one. A **bare** filename like
  `uci.zig` is not checked — write the path if you want the gate to hold it, except for a
  `*.yml`, which is checked against `.github/workflows/` because the CI lane table names its
  lanes bare. `.cpp`/`.h` are **not** checked: those name upstream's tree, which these pages
  reference without owning.
- **the bench anchor, quoted at all** — the live value, not a stale one. Permitting the
  current number was the inversion that let six pinnings accumulate across four pages: each
  was legal the moment it was written, and they would all have reddened together at the next
  sync, where the cheapest way back to green is to re-pin and buy the same red again. The
  reverse is the deliberate hole — once no page may write the live number, a dead one can
  only arrive by hand.
- **a backticked identifier defined nowhere in the tree.** A deleted shell function's name
  outlived it by a whole session in 07-shell, and the three checks above all passed over it —
  which is also why this bullet does not quote the name: the gate reads its own page.
- **a build step no shipped page mentions**, since a gate a contributor cannot find is a gate
  this repo does not have.
- **a reference to the internal surface** from any tracked file.

**Three classes stay out of its reach, and they are the common ones:**

- **a real symbol attributed to the wrong file.** The symbol check asks whether the name
  exists anywhere under `src/`, `tools/` or `build.zig` — never whether it lives where the
  sentence puts it.
- **a list with the wrong count or order** — every list the rule above names. Each lints
  perfectly clean, and each has been wrong in this set.
- **a behaviour described as absent from a build that has it**, which is how AGENTS.md came
  to promise a SIGSEGV from a binary that names its missing net and exits 1.

### It cannot tell you a sentence is false

*"`numa_context` is a never-dereferenced stub
handle"* parsed, linked, named no dead path — and was false for weeks, because the code had
moved and the prose had not. The gate buys the mechanical half so review can spend its
attention on the half that needs a reader.

That is the failure mode to write against: docs here are accurate when written and rot where
the code moves under them. A page is a claim with a shelf life, so prefer the claim that stays
true — name the owner and the invariant, point at the gate for the number.
