"""
Plot: Average parser overhead (%) by parser and scale factor — TPC-H and TPC-DS side by side.

Usage:
    python analysis/plot_overview.py [results/benchmark_results.duckdb] [version]

    version – git short-hash or label (default: most recent in DB)
"""
import sys
import os
import duckdb
import matplotlib.pyplot as plt

DB  = sys.argv[1] if len(sys.argv) > 1 else "results/benchmark_results.duckdb"

con = duckdb.connect(DB, read_only=True)

VERSION = sys.argv[2] if len(sys.argv) > 2 else con.execute(
    "SELECT version FROM results WHERE version IS NOT NULL ORDER BY run_at DESC LIMIT 1"
).fetchone()[0]

OUT = f"results/plots/overview_{VERSION}.png"

df = con.execute(f"""
    SELECT benchmark, parser, printf('SF %g', scale_factor) AS sf_label, scale_factor,
           round(avg(relative_pct), 4) AS avg_pct
    FROM results
    WHERE scale_factor > 0 AND version = '{VERSION}'
    GROUP BY ALL
    ORDER BY benchmark, scale_factor, parser
""").df()
con.close()

PEG_COLOR = "#f97316"
PG_COLOR  = "#38bdf8"
BG        = "#0a0a0f"
SURFACE   = "#111118"
MUTED     = "#475569"
TEXT      = "#e2e8f0"

benchmarks = sorted(df["benchmark"].unique())
fig, axes = plt.subplots(1, len(benchmarks), figsize=(9 * len(benchmarks), 5), sharey=True)
fig.patch.set_facecolor(BG)
if len(benchmarks) == 1:
    axes = [axes]

for ax, bm in zip(axes, benchmarks):
    ax.set_facecolor(SURFACE)
    sub = df[df["benchmark"] == bm]

    sf_order = (
        sub[["sf_label", "scale_factor"]]
        .drop_duplicates()
        .sort_values("scale_factor")
        ["sf_label"]
        .tolist()
    )
    x_pos   = list(range(len(sf_order)))
    sf_to_x = {sf: i for i, sf in enumerate(sf_order)}

    for parser, color, label in [("peg", PEG_COLOR, "PEG parser"), ("postgres", PG_COLOR, "PostgreSQL parser")]:
        d  = sub[sub["parser"] == parser].sort_values("scale_factor")
        xs = [sf_to_x[sf] for sf in d["sf_label"]]
        ax.plot(xs, d["avg_pct"], color=color, linewidth=2.5,
                marker="o", markersize=6, label=label, zorder=3)
        ax.fill_between(xs, d["avg_pct"], alpha=0.07, color=color)
        for x, (_, row) in zip(xs, d.iterrows()):
            ax.annotate(f"{row['avg_pct']:.2f}%",
                        (x, row["avg_pct"]),
                        textcoords="offset points", xytext=(0, 10),
                        ha="center", fontsize=8.5, color=color, alpha=0.9)

    ax.set_xticks(x_pos)
    ax.set_xticklabels(sf_order)
    ax.set_xlabel("Scale Factor", color=MUTED, fontsize=10)
    ax.set_ylabel("Parser overhead (% of latency)", color=MUTED, fontsize=10)
    ax.set_title(f"Avg. parser time / total latency  ·  {bm.upper()}  ·  {VERSION}", color=TEXT, fontsize=13, pad=14)
    ax.tick_params(colors=MUTED)
    for spine in ax.spines.values():
        spine.set_edgecolor("#1e1e2e")
    ax.grid(True, color="#1a1a2e", linestyle="--", linewidth=0.7, zorder=0)
    ax.legend(facecolor=SURFACE, edgecolor="#1e1e2e", labelcolor=TEXT, fontsize=10)

os.makedirs("results/plots", exist_ok=True)
fig.tight_layout()
fig.savefig(OUT, dpi=150, facecolor=BG)
print(f"Saved {OUT}")
