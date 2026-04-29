#!/usr/bin/env bash
# Profile the PEG parser using samply.
#
# Runs a benchmark query many times under samply to accumulate enough CPU time
# for meaningful samples.  Results open automatically in the Firefox Profiler.
#
# Requires a reldebug build for useful stack frames:
#   cd duckdb && DUCKDB_EXTENSIONS="tpch;tpcds;json;autocomplete" make reldebug && cd ..
#
# Usage:
#   ./scripts/profile_peg.sh [query_nr] [benchmark] [scale_factor] [duration_s]
#
#   query_nr   – TPC-H/DS query number (default: highest PEG overhead at given SF)
#   benchmark  – tpch | tpcds  (default: tpch)
#   scale_factor – (default: 0.1)
#   duration_s – seconds to run before stopping (default: 10)
#
# Examples:
#   ./scripts/profile_peg.sh                       # auto-pick worst query
#   ./scripts/profile_peg.sh 6                     # TPC-H Q6
#   ./scripts/profile_peg.sh 96 tpcds 0.1          # TPC-DS Q96
#   ./scripts/profile_peg.sh 6 tpch 0.1 30         # run for 30 seconds

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Prefer reldebug binary for useful symbols; fall back to release
DUCKDB="${DUCKDB:-}"
if [[ -z "$DUCKDB" ]]; then
  if [[ -x "$REPO_ROOT/duckdb/build/reldebug/duckdb" ]]; then
    DUCKDB="$REPO_ROOT/duckdb/build/reldebug/duckdb"
  elif [[ -x "$REPO_ROOT/duckdb/build/release/duckdb" ]]; then
    DUCKDB="$REPO_ROOT/duckdb/build/release/duckdb"
    echo "WARNING: using release build — stack frames may lack symbols."
    echo "         Build with: BUILD_TYPE=reldebug make -j\$(nproc)"
  else
    echo "ERROR: no DuckDB binary found. Build first." >&2; exit 1
  fi
fi

RESULTS_DB="${RESULTS_DB:-$REPO_ROOT/results/benchmark_results.duckdb}"
DATA_DIR="${DATA_DIR:-$REPO_ROOT/data}"

QUERY_NR="${1:-}"
BENCHMARK="${2:-tpch}"
SF="${3:-0.1}"
DURATION="${4:-10}"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

command -v samply >/dev/null 2>&1 || {
  echo "ERROR: samply not found. Install with: cargo install samply" >&2; exit 1
}

# Pick the query with the highest PEG overhead at this SF if not specified
if [[ -z "$QUERY_NR" ]]; then
  if [[ -f "$RESULTS_DB" ]]; then
    QUERY_NR=$("$DUCKDB" -unsigned -noheader -list "$RESULTS_DB" -c "
      SELECT query_nr FROM results
      WHERE parser = 'peg' AND benchmark = '${BENCHMARK}' AND scale_factor = ${SF}
      GROUP BY query_nr
      ORDER BY median(relative_pct) DESC
      LIMIT 1;")
  fi
  if [[ -z "$QUERY_NR" ]]; then
    QUERY_NR=1
    log "WARNING: no benchmark data found for ${BENCHMARK} SF=${SF}, defaulting to Q1"
  fi
fi

if [[ "$BENCHMARK" == "tpch" ]]; then
  QUERY_FN="tpch_queries"
else
  QUERY_FN="tpcds_queries"
fi

BENCH_DB="$DATA_DIR/${BENCHMARK}_sf${SF}.duckdb"
[[ -f "$BENCH_DB" ]] || {
  echo "ERROR: database not found: $BENCH_DB" >&2
  echo "       Run benchmark_parser.sh to generate it." >&2
  exit 1
}

# Estimate wall-clock time so the user knows what to expect
LATENCY_MS=$("$DUCKDB" -unsigned -noheader -list "$RESULTS_DB" -c "
  SELECT round(median(latency_ms), 4) FROM results
  WHERE parser = 'peg' AND benchmark = '${BENCHMARK}'
    AND scale_factor = ${SF} AND query_nr = ${QUERY_NR};" 2>/dev/null || echo "?")
OVERHEAD_PCT=$("$DUCKDB" -unsigned -noheader -list "$RESULTS_DB" -c "
  SELECT round(median(relative_pct), 1) FROM results
  WHERE parser = 'peg' AND benchmark = '${BENCHMARK}'
    AND scale_factor = ${SF} AND query_nr = ${QUERY_NR};" 2>/dev/null || echo "?")

log "Binary:     $DUCKDB"
log "Query:      ${BENCHMARK} Q${QUERY_NR}  SF=${SF}"
log "Duration:   ${DURATION}s"
log "Approx latency per run: ${LATENCY_MS} ms  (PEG overhead: ${OVERHEAD_PCT}%)"
log "Starting samply..."

{
  echo "CALL enable_peg_parser();"
  echo "SET VARIABLE bench_query = (SELECT query FROM ${QUERY_FN}() WHERE query_nr = ${QUERY_NR});"
  yes "FROM query(getvariable('bench_query'));"
} | samply record timeout "${DURATION}s" "$DUCKDB" -unsigned "$BENCH_DB" > /dev/null
