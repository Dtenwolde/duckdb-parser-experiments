"""
Plot: Raw timings per query, grouped by scale factor — TPC-H and TPC-DS.

Two row-blocks, one per benchmark:
  Top row of each block    – total query latency (ms)
  Bottom row of each block – parser time only (µs)

TPC-H shows all 22 queries; TPC-DS shows the top TOP_N queries by median latency.
The version label (duckdb git commit hash) is embedded in the figure.

Usage:
    python analysis/plot_raw_timings.py [results/benchmark_results.duckdb] [version]

    version – git short-hash or label (default: most recent in DB)
"""
import sys
import os
import duckdb
import matplotlib.pyplot as plt
import matplotlib.gridspec as gridspec
import matplotlib.ticker as ticker
import numpy as np

DB  = sys.argv[1] if len(sys.argv) > 1 else "results/benchmark_results.duckdb"
OUT = "results/plots/raw_timings.png"

TOP_N_TPCDS = 20

con = duckdb.connect(DB, read_only=True)

VERSION = sys.argv[2] if len(sys.argv) > 2 else con.execute(
    "SELECT version FROM results WHERE version IS NOT NULL ORDER BY run_at DESC LIMIT 1"
).fetchone()[0]

def fetch(benchmark, top_n=None):
    limit_clause = f"AND query_nr IN (SELECT query_nr FROM results WHERE benchmark = '{benchmark}' AND scale_factor > 0 AND version = '{VERSION}' GROUP BY query_nr ORDER BY median(latency_ms) DESC LIMIT {top_n})" if top_n else ""
    return con.execute(f"""
        SELECT printf('SF %g', scale_factor) AS sf_label,
               scale_factor, query_nr, parser,
               round(median(latency_ms),       4) AS median_latency_ms,
               round(median(parser_ms) * 1000, 4) AS median_parser_us
        FROM results
        WHERE scale_factor > 0 AND benchmark = '{benchmark}' AND version = '{VERSION}'
        {limit_clause}
        GROUP BY scale_factor, query_nr, parser
        ORDER BY scale_factor, query_nr, parser
    """).df()

df_tpch  = fetch("tpch")
df_tpcds = fetch("tpcds", top_n=TOP_N_TPCDS)
con.close()

def sf_order(df):
    return (
        df[["sf_label", "scale_factor"]].drop_duplicates()
        .sort_values("scale_factor")["sf_label"].tolist()
    )

blocks = [(df_tpch, "TPC-H  ·  all queries"),
          (df_tpcds, f"TPC-DS  ·  top {TOP_N_TPCDS} by latency")]
blocks = [(d, t) for d, t in blocks if not d.empty]

PEG_COLOR = "#f97316"
PG_COLOR  = "#38bdf8"
BG        = "#0a0a0f"
SURFACE   = "#111118"
MUTED     = "#475569"
TEXT      = "#e2e8f0"

row_meta = [
    ("median_latency_ms", "Total query latency (ms)",
     ticker.FuncFormatter(lambda v, _: f"{v:,.0f}" if v >= 1 else f"{v:.3f}")),
    ("median_parser_us",  "Parser time (µs)",
     ticker.FuncFormatter(lambda v, _: f"{v:.2f}")),
]

n_blocks  = len(blocks)
block_sfs = [sf_order(d) for d, _ in blocks]
max_n_sf  = max(len(s) for s in block_sfs)

fig = plt.figure(figsize=(5 * max_n_sf, 4.5 * 2 * n_blocks), constrained_layout=True)
fig.patch.set_facecolor(BG)
fig.suptitle(f"Raw timings per query  ·  version {VERSION}",
             color=TEXT, fontsize=13, y=1.01)

outer = gridspec.GridSpec(n_blocks, 1, figure=fig, hspace=0.45)

for block_idx, ((df, bm_title), sfs) in enumerate(zip(blocks, block_sfs)):
    inner = gridspec.GridSpecFromSubplotSpec(
        2, len(sfs), subplot_spec=outer[block_idx], hspace=0.05, wspace=0.3
    )
    queries = sorted(df["query_nr"].unique())
    x = np.arange(len(queries))
    w = 0.38

    for row, (col_key, ylabel, fmt) in enumerate(row_meta):
        for col_idx, sf_label in enumerate(sfs):
            ax = fig.add_subplot(inner[row, col_idx])
            ax.set_facecolor(SURFACE)
            sub = df[df["sf_label"] == sf_label]

            peg_vals = sub[sub["parser"] == "peg"].set_index("query_nr").reindex(queries)[col_key].fillna(0)
            pg_vals  = sub[sub["parser"] == "postgres"].set_index("query_nr").reindex(queries)[col_key].fillna(0)

            ax.bar(x - w/2, peg_vals, width=w, color=PEG_COLOR, label="PEG",      edgecolor="none", alpha=0.85)
            ax.bar(x + w/2, pg_vals,  width=w, color=PG_COLOR,  label="Postgres", edgecolor="none", alpha=0.85)

            ax.set_xticks(x)
            ax.set_xticklabels([f"Q{q}" for q in queries], rotation=45, ha="right", fontsize=7, color=MUTED)
            ax.tick_params(colors=MUTED)
            for spine in ax.spines.values():
                spine.set_edgecolor("#1e1e2e")
            ax.grid(True, axis="y", color="#1a1a2e", linestyle="--", linewidth=0.7, zorder=0)
            ax.yaxis.set_major_formatter(fmt)

            if row == 0:
                title = f"{sf_label}"
                if col_idx == 0:
                    title = f"{bm_title}  ·  {sf_label}"
                ax.set_title(title, color=TEXT, fontsize=10, pad=8)
            if col_idx == 0:
                ax.set_ylabel(ylabel, color=MUTED, fontsize=9)
            if row == 1:
                ax.set_xlabel("Query", color=MUTED, fontsize=9)
            if row == 0 and col_idx == len(sfs) - 1:
                ax.legend(facecolor=SURFACE, edgecolor="#1e1e2e", labelcolor=TEXT, fontsize=8)

os.makedirs("results/plots", exist_ok=True)
fig.savefig(OUT, dpi=150, facecolor=BG, bbox_inches="tight")
print(f"Saved {OUT}")
