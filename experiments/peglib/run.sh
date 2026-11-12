#!/usr/bin/env bash
# Parser-vs-parser benchmark: cpp-peglib on the DuckDB grammar, DuckDB's PEG parser, and the PostgreSQL-derived
# legacy parser, all in one process on the same inputs. See README.md.
#
# Several DuckDB builds can be compared. Each gets its own bench binary (they cannot share a process), and the
# binaries are run in alternating passes so that drift on the machine hits all of them alike. cpp-peglib and the
# PostgreSQL parser are measured in every binary and serve as anchors: report.py prints how far they differ.
#
# DuckDB builds (label=source tree, release build expected in <source tree>/build/release):
#   default: main=<repo>/duckdb, plus every <repo>/builds/duckdb-<label> that has a release build
#   override: DUCKDB_VARIANTS="main=/path/a perf=/path/b" ./run.sh
#
# Each build needs the legacy_parser extension for the PostgreSQL variants; DuckDB pins it per commit:
#   cd <source tree> && GEN=ninja EXTENSION_CONFIGS='.github/config/extensions/legacy_parser.cmake' make release
# A branch is checked out next to the submodule with:
#   git -C duckdb fetch <remote-url> <branch>
#   git -C duckdb worktree add --detach ../builds/duckdb-<label> FETCH_HEAD
#
# Usage: [PASSES=3] ./run.sh [extra bench arguments, e.g. --rounds 5 --corpus mine=/path/to/dir]
set -euo pipefail
cd "$(dirname "$0")"

ROOT="$(cd ../.. && pwd)"
PASSES="${PASSES:-3}"

if [[ -z "${DUCKDB_VARIANTS:-}" ]]; then
  DUCKDB_VARIANTS="main=$ROOT/duckdb"
  for dir in "$ROOT"/builds/duckdb-*; do
    [[ -x "$dir/build/release/duckdb" ]] && DUCKDB_VARIANTS+=" ${dir##*/duckdb-}=$dir"
  done
fi

mkdir -p results
STAMP="$(date +%Y-%m-%d)"
OUT="results/${STAMP}.csv"
rm -f "$OUT"

LABELS=()
declare -a COMMANDS
for variant in $DUCKDB_VARIANTS; do
  label="${variant%%=*}"
  src="${variant#*=}"
  build="$src/build/release"
  make DUCKDB="$src" DUCKDB_BUILD="$build" BUILD="build/$label" >&2

  # refuse to benchmark a library that was built from a different commit than the grammar we translate
  source_commit="$(git -C "$src" rev-parse --short=10 HEAD)"
  build_commit="$("$build/duckdb" -no-agent -noheader -list -c "SELECT source_id FROM pragma_version()" 2>/dev/null || true)"
  if [[ "$build_commit" != "$source_commit" ]]; then
    echo "error: $build was built from '${build_commit}', the source tree is at ${source_commit}; rebuild DuckDB" >&2
    exit 1
  fi
  if [[ -n "$(git -C "$src" status --porcelain --untracked-files=no)" ]]; then
    echo "note: $label has local changes on top of ${source_commit}:" >&2
    git -C "$src" status --porcelain --untracked-files=no >&2
    source_commit+="+local"
  fi

  args=(--grammar "build/$label/duckdb.peg" --label "$label" --commit "$source_commit"
        --corpus "tpch=$src/extension/tpch/dbgen/queries"
        --corpus "tpcds=$src/extension/tpcds/dsdgen/queries"
        --corpus "short=corpora/short")
  legacy="$build/extension/legacy_parser/legacy_parser.duckdb_extension"
  if [[ -f "$legacy" ]]; then
    args+=(--legacy-extension "$legacy")
  else
    echo "note: $legacy not found, skipping the legacy parser for $label (see header of this script)" >&2
  fi
  LABELS+=("$label")
  COMMANDS+=("$(printf '%q ' "build/$label/bench" "${args[@]}")")
done

for pass in $(seq 1 "$PASSES"); do
  for i in "${!LABELS[@]}"; do
    echo "pass $pass/$PASSES: ${LABELS[$i]}" >&2
    eval "${COMMANDS[$i]}" --out "$OUT" --append --pass "$pass" '"$@"' 2>/dev/null
  done
done

echo "wrote $OUT (cpp-peglib $(git -C "$ROOT/third_party/cpp-peglib" describe --tags))" >&2
python3 report.py "$OUT"
