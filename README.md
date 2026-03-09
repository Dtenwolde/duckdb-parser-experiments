# duckdb-parser-experiments

Benchmarking the PEG parser against the PostgreSQL parser in DuckDB, across TPC-H and TPC-DS queries at multiple scale factors.

## Repository structure

```
duckdb-parser-experiments/
├── duckdb/                  # Git submodule — DuckDB source
├── scripts/
│   ├── benchmark_parser.sh  # Main benchmark runner
│   └── plot.html            # Interactive results visualisation
├── data/                    # Generated TPC-H/TPC-DS databases (gitignored)
├── results/                 # benchmark_results.duckdb, errors.log (gitignored by default)
├── analysis/                # Plot scripts and ad-hoc SQL queries
└── README.md
```

## Reproducibility

### 1. Clone with submodule

```bash
git clone --recurse-submodules git@github.com:dtenwolde/duckdb-parser-experiments.git
cd duckdb-parser-experiments

# Or if you already cloned without --recurse-submodules
git submodule update --init --recursive
```

### 2. Point submodule at the right remote

The submodule tracks `dtenwolde/duckdb` by default.  To switch to upstream:

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
DUCKDB_EXTENSIONS="tpch;tpcds;json;autocomplete" make -j$(nproc)
cd ..
```

The benchmark script expects the binary at `duckdb/build/release/duckdb`.

### 4. Run benchmarks

```bash
# Defaults: SF=0 0.1 1, 5 runs per (query, parser, SF)
# Runs both TPC-H (22 queries) and TPC-DS (99 queries; SF=0 skipped)
./scripts/benchmark_parser.sh

# Custom configuration via env vars
SFS="1 10 30" RUNS=10 ./scripts/benchmark_parser.sh
DUCKDB=./duckdb/build/release/duckdb SFS="0.1 1" ./scripts/benchmark_parser.sh

# Pin a version label (defaults to the duckdb submodule's git short-hash)
VERSION=baseline ./scripts/benchmark_parser.sh
```

Any queries that fail (e.g. unsupported syntax in the PEG parser) are skipped and their errors are written to `results/errors.log`.

### 5. Generate plots

```bash
source .venv/bin/activate  # or: pip install -r requirements.txt

python analysis/plot_overview.py
python analysis/plot_raw_timings.py
python analysis/plot_per_query.py
python analysis/plot_ratio.py
python analysis/plot_heatmap.py
```

Each script accepts an optional DB path and version label:

```bash
python analysis/plot_raw_timings.py results/benchmark_results.duckdb 9ebda86e9f
python analysis/plot_per_query.py   results/benchmark_results.duckdb 10.0
```

Plots are saved to `results/plots/`.

#### Plot contents

Every plot shows both TPC-H and TPC-DS side by side. TPC-DS has 99 queries, so
query-level plots cap it at the most informative subset to stay readable.

| Plot | TPC-H | TPC-DS |
|---|---|---|
| `plot_overview` | avg overhead % across all queries, per SF | same |
| `plot_ratio` | PEG/Postgres ratio + absolute overhead per SF | same |
| `plot_per_query` | all 22 queries, sorted by PEG overhead | top 20 by PEG overhead |
| `plot_heatmap` | all 22 queries × all SFs | top 20 by PEG overhead × available SFs |
| `plot_raw_timings` | all 22 queries × all SFs (total latency + parser time) | top 20 by median latency × available SFs |

### 6. Explore results

```bash
# Quick summary grouped by benchmark and scale factor
duckdb results/benchmark_results.duckdb -c "
SELECT benchmark, printf('SF %g', scale_factor) AS sf, parser,
       round(avg(relative_pct), 3) AS avg_overhead_pct
FROM results
GROUP BY benchmark, scale_factor, parser
ORDER BY benchmark, scale_factor, parser;"
```

## Environment

Record your environment when publishing results:

```bash
./duckdb/build/release/duckdb -c "SELECT version();"
uname -a
# CPU, RAM, storage type
```

## Configuration reference

| Env var      | Default                              | Description                                        |
|--------------|--------------------------------------|----------------------------------------------------|
| `DUCKDB`     | `./duckdb/build/release/duckdb`      | Path to DuckDB binary                              |
| `SFS`        | `0 0.1 1`                            | Space-separated scale factors                      |
| `RUNS`       | `5`                                  | Repeated runs per (query, parser, SF)              |
| `RESULTS_DB` | `results/benchmark_results.duckdb`   | Output DuckDB database                             |
| `VERSION`    | git short-hash of duckdb submodule   | Label attached to every row for tracking over time |

## Schema

Results are stored in a single DuckDB table:

```sql
CREATE TABLE results (
    run_at       TIMESTAMPTZ,   -- wall-clock time of the run
    version      VARCHAR,       -- duckdb git short-hash (or VERSION env var)
    benchmark    VARCHAR,       -- 'tpch' or 'tpcds'
    query_nr     INTEGER,       -- query number within the benchmark
    run_nr       INTEGER,       -- repetition index within a (query, parser, SF) group
    scale_factor DOUBLE,        -- scale factor (TPC-DS skips SF=0)
    parser       VARCHAR,       -- 'peg' or 'postgres'
    latency_ms   DOUBLE,        -- total query latency (ms)
    parser_ms    DOUBLE,        -- time spent in parser (ms)
    relative_pct DOUBLE         -- parser_ms / latency_ms * 100
);
```

## Submodule remotes

| Remote     | URL                                        |
|------------|--------------------------------------------|
| `origin`   | `git@github.com:dtenwolde/duckdb.git`      |
| `upstream` | `git@github.com:duckdb/duckdb.git`         |

To add `upstream` after cloning:

```bash
cd duckdb
git remote add upstream https://github.com/duckdb/duckdb.git
```
