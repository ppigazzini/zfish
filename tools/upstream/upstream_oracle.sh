#!/usr/bin/env bash
# Print the path of a PRISTINE upstream Stockfish binary, building it if it is absent.
#
# ONE ORACLE SERVES EVERY TREE. fcfish, mcfish, rfish, zfish and the golden's `refish`
# branch carry this file byte for byte and write to one ORACLE_DIR, so a commit is built
# once however many of them ask. It is never edited in one tree alone: the warning below
# compares the copies.
#
# Pristine is the point. The source is `git archive` of a commit in the golden's object
# store, built by upstream's own Makefile, so no port's edit is anywhere near it and a bug
# shared with a port cannot cancel out. The golden's working tree, index and HEAD are not
# read and not written, so it can have any branch checked out, or be mid-rebase.
#
# A build is keyed by WHAT IT IS -- commit, compiler, ARCH, make target, patch -- and
# renamed into place only once its bench equals upstream's own `Bench:` at that commit. So
# a directory that exists is a finished, verified build, and nothing can be stale: moving
# the pin or the compiler names a different directory.
#
#   $ORACLE_DIR/<sha12>/<compiler>-<ARCH>-<target>[-patch-<hash>]/{stockfish,nn-*.nnue,BUILD}
#   $ORACLE_DIR/nets/nn-*.nnue
#
# A TREE IS COMPARED WITH UPSTREAM BUILT BY ITS OWN COMPILER, always and by default: another
# one measures the compilers. That is clang, or the wrapper an ORACLE_CXX file beside this
# one names; a gcc build of a tree asks for ORACLE_COMP=gcc. Trees that share a compiler
# share the binary. The default has no profile, because PGO inlines away functions the
# call-count fingerprints read.
#
# Usage:
#   upstream_oracle.sh [sha]           print the binary, building it if needed
#   upstream_oracle.sh [sha] --path    print the binary if it is built, else exit 3
#   upstream_oracle.sh [sha] --verify  re-bench the binary against `Bench:` as well
#   upstream_oracle.sh [sha] --patch F build with F applied; the bench is not checked
#   upstream_oracle.sh [sha] --prune   delete every other commit's builds and nets
#   upstream_oracle.sh --dir           print ORACLE_DIR
#     sha defaults to the UPSTREAM_BASE file beside this one, or, on a branch of the golden,
#     which carries none, to its merge-base with master. Only the path goes to stdout.
#
# Env:
#   UPSTREAM_REPO  the golden             (default: ../Stockfish beside this repository)
#   ORACLE_DIR     the shared builds      (default: ../.upstream-oracle beside it)
#   ORACLE_COMP    make COMP=             (default: clang)
#   ORACLE_CXX     make COMPCXX=          (default: the port's own; see above)
#   ORACLE_ARCH    make ARCH=             (default: x86-64-sse41-popcnt)
#   ORACLE_TARGET  build | profile-build  (default: build)
#   ORACLE_JOBS    make -j                (default: every processor)
#
# Exit: 0 printed a path, 1 the build or its bench is wrong, 2 the rig is, 3 not built.
set -euo pipefail

die() { local rc=$1; shift; printf '\033[31mupstream-oracle: %s\033[0m\n' "$@" >&2; exit "$rc"; }
info() { printf '\033[36m==>\033[0m %s\n' "upstream-oracle: $*" >&2; }

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(git -C "$HERE" rev-parse --show-toplevel 2>/dev/null) || ROOT=$(cd "$HERE/../.." && pwd)

# Resolve the siblings from the MAIN checkout, so a git worktree of a port -- wherever it
# lives -- reaches the same golden and the same oracle as the port itself.
common=$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || common=$ROOT/.git
PARENT=$(cd "$(dirname "$common")/.." && pwd)

ref='' mode=build verify=0 patch=''
while [[ $# -gt 0 ]]; do
  case $1 in
    --path | --prune | --dir) mode=${1#--} ;;
    --verify) verify=1 ;;
    --patch)
      [[ -f ${2:-} ]] || die 2 "--patch needs a file, got '${2:-}'"
      patch=$(cd "$(dirname "$2")" && pwd)/$(basename "$2")
      shift
      ;;
    -*) die 2 "unknown flag '$1'" ;;
    *) [[ -z $ref ]] || die 2 "two commits given: '$ref' and '$1'"; ref=$1 ;;
  esac
  shift
done

cd "$ROOT"
UPSTREAM_REPO=${UPSTREAM_REPO:-$PARENT/Stockfish}
ORACLE_DIR=$(realpath -m "${ORACLE_DIR:-$PARENT/.upstream-oracle}")
if [[ -z ${ORACLE_COMP:-}${ORACLE_CXX:-} && -f $HERE/ORACLE_CXX ]]; then
  ORACLE_CXX=$ROOT/$(tr -d '[:space:]' < "$HERE/ORACLE_CXX")
fi
ORACLE_COMP=${ORACLE_COMP:-clang}
ORACLE_ARCH=${ORACLE_ARCH:-x86-64-sse41-popcnt}
ORACLE_TARGET=${ORACLE_TARGET:-build}

[[ $mode == dir ]] && { printf '%s\n' "$ORACLE_DIR"; exit 0; }

# A path this script deletes under must be one this script made. ORACLE_DIR pointed at a
# checkout -- the golden's above all -- is refused rather than written into.
MARK=$ORACLE_DIR/.upstream-oracle
[[ ! -e $ORACLE_DIR || -f $MARK ]] ||
  die 2 "$ORACLE_DIR exists and is not an oracle directory (no .upstream-oracle in it)"

for dir in "$PARENT"/{fcfish,mcfish,rfish,zfish}/tools/upstream "$PARENT/Stockfish/tests"; do
  for f in upstream_oracle.sh oracle_profile.sh oracle_counters.py; do
    [[ ! -f $HERE/$f || ! -f $dir/$f ]] || cmp -s "$HERE/$f" "$dir/$f" ||
      printf '\033[31mupstream-oracle: WARNING -- %s differs from %s; the copies must be identical\033[0m\n' "$f" "$dir/$f" >&2
  done
done

git -C "$UPSTREAM_REPO" rev-parse --git-dir >/dev/null 2>&1 ||
  die 2 "no upstream Stockfish clone at $UPSTREAM_REPO" "clone it there, or set UPSTREAM_REPO"
if [[ -z $ref && -f $HERE/UPSTREAM_BASE ]]; then
  ref=$(tr -d '[:space:]' < "$HERE/UPSTREAM_BASE")
elif [[ -z $ref ]]; then
  ref=$(git merge-base HEAD master 2>/dev/null) || true
fi
[[ -n $ref ]] || die 2 "no commit given, no UPSTREAM_BASE beside this file and no merge-base with master"
sha=$(git -C "$UPSTREAM_REPO" rev-parse --verify --quiet "$ref^{commit}") ||
  die 2 "$ref is not a commit in $UPSTREAM_REPO -- fetch upstream there"

case $ORACLE_COMP in
  gcc) cxx=g++ ;;
  clang) cxx=clang++ ;;
  *) [[ -n ${ORACLE_CXX:-} ]] || die 2 "ORACLE_COMP=$ORACLE_COMP needs ORACLE_CXX" ;;
esac
cxx=${ORACLE_CXX:-$cxx}
version=$("$cxx" -dumpversion 2>/dev/null) || die 2 "no working C++ compiler at $cxx"

variant=$(basename "$cxx")-$version-$ORACLE_ARCH-$ORACLE_TARGET
[[ -z $patch ]] || variant+=-patch-$(sha256sum < "$patch" | cut -c1-8)
dest=$ORACLE_DIR/${sha:0:12}/$variant
bin=$dest/stockfish

bench_of() { (cd "$(dirname "$1")" && "$1" bench 2>&1) | sed -n 's/^Nodes searched *: *\([0-9]*\).*/\1/p'; }

# The newest footer at or before the commit: a non-functional commit carries none and
# benches what its predecessor declared. Read to the end -- a reader that stops at the
# first match kills git with SIGPIPE, and pipefail reports that as a failure.
declared() {
  git -C "$UPSTREAM_REPO" log --format=%b "$sha" |
    awk '/^[Bb]ench:? [1-9][0-9]+$/ && !n { n = $2 } END { print n }'
}

check_bench() { # <binary>
  local got want
  got=$(bench_of "$1") || true
  want=$(declared)
  [[ -n $want ]] || die 1 "no Bench: footer at or before ${sha:0:12}"
  [[ $got == "$want" ]] || die 1 "${sha:0:12} benches ${got:-nothing}, and upstream declares $want"
  info "${sha:0:12} benches $got, as upstream declares"
}

if [[ $mode == path ]]; then
  [[ -x $bin ]] || exit 3
  printf '%s\n' "$bin"
  exit 0
fi

mkdir -p "$ORACLE_DIR/nets"
: > "$MARK"

# One builder at a time: the ports share this directory, and a second caller for the same
# build waits for the first and then finds it done.
exec 9> "$ORACLE_DIR/.lock"
if command -v flock >/dev/null; then flock 9; fi

if [[ $mode == prune ]]; then
  for d in "$ORACLE_DIR"/*/; do
    d=$(basename "$d")
    [[ $d =~ ^[0-9a-f]{12}$ && $d != "${sha:0:12}" ]] || continue
    info "pruning $d"
    rm -rf -- "${ORACLE_DIR:?}/$d"
  done
  # A net no remaining build is linked to has one name left, the one in nets/.
  find "$ORACLE_DIR/nets" -type f -links 1 -delete
  [[ -x $bin ]] || exit 3
  printf '%s\n' "$bin"
  exit 0
fi

net_ok() { [[ -f $1 && $(basename "$1") == nn-$(sha256sum < "$1" | cut -c1-12).nnue ]]; }

if [[ ! -x $bin ]]; then
  work=$(mktemp -d "$ORACLE_DIR/.build.XXXXXX")
  trap 'rm -rf -- "$work"' EXIT
  log=$work/build.log
  info "building ${sha:0:12} as $variant"

  git -C "$UPSTREAM_REPO" archive "$sha" | tar -x -C "$work"
  # The ceiling keeps `git apply` from finding an enclosing repository, where it would
  # treat every path as outside the tree and apply nothing.
  [[ -z $patch ]] || GIT_CEILING_DIRECTORIES=$ORACLE_DIR git -C "$work" apply "$patch" ||
    die 1 "$patch does not apply at ${sha:0:12}"

  # Take the net from a copy already on this box, checked against its own name, and let
  # upstream's `net` target download only what is nowhere.
  mapfile -t nets < <(sed -n 's/^#define EvalFileDefaultName[A-Za-z]* "\(nn-[0-9a-f]*\.nnue\)".*/\1/p' "$work/src/evaluate.h")
  for net in "${nets[@]}"; do
    for from in "$ORACLE_DIR/nets" "$UPSTREAM_REPO/src" "$ROOT/resources"; do
      net_ok "$from/$net" || continue
      [[ $from == "$ORACLE_DIR/nets" ]] || cp -- "$from/$net" "$ORACLE_DIR/nets/$net"
      ln -- "$ORACLE_DIR/nets/$net" "$work/src/$net"
      break
    done
  done

  # Stamp the commit by hand: an archive has no .git for the Makefile to ask. A patched
  # build carries upstream's own `-m` marker, so it names itself as not pristine.
  args=("ARCH=$ORACLE_ARCH" "COMP=$ORACLE_COMP" "GIT_SHA=${sha:0:8}"
    "GIT_DATE=$(git -C "$UPSTREAM_REPO" show -s --date=format:%Y%m%d --format=%cd "$sha")"
    "GIT_DIFFINDEX=${patch:+1}")
  [[ -z ${ORACLE_CXX:-} ]] || args+=("COMPCXX=$ORACLE_CXX")
  TMPDIR=$work make -C "$work/src" -j"${ORACLE_JOBS:-$(nproc)}" "$ORACLE_TARGET" "${args[@]}" > "$log" 2>&1 9>&- || {
    tail -30 "$log" >&2
    die 1 "make $ORACLE_TARGET ${args[*]} failed"
  }
  [[ -x $work/src/stockfish ]] || die 1 "make $ORACLE_TARGET produced no binary"
  [[ -n $patch ]] || check_bench "$work/src/stockfish"

  mkdir "$work/out"
  mv -- "$work/src/stockfish" "$work/out/"
  for net in "${nets[@]}"; do
    net_ok "$work/src/$net" || die 1 "$net is absent after the build, or is not what its name says"
    [[ -f $ORACLE_DIR/nets/$net ]] || ln -- "$work/src/$net" "$ORACLE_DIR/nets/$net"
    ln -- "$ORACLE_DIR/nets/$net" "$work/out/$net"
  done
  {
    printf 'commit   %s\nmake     %s %s\ncompiler %s\n' "$sha" "$ORACLE_TARGET" "${args[*]}" "$("$cxx" --version | sed -n 1p)"
    [[ -z $patch ]] || printf 'patch    %s\n' "$patch"
  } > "$work/out/BUILD"

  mkdir -p "$(dirname "$dest")"
  rm -rf -- "$dest"
  mv -- "$work/out" "$dest"
  info "built $bin"
elif [[ $verify == 1 && -z $patch ]]; then
  check_bench "$bin"
fi

printf '%s\n' "$bin"
