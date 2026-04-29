#!/usr/bin/env bash
set -euo pipefail

# ── Usage ──────────────────────────────────────────────────────────────────────
# ./scripts/bench_version.sh <commit-or-branch> [label]
#
#   commit-or-branch  – any ref resolvable by the duckdb submodule's git
#                       (branch name, tag, or full/short commit hash)
#   label             – human-readable name stored in the results DB as VERSION
#                       (defaults to the short commit hash)
#
# All benchmark env vars (SFS, RUNS, RESULTS_DB, …) are forwarded to
# benchmark_parser.sh unchanged.
#
# Builds are cached under builds/<label>/duckdb; re-running the same label
# skips the build step and goes straight to benchmarking.
#
# Examples:
#   ./scripts/bench_version.sh main
#   ./scripts/bench_version.sh my-caching-branch peg-caching
#   ./scripts/bench_version.sh abc1234            peg-caching
#   SFS="1 10" RUNS=10 ./scripts/bench_version.sh main baseline

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DUCKDB_DIR="$REPO_ROOT/duckdb"
BUILDS_DIR="$REPO_ROOT/builds"

TARGET="${1:-}"
LABEL="${2:-}"

[[ -n "$TARGET" ]] || {
  echo "Usage: $0 <commit-or-branch> [label]" >&2
  exit 1
}

log() { echo "[$(date '+%H:%M:%S')] $*"; }

# ── Save current submodule state ───────────────────────────────────────────────
ORIGINAL=$(git -C "$DUCKDB_DIR" rev-parse HEAD)
log "duckdb submodule is currently at $ORIGINAL"

restore() {
  log "Restoring duckdb submodule to $ORIGINAL ..."
  git -C "$DUCKDB_DIR" checkout --quiet "$ORIGINAL"
  log "Submodule restored."
}
trap restore EXIT

# ── Checkout target ────────────────────────────────────────────────────────────
log "Fetching origin in duckdb submodule ..."
git -C "$DUCKDB_DIR" fetch --quiet origin
# Also try fetching the target from upstream (e.g. official release tags)
git -C "$DUCKDB_DIR" fetch --quiet upstream \
  "refs/tags/${TARGET}:refs/tags/${TARGET}" 2>/dev/null || \
git -C "$DUCKDB_DIR" fetch --quiet upstream "${TARGET}" 2>/dev/null || true

log "Checking out '$TARGET' ..."
git -C "$DUCKDB_DIR" checkout --quiet "$TARGET"

FULL_HASH=$(git -C "$DUCKDB_DIR" rev-parse HEAD)
SHORT=$(git -C "$DUCKDB_DIR" rev-parse --short HEAD)
LABEL="${LABEL:-$SHORT}"

log "Version label : $LABEL"
log "Full commit   : $FULL_HASH"

# ── Build (cached) ─────────────────────────────────────────────────────────────
BINARY="$BUILDS_DIR/$LABEL/duckdb"

if [[ -x "$BINARY" ]]; then
  log "Cached build found at $BINARY — skipping rebuild."
else
  NCPU=$(nproc 2>/dev/null || sysctl -n hw.logicalcpu 2>/dev/null || echo 4)
  log "Building DuckDB with $NCPU cores (this may take a while) ..."
  DUCKDB_EXTENSIONS="tpch;tpcds;json;autocomplete" \
    make -C "$DUCKDB_DIR" -j"$NCPU" 2>&1
  mkdir -p "$BUILDS_DIR/$LABEL"
  cp "$DUCKDB_DIR/build/release/duckdb" "$BINARY"
  log "Binary saved to $BINARY"
fi

# ── Run benchmarks ─────────────────────────────────────────────────────────────
log "Starting benchmarks for version '$LABEL' ..."
DUCKDB="$BINARY" VERSION="$LABEL" bash "$SCRIPT_DIR/benchmark_parser.sh"
