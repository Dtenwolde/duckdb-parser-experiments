#!/usr/bin/env bash
set -euo pipefail

# ── Usage ──────────────────────────────────────────────────────────────────────
# ./scripts/bench_version.sh <commit-or-branch> [label]
#
#   commit-or-branch  – any ref the duckdb submodule's repository can resolve or fetch
#                       (branch name, tag, or commit hash). Set REMOTE to fetch it from another
#                       repository, e.g. REMOTE=git@github.com:Dtenwolde/duckdb.git
#   label             – name stored in the results DB as VERSION and used for the checkout
#                       (defaults to the short commit hash)
#
# The revision is checked out as a git worktree of the submodule under builds/duckdb-<label>, built there
# with tpch, tpcds, json and the legacy_parser extension that the revision pins, and benchmarked with
# benchmark_parser.sh. The duckdb submodule itself is never touched. experiments/peglib/run.sh picks up the
# same worktrees.
#
# All benchmark env vars (SFS, RUNS, WARMUP, RESULTS_DB, …) are forwarded to benchmark_parser.sh unchanged.
#
# Examples:
#   ./scripts/bench_version.sh origin/main upstream-main
#   REMOTE=git@github.com:Dtenwolde/duckdb.git ./scripts/bench_version.sh parser-performance
#   SFS="1 10" RUNS=10 ./scripts/bench_version.sh v2.0.0 v2.0.0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DUCKDB_DIR="$REPO_ROOT/duckdb"
BUILDS_DIR="$REPO_ROOT/builds"

TARGET="${1:-}"
LABEL="${2:-}"
REMOTE="${REMOTE:-origin}"

[[ -n "$TARGET" ]] || {
  echo "Usage: $0 <commit-or-branch> [label]" >&2
  exit 1
}

log() { echo "[$(date '+%H:%M:%S')] $*"; }
die() {
  echo "ERROR: $*" >&2
  exit 1
}

# ── Resolve the target ─────────────────────────────────────────────────────────
if FULL_HASH=$(git -C "$DUCKDB_DIR" rev-parse --verify --quiet "${TARGET}^{commit}"); then
  log "'$TARGET' resolves locally to $FULL_HASH"
else
  log "Fetching '$TARGET' from $REMOTE ..."
  git -C "$DUCKDB_DIR" fetch --quiet "$REMOTE" "$TARGET" || die "cannot fetch '$TARGET' from $REMOTE"
  FULL_HASH=$(git -C "$DUCKDB_DIR" rev-parse FETCH_HEAD)
fi
SHORT=$(git -C "$DUCKDB_DIR" rev-parse --short "$FULL_HASH")
LABEL="${LABEL:-$SHORT}"
WORKTREE="$BUILDS_DIR/duckdb-$LABEL"

log "Version label : $LABEL"
log "Full commit   : $FULL_HASH"

# ── Check out (worktree) ───────────────────────────────────────────────────────
if [[ -d "$WORKTREE" ]]; then
  CURRENT=$(git -C "$WORKTREE" rev-parse HEAD)
  if [[ "$CURRENT" != "$FULL_HASH" ]]; then
    die "$WORKTREE is at $CURRENT, not at $FULL_HASH.
Move it with 'git -C $WORKTREE checkout --detach $FULL_HASH', or pick another label."
  fi
  log "Reusing worktree $WORKTREE"
else
  mkdir -p "$BUILDS_DIR"
  git -C "$DUCKDB_DIR" worktree add --quiet --detach "$WORKTREE" "$FULL_HASH"
  log "Created worktree $WORKTREE"
fi
if [[ -n "$(git -C "$WORKTREE" status --porcelain --untracked-files=no)" ]]; then
  log "NOTE: $WORKTREE has local changes on top of $SHORT:"
  git -C "$WORKTREE" status --porcelain --untracked-files=no
  LABEL_SUFFIX="+local"
fi

# ── Build (incremental) ────────────────────────────────────────────────────────
LEGACY_CONFIG=".github/config/extensions/legacy_parser.cmake"
[[ -f "$WORKTREE/$LEGACY_CONFIG" ]] || die "$SHORT does not pin the legacy_parser extension ($LEGACY_CONFIG);
it predates the PEG parser becoming the default and cannot be compared with this script."

log "Building DuckDB in $WORKTREE (this may take a while) ..."
GEN=ninja DUCKDB_EXTENSIONS='tpch;tpcds;json' EXTENSION_CONFIGS="$LEGACY_CONFIG" \
  make -C "$WORKTREE" release >"$WORKTREE/build.log" 2>&1 || die "build failed, see $WORKTREE/build.log"
BINARY="$WORKTREE/build/release/duckdb"
log "Binary: $BINARY"

# ── Run benchmarks ─────────────────────────────────────────────────────────────
log "Starting benchmarks for version '$LABEL' ..."
DUCKDB="$BINARY" VERSION="${LABEL}${LABEL_SUFFIX:-}" bash "$SCRIPT_DIR/benchmark_parser.sh"
