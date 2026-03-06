-- analysis/queries.sql
-- Useful queries for exploring benchmark_results.duckdb
-- Run with: duckdb results/benchmark_results.duckdb

-- ── Overview ──────────────────────────────────────────────────────────────────

-- Average parser overhead by parser and scale factor
SELECT parser, scale_factor, round(avg(relative_pct), 4) AS avg_pct
FROM results
GROUP BY ALL
ORDER BY scale_factor, parser;

-- ── Per-query breakdown ───────────────────────────────────────────────────────

-- Median latency and parser cost per (query, parser, SF)
SELECT
    scale_factor,
    query_nr,
    parser,
    round(median(latency_ms),   6) AS median_latency_ms,
    round(median(parser_ms),    6) AS median_parser_ms,
    round(median(relative_pct), 4) AS median_relative_pct
FROM results
GROUP BY ALL
ORDER BY scale_factor, query_nr, parser;

-- Queries where PEG overhead is highest (at SF=1)
SELECT
    query_nr,
    round(median(relative_pct), 3) AS median_peg_pct,
    round(median(latency_ms),   3) AS median_latency_ms
FROM results
WHERE parser = 'peg' AND scale_factor = 1.0
GROUP BY query_nr
ORDER BY median_peg_pct DESC;

-- ── Parser comparison ─────────────────────────────────────────────────────────

-- PEG / postgres ratio per scale factor
WITH agg AS (
    SELECT scale_factor, parser, median(relative_pct) AS med
    FROM results GROUP BY ALL
)
SELECT
    scale_factor,
    round(MAX(CASE WHEN parser='peg'      THEN med END), 4) AS peg_pct,
    round(MAX(CASE WHEN parser='postgres' THEN med END), 4) AS postgres_pct,
    round(
        MAX(CASE WHEN parser='peg' THEN med END) /
        MAX(CASE WHEN parser='postgres' THEN med END)
    , 1) AS peg_postgres_ratio
FROM agg
GROUP BY scale_factor
ORDER BY scale_factor;

-- ── Variance / stability ──────────────────────────────────────────────────────

-- Coefficient of variation (stddev/mean) — higher = less stable
SELECT
    parser,
    scale_factor,
    query_nr,
    round(stddev(relative_pct) / mean(relative_pct) * 100, 2) AS cv_pct
FROM results
GROUP BY ALL
HAVING count(*) > 1
ORDER BY cv_pct DESC
LIMIT 20;

-- ── Export ────────────────────────────────────────────────────────────────────

-- Export summary to CSV (uncomment to run)
-- COPY (
--     SELECT scale_factor, query_nr, parser,
--            round(median(latency_ms),   6) AS median_latency_ms,
--            round(median(parser_ms),    6) AS median_parser_ms,
--            round(median(relative_pct), 4) AS median_relative_pct
--     FROM results GROUP BY ALL ORDER BY scale_factor, query_nr, parser
-- ) TO 'results/summary.csv' (HEADER, DELIMITER ',');
