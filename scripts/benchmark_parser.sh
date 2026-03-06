#!/usr/bin/env bash
set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

DUCKDB="${DUCKDB:-$REPO_ROOT/duckdb/build/release/duckdb}"
SCALE_FACTORS="${SFS:-0 0.1 1}" # space-separated, e.g. SFS="1 10 100"
RESULTS_DB="${RESULTS_DB:-$REPO_ROOT/results/benchmark_results.duckdb}"
DATA_DIR="${DATA_DIR:-$REPO_ROOT/data}"
PROFILING_JSON="$REPO_ROOT/results/profiling.json"
PARSERS=("postgres" "peg")
RUNS="${RUNS:-5}"
TPCH_QUERIES=$(seq 1 22)

# ── Helpers ───────────────────────────────────────────────────────────────────
log() { echo "[$(date '+%H:%M:%S')] $*"; }
die() {
  echo "ERROR: $*" >&2
  exit 1
}

# ── Pre-flight ────────────────────────────────────────────────────────────────
[[ -x "$DUCKDB" ]] || die "DuckDB binary not found at '$DUCKDB'.
Build it first:
  cd $REPO_ROOT/duckdb
  DUCKDB_EXTENSIONS='tpch;json' make -j\$(nproc)"

mkdir -p "$DATA_DIR" "$(dirname "$RESULTS_DB")"

# ── Ensure results table exists ───────────────────────────────────────────────
"$DUCKDB" -unsigned "$RESULTS_DB" -c "
CREATE TABLE IF NOT EXISTS results (
    run_at          TIMESTAMPTZ DEFAULT now(),
    query_nr        INTEGER,
    run_nr          INTEGER,
    scale_factor    DOUBLE,
    parser          VARCHAR,
    latency_ms      DOUBLE,
    parser_ms       DOUBLE,
    relative_pct    DOUBLE
);"

# ── Outer loop: scale factors ─────────────────────────────────────────────────
for SCALE_FACTOR in $SCALE_FACTORS; do

  TPCH_DB="$DATA_DIR/tpch_sf${SCALE_FACTOR}.duckdb"

  if [[ ! -f "$TPCH_DB" ]]; then
    log "════════════════════════════════════════════"
    log "Generating TPC-H data SF=${SCALE_FACTOR} -> $TPCH_DB ..."
    "$DUCKDB" -unsigned "$TPCH_DB" -c "CALL dbgen(sf=${SCALE_FACTOR});"
    log "TPC-H data ready."
  else
    log "════════════════════════════════════════════"
    log "Reusing existing TPC-H database: $TPCH_DB"
  fi

  TOTAL=$((22 * ${#PARSERS[@]} * RUNS))
  DONE=0

  for QUERY_NR in $TPCH_QUERIES; do
    for PARSER in "${PARSERS[@]}"; do
      for RUN in $(seq 1 $RUNS); do
        DONE=$((DONE + 1))
        log "SF=${SCALE_FACTOR} [$DONE/$TOTAL] Q${QUERY_NR} | parser=${PARSER} | run=${RUN}/${RUNS}"

        if [[ "$PARSER" == "peg" ]]; then
          PARSER_TOGGLE="CALL enable_peg_parser();"
        else
          PARSER_TOGGLE="CALL disable_peg_parser();"
        fi

        rm -f "$PROFILING_JSON"

        echo "FROM query(getvariable('bench_query'));" |
          "$DUCKDB" -unsigned -bail "$TPCH_DB" \
            -cmd "$PARSER_TOGGLE" \
            -cmd "SET enable_profiling = 'json';" \
            -cmd "SET profiling_mode = 'detailed';" \
            -cmd "SET profile_output = '${PROFILING_JSON}';" \
            -cmd "SET VARIABLE bench_query = (SELECT query FROM tpch_queries() WHERE query_nr = ${QUERY_NR});" \
            >/dev/null

        if [[ ! -f "$PROFILING_JSON" ]]; then
          log "WARNING: profiling.json missing for SF=${SCALE_FACTOR} Q${QUERY_NR} parser=${PARSER} run=${RUN}, skipping."
          continue
        fi

        "$DUCKDB" -unsigned -bail "$RESULTS_DB" -c "
INSERT INTO results (query_nr, run_nr, scale_factor, parser, latency_ms, parser_ms, relative_pct)
SELECT
    ${QUERY_NR}                       AS query_nr,
    ${RUN}                            AS run_nr,
    ${SCALE_FACTOR}                   AS scale_factor,
    '${PARSER}'                       AS parser,
    latency                           AS latency_ms,
    parser                            AS parser_ms,
    round(parser / latency * 100, 4)  AS relative_pct
FROM '${PROFILING_JSON}';"

      done
    done
  done

done # scale factors

# ── Summary ───────────────────────────────────────────────────────────────────
log "══════════════════════════════════════════"
log "Summary — median across ${RUNS} runs, all scale factors"
"$DUCKDB" -unsigned -bail "$RESULTS_DB" -c "
SELECT
    scale_factor,
    query_nr,
    parser,
    round(median(latency_ms),   6) AS median_latency_ms,
    round(median(parser_ms),    6) AS median_parser_ms,
    round(median(relative_pct), 4) AS median_relative_pct
FROM results
GROUP BY scale_factor, query_nr, parser
ORDER BY scale_factor, query_nr, parser;"

log "Results written to: $RESULTS_DB"
