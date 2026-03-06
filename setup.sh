#!/usr/bin/env bash
# setup.sh — one-shot setup for a fresh clone
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "==> Initialising submodule..."
git submodule update --init --recursive

echo "==> Adding upstream remote to submodule..."
cd duckdb
if ! git remote | grep -q upstream; then
  git remote add upstream https://github.com/duckdb/duckdb.git
  echo "    Added remote 'upstream' -> duckdb/duckdb"
else
  echo "    Remote 'upstream' already exists"
fi
cd ..

echo "==> Building DuckDB (tpch + json extensions)..."
cd duckdb
DUCKDB_EXTENSIONS="tpch;json" make -j"$(nproc 2>/dev/null || sysctl -n hw.logicalcpu)"
cd ..

echo ""
echo "Done! Run benchmarks with:"
echo "  ./scripts/benchmark.sh"
echo ""
echo "Override defaults with env vars:"
echo "  SFS='1 10' RUNS=10 ./scripts/benchmark.sh"
