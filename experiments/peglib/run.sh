#!/usr/bin/env bash
# Parser-vs-parser benchmark: cpp-peglib on the DuckDB grammar, DuckDB's PEG parser, and the PostgreSQL-derived
# legacy parser, all in one process on the same inputs. See README.md.
#
# Requirements: a release build of the duckdb submodule (duckdb/build/release). For the PostgreSQL variants the
# build must include the legacy_parser extension, which DuckDB pins per commit:
#   cd duckdb && GEN=ninja EXTENSION_CONFIGS='.github/config/extensions/legacy_parser.cmake' make release
#
# Usage: ./run.sh [extra bench arguments, e.g. --rounds 15 --corpus mine=/path/to/dir]
set -euo pipefail
cd "$(dirname "$0")"

ROOT="$(cd ../.. && pwd)"
DUCKDB="$ROOT/duckdb"
DUCKDB_BUILD="${DUCKDB_BUILD:-$DUCKDB/build/release}"
LEGACY_EXT="$DUCKDB_BUILD/extension/legacy_parser/legacy_parser.duckdb_extension"

make DUCKDB_BUILD="$DUCKDB_BUILD"

# refuse to benchmark a library that was built from a different commit than the grammar we translate
SOURCE_COMMIT="$(git -C "$DUCKDB" rev-parse --short=10 HEAD)"
BUILD_COMMIT="$("$DUCKDB_BUILD/duckdb" -no-agent -noheader -list -c "SELECT source_id FROM pragma_version()" 2>/dev/null || true)"
if [[ "$BUILD_COMMIT" != "$SOURCE_COMMIT" ]]; then
  echo "error: $DUCKDB_BUILD was built from '${BUILD_COMMIT}', the submodule is at ${SOURCE_COMMIT}; rebuild DuckDB" >&2
  exit 1
fi

ARGS=(--grammar build/duckdb.peg
      --corpus "tpch=$DUCKDB/extension/tpch/dbgen/queries"
      --corpus "tpcds=$DUCKDB/extension/tpcds/dsdgen/queries"
      --corpus "short=corpora/short")
if [[ -f "$LEGACY_EXT" ]]; then
  ARGS+=(--legacy-extension "$LEGACY_EXT")
else
  echo "note: $LEGACY_EXT not found, skipping the legacy parser (see header of this script)" >&2
fi

mkdir -p results
OUT="results/duckdb-${SOURCE_COMMIT}.csv"
./build/bench "${ARGS[@]}" --out "$OUT" "$@"
echo "wrote $OUT (cpp-peglib $(git -C "$ROOT/third_party/cpp-peglib" describe --tags), DuckDB ${SOURCE_COMMIT})"
python3 report.py "$OUT"
