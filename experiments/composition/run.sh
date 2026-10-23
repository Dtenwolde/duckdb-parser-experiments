#!/usr/bin/env bash
# Grammar-composition experiments: can several grammar extensions (and a dialect)
# be active in one connection, and do mixed statements parse?
#
# Requires saneql and duckpgq-extension built against the SAME DuckDB commit
# (both are submodules of this repo; the pipe-syntax demo is DuckDB's own
# test/extension/loadable_grammar_extension_demo, built by either tree).
#
#   SANEQL_BUILD=../../saneql/build/release DUCKPGQ_BUILD=../../duckpgq-extension/build/release ./run.sh [NN...]
#
# With no arguments every numbered .sql file is run; pass prefixes (e.g. 11 14) to select.
set -uo pipefail
cd "$(dirname "$0")"
SANEQL_BUILD="${SANEQL_BUILD:-$(cd ../../saneql/build/release 2>/dev/null && pwd)}"
DUCKPGQ_BUILD="${DUCKPGQ_BUILD:-$(cd ../../duckpgq-extension/build/release 2>/dev/null && pwd)}"
DUCKDB="${DUCKDB:-$DUCKPGQ_BUILD/duckdb}"
export SANEQL_BUILD DUCKPGQ_BUILD
unset AI_AGENT
[[ -x "$DUCKDB" ]] || { echo "no duckdb binary at $DUCKDB" >&2; exit 1; }

run() { # run <setup> <test>
  echo "===== $2 ====="
  cat "$1" "$2" | envsubst '${SANEQL_BUILD} ${DUCKPGQ_BUILD}' | "$DUCKDB" -unsigned -no-agent -box 2>&1 | grep -vE '^\s*$'
}
sel=("$@")
for f in [0-9][0-9]_*.sql; do
  case "$f" in 00_*|10_*) continue;; esac
  if ((${#sel[@]})); then m=0; for p in "${sel[@]}"; do [[ "$f" == "$p"* ]] && m=1; done; ((m)) || continue; fi
  case "$f" in 0*) run 00_setup_saneql_duckpgq.sql "$f";; 1*) run 10_setup_duckpgq_pipe.sql "$f";; esac
done
