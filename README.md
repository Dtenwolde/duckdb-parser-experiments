# duckdb-parser-experiments

Benchmarking the PEG parser against the PostgreSQL parser in DuckDB, across TPC-H queries and multiple scale factors.

## Repository structure

```
duckdb-parser-experiments/
├── duckdb/                  # Git submodule — DuckDB source
├── scripts/
│   ├── benchmark.sh         # Main benchmark runner
│   └── plot.html            # Interactive results visualisation
├── data/                    # Generated TPC-H databases (gitignored, reproduced by benchmark.sh)
├── results/                 # benchmark_results.duckdb + exported CSVs (gitignored by default)
├── analysis/                # Ad-hoc SQL queries and notes
└── README.md
```

## Reproducibility

### 1. Clone with submodule

```bash
# Using your fork of DuckDB
git clone --recurse-submodules git@github.com:dtenwolde/duckdb-parser-experiments.git
cd duckdb-parser-experiments

# Or if you already cloned without --recurse-submodules
git submodule update --init --recursive
```

### 2. Point submodule at the right remote

The submodule is configured to track `dtenwolde/duckdb` by default.
To switch to upstream:

```bash
cd duckdb
git remote set-url origin https://github.com/duckdb/duckdb.git
git fetch origin
git checkout main
cd ..
```

### 3. Build DuckDB

```bash
cd duckdb
DUCKDB_EXTENSIONS="tpch;json" make -j$(nproc)
cd ..
```

The benchmark script expects the binary at `duckdb/build/release/duckdb`.

### 4. Run benchmarks

```bash
# Defaults: SF=0.1 1 10 30, 5 runs per (query, parser), all 22 TPC-H queries
./scripts/benchmark.sh

# Custom configuration via env vars
SFS="1 10" RUNS=10 ./scripts/benchmark.sh
DUCKDB=./duckdb/build/release/duckdb RESULTS_DB=results/benchmark_results.duckdb ./scripts/benchmark.sh
```

### 5. Explore results

```bash
# Quick summary
duckdb results/benchmark_results.duckdb -c "
SELECT parser, round(avg(relative_pct),3) AS avg_pct, scale_factor
FROM results
GROUP BY ALL
ORDER BY scale_factor;"

# Open the interactive plot
open scripts/plot.html
```

## Environment

Record your environment when publishing results:

```bash
./duckdb/build/release/duckdb -c "SELECT version();"
uname -a
# CPU, RAM, storage type
```

## Configuration reference

| Env var      | Default                          | Description                        |
|------------- |----------------------------------|------------------------------------|
| `DUCKDB`     | `./duckdb/build/release/duckdb`  | Path to DuckDB binary              |
| `SFS`        | `0.1 1 10 30`                    | Space-separated scale factors      |
| `RUNS`       | `5`                              | Repeated runs per (query, parser)  |
| `RESULTS_DB` | `results/benchmark_results.duckdb` | Output DuckDB database           |

## Schema

Results are stored in a single DuckDB table:

```sql
CREATE TABLE results (
    run_at       TIMESTAMPTZ,   -- wall-clock time of the run
    query_nr     INTEGER,       -- TPC-H query number (1–22)
    run_nr       INTEGER,       -- repetition index within a (query, parser, SF) group
    scale_factor DOUBLE,        -- TPC-H scale factor
    parser       VARCHAR,       -- 'peg' or 'postgres'
    latency_ms   DOUBLE,        -- total query latency (ms)
    parser_ms    DOUBLE,        -- time spent in parser (ms)
    relative_pct DOUBLE         -- parser_ms / latency_ms * 100
);
```

## Submodule remotes

| Remote   | URL                                          |
|----------|----------------------------------------------|
| `origin` | `git@github.com:dtenwolde/duckdb.git`        |
| `upstream` | `git@github.com:duckdb/duckdb.git`         |

To add `upstream` after cloning:

```bash
cd duckdb
git remote add upstream https://github.com/duckdb/duckdb.git
```
