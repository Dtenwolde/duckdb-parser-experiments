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
ERROR_LOG="$REPO_ROOT/results/errors.log"
IFS=' ' read -r -a PARSERS <<< "${PARSERS_LIST:-postgres peg}"
RUNS="${RUNS:-5}"
VERSION="${VERSION:-$(git -C "$REPO_ROOT/duckdb" rev-parse --short HEAD 2>/dev/null || echo "unknown")}"

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
  DUCKDB_EXTENSIONS='tpch;tpcds;json;autocomplete' make -j\$(nproc)"

mkdir -p "$DATA_DIR" "$(dirname "$RESULTS_DB")"
: > "$ERROR_LOG"  # truncate / create

# ── Ensure results table exists ───────────────────────────────────────────────
"$DUCKDB" -unsigned "$RESULTS_DB" -c "
CREATE TABLE IF NOT EXISTS results (
    run_at          TIMESTAMPTZ DEFAULT now(),
    version         VARCHAR,
    benchmark       VARCHAR,
    query_nr        INTEGER,
    run_nr          INTEGER,
    scale_factor    DOUBLE,
    parser          VARCHAR,
    latency_ms      DOUBLE,
    parser_ms       DOUBLE,
    relative_pct    DOUBLE
);
ALTER TABLE results ADD COLUMN IF NOT EXISTS version   VARCHAR;
ALTER TABLE results ADD COLUMN IF NOT EXISTS benchmark VARCHAR;"

# ── Inner benchmark loop ───────────────────────────────────────────────────────
# Usage: run_benchmark <benchmark> <db_file> <query_count> <query_fn>
#   benchmark   – tpch | tpcds
#   db_file     – path to the pre-generated data database
#   query_count – number of queries (22 for tpch, 99 for tpcds)
#   query_fn    – SQL function name returning (query_nr, query) rows
run_benchmark() {
  local BENCHMARK="$1"
  local BENCH_DB="$2"
  local QUERY_COUNT="$3"
  local QUERY_FN="$4"
  local QUERIES
  QUERIES=$(seq 1 "$QUERY_COUNT")

  local TOTAL=$(( QUERY_COUNT * ${#PARSERS[@]} * RUNS ))
  local DONE=0

  for QUERY_NR in $QUERIES; do
    for PARSER in "${PARSERS[@]}"; do
      for RUN in $(seq 1 $RUNS); do
        DONE=$((DONE + 1))
        log "SF=${SCALE_FACTOR} ${BENCHMARK} [$DONE/$TOTAL] Q${QUERY_NR} | parser=${PARSER} | run=${RUN}/${RUNS}"

        TOGGLE_ARGS=()
        if [[ "${PEG_DEFAULT:-0}" == "1" ]]; then
          : # PEG is the default parser; no toggle call exists
        elif [[ "$PARSER" == "peg" ]]; then
          TOGGLE_ARGS=(-cmd "CALL enable_peg_parser();")
        else
          TOGGLE_ARGS=(-cmd "CALL disable_peg_parser();")
        fi

        rm -f "$PROFILING_JSON"

        if ! echo "FROM query(getvariable('bench_query'));" |
          "$DUCKDB" -unsigned "$BENCH_DB" \
            "${TOGGLE_ARGS[@]}" \
            -cmd "SET enable_profiling = 'json';" \
            -cmd "SET profiling_mode = 'detailed';" \
            -cmd "SET profile_output = '${PROFILING_JSON}';" \
            -cmd "SET VARIABLE bench_query = (SELECT query FROM ${QUERY_FN}() WHERE query_nr = ${QUERY_NR});" \
            >/dev/null 2>>"$ERROR_LOG"; then
          log "WARNING: query failed for SF=${SCALE_FACTOR} ${BENCHMARK} Q${QUERY_NR} parser=${PARSER} run=${RUN} — see errors.log"
          continue
        fi

        if [[ ! -f "$PROFILING_JSON" ]]; then
          log "WARNING: profiling.json missing for SF=${SCALE_FACTOR} ${BENCHMARK} Q${QUERY_NR} parser=${PARSER} run=${RUN}, skipping."
          continue
        fi

        "$DUCKDB" -unsigned -bail "$RESULTS_DB" -c "
INSERT INTO results (version, benchmark, query_nr, run_nr, scale_factor, parser, latency_ms, parser_ms, relative_pct)
SELECT
    '${VERSION}'                      AS version,
    '${BENCHMARK}'                    AS benchmark,
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
}

# ── Outer loop: scale factors ─────────────────────────────────────────────────
for SCALE_FACTOR in $SCALE_FACTORS; do
  log "════════════════════════════════════════════"
  log "Scale factor: ${SCALE_FACTOR}"

  # TPC-H
  TPCH_DB="$DATA_DIR/tpch_sf${SCALE_FACTOR}.duckdb"
  if [[ ! -f "$TPCH_DB" ]]; then
    log "Generating TPC-H data SF=${SCALE_FACTOR} -> $TPCH_DB ..."
    "$DUCKDB" -unsigned "$TPCH_DB" -c "CALL dbgen(sf=${SCALE_FACTOR});"
    log "TPC-H data ready."
  else
    log "Reusing existing TPC-H database: $TPCH_DB"
  fi
  run_benchmark "tpch" "$TPCH_DB" 22 "tpch_queries"

  # TPC-DS — dsdgen does not support SF=0
  if [[ "$SCALE_FACTOR" == "0" ]]; then
    log "Skipping TPC-DS for SF=0 (dsdgen does not support it)"
  else
    TPCDS_DB="$DATA_DIR/tpcds_sf${SCALE_FACTOR}.duckdb"
    if [[ ! -f "$TPCDS_DB" ]]; then
      log "Generating TPC-DS data SF=${SCALE_FACTOR} -> $TPCDS_DB ..."
      "$DUCKDB" -unsigned "$TPCDS_DB" -c "CALL dsdgen(sf=${SCALE_FACTOR});"
      log "TPC-DS data ready."
    else
      log "Reusing existing TPC-DS database: $TPCDS_DB"
    fi
    run_benchmark "tpcds" "$TPCDS_DB" 99 "tpcds_queries"
  fi

done # scale factors

# ── Summary ───────────────────────────────────────────────────────────────────
log "══════════════════════════════════════════"
log "Summary — median across ${RUNS} runs, all scale factors"
"$DUCKDB" -unsigned -bail "$RESULTS_DB" -c "
SELECT
    benchmark,
    scale_factor,
    query_nr,
    parser,
    round(median(latency_ms),   6) AS median_latency_ms,
    round(median(parser_ms),    6) AS median_parser_ms,
    round(median(relative_pct), 4) AS median_relative_pct
FROM results
GROUP BY benchmark, scale_factor, query_nr, parser
ORDER BY benchmark, scale_factor, query_nr, parser;"

log "Results written to: $RESULTS_DB"
if [[ -s "$ERROR_LOG" ]]; then
  log "WARNING: some queries failed — see $ERROR_LOG"
fi
