"""
Plot: PEG / PostgreSQL parser overhead ratio by scale factor — TPC-H and TPC-DS side by side.

Usage:
    python analysis/plot_ratio.py [results/benchmark_results.duckdb]
"""
import sys
import os
import duckdb
import matplotlib.pyplot as plt

DB  = sys.argv[1] if len(sys.argv) > 1 else "results/benchmark_results.duckdb"
OUT = "results/plots/peg_postgres_ratio.png"

con = duckdb.connect(DB, read_only=True)
df = con.execute("""
    WITH agg AS (
        SELECT benchmark, scale_factor, parser, median(relative_pct) AS med
        FROM results
        GROUP BY benchmark, scale_factor, parser
    )
    SELECT
        benchmark,
        printf('SF %g', scale_factor) AS sf_label,
        scale_factor,
        round(MAX(CASE WHEN parser='peg'      THEN med END), 4) AS peg_pct,
        round(MAX(CASE WHEN parser='postgres' THEN med END), 4) AS postgres_pct,
        round(
            MAX(CASE WHEN parser='peg' THEN med END) /
            NULLIF(MAX(CASE WHEN parser='postgres' THEN med END), 0)
        , 1) AS peg_postgres_ratio
    FROM agg
    GROUP BY benchmark, scale_factor
    ORDER BY benchmark, scale_factor
""").df()
con.close()

RATIO_COLOR = "#a78bfa"
BG      = "#0a0a0f"
SURFACE = "#111118"
MUTED   = "#475569"
TEXT    = "#e2e8f0"

benchmarks = sorted(df["benchmark"].unique())
fig, axes = plt.subplots(2, len(benchmarks), figsize=(7 * len(benchmarks), 9))
fig.patch.set_facecolor(BG)
if len(benchmarks) == 1:
    axes = axes.reshape(2, 1)

for col, bm in enumerate(benchmarks):
    sub = df[df["benchmark"] == bm].sort_values("scale_factor")
    sf_labels = sub["sf_label"].tolist()
    x = range(len(sf_labels))
    w = 0.35

    # Row 0: ratio
    ax = axes[0][col]
    ax.set_facecolor(SURFACE)
    bars = ax.bar(sf_labels, sub["peg_postgres_ratio"], color=RATIO_COLOR, edgecolor="none", width=0.55)
    for bar, val in zip(bars, sub["peg_postgres_ratio"]):
        ax.text(bar.get_x() + bar.get_width() / 2, bar.get_height() + 1,
                f"{val:.0f}×", ha="center", fontsize=9, color=RATIO_COLOR)
    ax.set_ylabel("Ratio (PEG / Postgres overhead)", color=MUTED, fontsize=10)
    ax.set_title(f"PEG vs Postgres overhead ratio  ·  {bm.upper()}", color=TEXT, fontsize=12, pad=12)
    ax.tick_params(colors=MUTED)
    for spine in ax.spines.values():
        spine.set_edgecolor("#1e1e2e")
    ax.grid(True, axis="y", color="#1a1a2e", linestyle="--", linewidth=0.7, zorder=0)

    # Row 1: absolute overhead side-by-side
    ax2 = axes[1][col]
    ax2.set_facecolor(SURFACE)
    ax2.bar([i - w/2 for i in x], sub["peg_pct"],     width=w, color="#f97316", label="PEG",      edgecolor="none")
    ax2.bar([i + w/2 for i in x], sub["postgres_pct"], width=w, color="#38bdf8", label="Postgres", edgecolor="none")
    ax2.set_xticks(list(x))
    ax2.set_xticklabels(sf_labels)
    ax2.set_ylabel("Median overhead (% of latency)", color=MUTED, fontsize=10)
    ax2.set_title(f"Absolute overhead by scale factor  ·  {bm.upper()}", color=TEXT, fontsize=12, pad=12)
    ax2.tick_params(colors=MUTED)
    for spine in ax2.spines.values():
        spine.set_edgecolor("#1e1e2e")
    ax2.grid(True, axis="y", color="#1a1a2e", linestyle="--", linewidth=0.7, zorder=0)
    ax2.legend(facecolor=SURFACE, edgecolor="#1e1e2e", labelcolor=TEXT, fontsize=10)

os.makedirs("results/plots", exist_ok=True)
fig.tight_layout()
fig.savefig(OUT, dpi=150, facecolor=BG)
print(f"Saved {OUT}")
