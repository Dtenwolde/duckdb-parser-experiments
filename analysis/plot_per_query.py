"""
Plot: PEG parser overhead per query, sorted highest to lowest.
TPC-H shows all 22 queries; TPC-DS shows the top TOP_N queries by PEG overhead.

Usage:
    python analysis/plot_per_query.py [results/benchmark_results.duckdb] [scale_factor] [version]

    scale_factor – default: 1.0
    version      – git short-hash or label (default: most recent in DB)
"""
import sys
import os
import duckdb
import matplotlib.pyplot as plt

DB  = sys.argv[1] if len(sys.argv) > 1 else "results/benchmark_results.duckdb"
SF  = float(sys.argv[2]) if len(sys.argv) > 2 else 1.0

TOP_N_TPCDS = 20

con = duckdb.connect(DB, read_only=True)

VERSION = sys.argv[3] if len(sys.argv) > 3 else con.execute(
    "SELECT version FROM results WHERE version IS NOT NULL ORDER BY run_at DESC LIMIT 1"
).fetchone()[0]

OUT = f"results/plots/per_query_peg_{VERSION}.png"

df_tpch = con.execute(f"""
    SELECT query_nr,
           round(median(relative_pct), 3) AS median_peg_pct
    FROM results
    WHERE parser = 'peg' AND scale_factor = ? AND benchmark = 'tpch' AND version = '{VERSION}'
    GROUP BY query_nr
    ORDER BY median_peg_pct DESC
""", [SF]).df()

df_tpcds = con.execute(f"""
    SELECT query_nr,
           round(median(relative_pct), 3) AS median_peg_pct
    FROM results
    WHERE parser = 'peg' AND scale_factor = ? AND benchmark = 'tpcds' AND version = '{VERSION}'
    GROUP BY query_nr
    ORDER BY median_peg_pct DESC
    LIMIT ?
""", [SF, TOP_N_TPCDS]).df()

con.close()

PEG_COLOR = "#f97316"
BG        = "#0a0a0f"
SURFACE   = "#111118"
MUTED     = "#475569"
TEXT      = "#e2e8f0"

panels = [
    (df_tpch,  f"TPC-H  ·  SF {SF:g}  ·  all {len(df_tpch)} queries  ·  {VERSION}"),
    (df_tpcds, f"TPC-DS  ·  SF {SF:g}  ·  top {TOP_N_TPCDS} by PEG overhead  ·  {VERSION}"),
]
# Only include panels that have data
panels = [(d, t) for d, t in panels if not d.empty]

fig, axes = plt.subplots(1, len(panels), figsize=(8 * len(panels), 8))
fig.patch.set_facecolor(BG)
if len(panels) == 1:
    axes = [axes]

for ax, (df, title) in zip(axes, panels):
    ax.set_facecolor(SURFACE)
    max_pct = df["median_peg_pct"].max()
    colors = [plt.matplotlib.colors.to_rgba(PEG_COLOR, alpha=0.4 + 0.6 * (v / max_pct))
              for v in df["median_peg_pct"]]

    labels = [f"Q{q}" for q in df["query_nr"]]
    bars   = ax.barh(labels, df["median_peg_pct"], color=colors, edgecolor="none", height=0.7)

    for bar, val in zip(bars, df["median_peg_pct"]):
        ax.text(bar.get_width() + 0.05, bar.get_y() + bar.get_height() / 2,
                f"{val:.2f}%", va="center", fontsize=8.5, color=PEG_COLOR)

    ax.invert_yaxis()
    ax.set_xlabel("Median PEG parser overhead (% of latency)", color=MUTED, fontsize=10)
    ax.set_title(title, color=TEXT, fontsize=12, pad=14)
    ax.tick_params(colors=MUTED)
    ax.spines["top"].set_visible(False)
    ax.spines["right"].set_visible(False)
    for spine in ax.spines.values():
        spine.set_edgecolor("#1e1e2e")
    ax.grid(True, axis="x", color="#1a1a2e", linestyle="--", linewidth=0.7, zorder=0)

os.makedirs("results/plots", exist_ok=True)
fig.tight_layout()
fig.savefig(OUT, dpi=150, facecolor=BG)
print(f"Saved {OUT}")
