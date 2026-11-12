#!/usr/bin/env bash
set -euo pipefail

# End-to-end parse share: parser time as a fraction of query latency, from DuckDB's profiler, for TPC-H and
# TPC-DS, with the PEG parser and with the PostgreSQL-derived legacy parser.
#
# The DuckDB binary must be built with tpch, tpcds and json, and with the legacy_parser extension, which is
# out of tree and pinned per DuckDB commit:
#
#   cd duckdb
#   GEN=ninja DUCKDB_EXTENSIONS='tpch;tpcds;json' \
#     EXTENSION_CONFIGS='.github/config/extensions/legacy_parser.cmake' make release
#
# Environment:
#   DUCKDB        binary to benchmark (default: duckdb/build/release/duckdb)
#   LEGACY_EXT    legacy_parser.duckdb_extension (default: next to the binary's build tree)
#   SFS           scale factors, e.g. SFS="0 0.1 1" (default)
#   RUNS          measured runs per (query, parser) (default 5)
#   WARMUP        1 (default): each measurement executes the query twice in one process and records the second
#                 execution, so parser and data caches are warm. 0: record the first execution of a fresh process.
#   PARSERS_LIST  parsers to run, default "postgres peg"
#   VERSION       label stored with the results (default: commit of the duckdb submodule)

# ── Configuration ─────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

DUCKDB="${DUCKDB:-$REPO_ROOT/duckdb/build/release/duckdb}"
LEGACY_EXT="${LEGACY_EXT:-$(dirname "$DUCKDB")/extension/legacy_parser/legacy_parser.duckdb_extension}"
SCALE_FACTORS="${SFS:-0 0.1 1}" # space-separated, e.g. SFS="1 10 100"
RESULTS_DB="${RESULTS_DB:-$REPO_ROOT/results/benchmark_results.duckdb}"
DATA_DIR="${DATA_DIR:-$REPO_ROOT/data}"
WORK_DIR="$REPO_ROOT/results/work"
PROFILING_JSON="$WORK_DIR/profiling.json"
QUERY_SQL="$WORK_DIR/query.sql"
ERROR_LOG="$REPO_ROOT/results/errors.log"
IFS=' ' read -r -a PARSERS <<< "${PARSERS_LIST:-postgres peg}"
RUNS="${RUNS:-5}"
WARMUP="${WARMUP:-1}"
VERSION="${VERSION:-$(git -C "$REPO_ROOT/duckdb" rev-parse --short HEAD 2>/dev/null || echo "unknown")}"

# ── Helpers ───────────────────────────────────────────────────────────────────
log() { echo "[$(date '+%H:%M:%S')] $*"; }
die() {
  echo "ERROR: $*" >&2
  exit 1
}
# -no-agent keeps the shell's output format independent of how the script is started
duck() { "$DUCKDB" -no-agent -unsigned "$@"; }

BUILD_HINT="Build it first:
  cd $REPO_ROOT/duckdb
  GEN=ninja DUCKDB_EXTENSIONS='tpch;tpcds;json' \\
    EXTENSION_CONFIGS='.github/config/extensions/legacy_parser.cmake' make release"

# The -cmd arguments that select a parser. The PEG parser is DuckDB's parser; the PostgreSQL-derived one is
# provided by the legacy_parser extension and takes over once enable_legacy_parser is set.
parser_args() {
  case "$1" in
  peg) ;;
  postgres)
    printf '%s\n' -cmd "LOAD '${LEGACY_EXT}';" -cmd "SET GLOBAL enable_legacy_parser = true;"
    ;;
  *) die "unknown parser '$1' (expected: peg, postgres)" ;;
  esac
}

# ── Pre-flight ────────────────────────────────────────────────────────────────
[[ -x "$DUCKDB" ]] || die "DuckDB binary not found at '$DUCKDB'.
$BUILD_HINT"

mkdir -p "$DATA_DIR" "$(dirname "$RESULTS_DB")" "$WORK_DIR"
: > "$ERROR_LOG" # truncate / create

duck -c "SELECT count(*) FROM tpch_queries(); SELECT count(*) FROM tpcds_queries();" >/dev/null 2>>"$ERROR_LOG" ||
  die "'$DUCKDB' has no tpch/tpcds extension.
$BUILD_HINT"

for PARSER in "${PARSERS[@]}"; do
  if [[ "$PARSER" == "postgres" ]]; then
    [[ -f "$LEGACY_EXT" ]] || die "legacy_parser extension not found at '$LEGACY_EXT'.
$BUILD_HINT"
    # make sure the 'postgres' rows cannot silently be PEG measurements: after enabling, the legacy parser must be
    # the strict parser override of the database
    PARSER_ARGS=()
    while IFS= read -r arg; do PARSER_ARGS+=("$arg"); done < <(parser_args postgres)
    STATE="$(duck "${PARSER_ARGS[@]}" -noheader -list -c "SELECT current_setting('enable_legacy_parser') || '/' || current_setting('allow_parser_override_extension');" 2>>"$ERROR_LOG" || true)"
    [[ "$STATE" == "true/strict" ]] || die "the legacy parser is not active after enabling it (state: '${STATE}')"
  fi
done

# ── Ensure results table exists ───────────────────────────────────────────────
duck "$RESULTS_DB" -c "
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
    relative_pct    DOUBLE,
    warmup          BOOLEAN
);
ALTER TABLE results ADD COLUMN IF NOT EXISTS version   VARCHAR;
ALTER TABLE results ADD COLUMN IF NOT EXISTS benchmark VARCHAR;
ALTER TABLE results ADD COLUMN IF NOT EXISTS warmup    BOOLEAN;"

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

  local TOTAL=$((QUERY_COUNT * ${#PARSERS[@]} * RUNS))
  local DONE=0

  for QUERY_NR in $QUERIES; do
    # The query text itself is what the shell executes. Wrapping it (FROM query(getvariable(...))) would make the
    # profiler report the parse time of the wrapper, because the inner text is parsed while binding.
    duck -noheader -list -c "SELECT rtrim(trim(query, E' \n\t'), ';') || ';' FROM ${QUERY_FN}() WHERE query_nr = ${QUERY_NR};" \
      >"$QUERY_SQL" 2>>"$ERROR_LOG"
    [[ -s "$QUERY_SQL" ]] || die "could not extract ${BENCHMARK} Q${QUERY_NR}"

    # runs are the outer loop so that the parsers alternate
    for RUN in $(seq 1 "$RUNS"); do
      for PARSER in "${PARSERS[@]}"; do
        DONE=$((DONE + 1))
        log "SF=${SCALE_FACTOR} ${BENCHMARK} [$DONE/$TOTAL] Q${QUERY_NR} | parser=${PARSER} | run=${RUN}/${RUNS}"

        PARSER_ARGS=()
        while IFS= read -r arg; do PARSER_ARGS+=("$arg"); done < <(parser_args "$PARSER")

        rm -f "$PROFILING_JSON"

        # the profile is rewritten after every statement, so the file holds the last execution
        if ! { [[ "$WARMUP" == "1" ]] && cat "$QUERY_SQL"; cat "$QUERY_SQL"; } |
          duck -readonly "$BENCH_DB" \
            ${PARSER_ARGS[@]+"${PARSER_ARGS[@]}"} \
            -cmd "SET enable_profiling = 'json';" \
            -cmd "SET profiling_mode = 'detailed';" \
            -cmd "SET profile_output = '${PROFILING_JSON}';" \
            -bail >/dev/null 2>>"$ERROR_LOG"; then
          log "WARNING: query failed for SF=${SCALE_FACTOR} ${BENCHMARK} Q${QUERY_NR} parser=${PARSER} run=${RUN} — see errors.log"
          continue
        fi

        if [[ ! -f "$PROFILING_JSON" ]]; then
          log "WARNING: profiling.json missing for SF=${SCALE_FACTOR} ${BENCHMARK} Q${QUERY_NR} parser=${PARSER} run=${RUN}, skipping."
          continue
        fi

        # the profiler reports seconds, per phase: {"query": {"total_time": ..}, "parser": {"total_time": ..}, ..}
        duck -bail "$RESULTS_DB" -c "
INSERT INTO results (version, benchmark, query_nr, run_nr, scale_factor, parser, latency_ms, parser_ms, relative_pct, warmup)
SELECT
    '${VERSION}'                              AS version,
    '${BENCHMARK}'                            AS benchmark,
    ${QUERY_NR}                               AS query_nr,
    ${RUN}                                    AS run_nr,
    ${SCALE_FACTOR}                           AS scale_factor,
    '${PARSER}'                               AS parser,
    latency_s * 1000                          AS latency_ms,
    parser_s * 1000                           AS parser_ms,
    round(parser_s / latency_s * 100, 4)      AS relative_pct,
    ${WARMUP} = 1                             AS warmup
FROM (
    SELECT json_extract(content, '\$.query.total_time')::DOUBLE  AS latency_s,
           json_extract(content, '\$.parser.total_time')::DOUBLE AS parser_s
    FROM read_text('${PROFILING_JSON}')
);"

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
    duck "$TPCH_DB" -c "CALL dbgen(sf=${SCALE_FACTOR});"
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
      duck "$TPCDS_DB" -c "CALL dsdgen(sf=${SCALE_FACTOR});"
      log "TPC-DS data ready."
    else
      log "Reusing existing TPC-DS database: $TPCDS_DB"
    fi
    run_benchmark "tpcds" "$TPCDS_DB" 99 "tpcds_queries"
  fi

done # scale factors

# ── Summary ───────────────────────────────────────────────────────────────────
log "══════════════════════════════════════════"
log "Summary for version '${VERSION}' — median across runs"
duck -bail "$RESULTS_DB" -c "
SELECT
    benchmark,
    scale_factor,
    parser,
    count(DISTINCT query_nr)                       AS queries,
    round(sum(median_latency_ms), 3)               AS total_latency_ms,
    round(sum(median_parser_ms), 3)                AS total_parser_ms,
    round(median(median_relative_pct), 3)          AS median_parse_share_pct,
    round(max(median_relative_pct), 3)             AS max_parse_share_pct
FROM (
    SELECT benchmark, scale_factor, query_nr, parser,
           median(latency_ms) AS median_latency_ms,
           median(parser_ms) AS median_parser_ms,
           median(relative_pct) AS median_relative_pct
    FROM results
    WHERE version = '${VERSION}'
    GROUP BY ALL
)
GROUP BY ALL
ORDER BY benchmark, scale_factor, parser;"

log "Results written to: $RESULTS_DB"
if [[ -s "$ERROR_LOG" ]]; then
  log "WARNING: some queries failed — see $ERROR_LOG"
fi
