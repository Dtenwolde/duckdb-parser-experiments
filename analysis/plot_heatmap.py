"""
Plot: Heatmap of median PEG parser overhead (%) per TPC-H query × scale factor.
Corresponds to the "Median latency and parser cost per (query, parser, SF)" query in queries.sql.

Usage:
    python analysis/plot_heatmap.py [results/benchmark_results.duckdb]
"""
import sys
import os
import duckdb
import pandas as pd
import matplotlib.pyplot as plt
import matplotlib.colors as mcolors

DB = sys.argv[1] if len(sys.argv) > 1 else "results/benchmark_results.duckdb"
OUT = "results/plots/heatmap_peg_overhead.png"

con = duckdb.connect(DB, read_only=True)
df = con.execute("""
    SELECT
        scale_factor,
        query_nr,
        round(median(relative_pct), 3) AS median_peg_pct
    FROM results
    WHERE parser = 'peg'
    GROUP BY ALL
    ORDER BY scale_factor, query_nr
""").df()
con.close()

pivot = df.pivot(index="query_nr", columns="scale_factor", values="median_peg_pct")
pivot = pivot.sort_index()

col_labels = [f"SF {v:g}" for v in pivot.columns]
row_labels = [f"Q{q}" for q in pivot.index]

BG = "#0a0a0f"
SURFACE = "#111118"
MUTED = "#64748b"
TEXT = "#e2e8f0"

# Custom colormap: dark surface → orange
cmap = mcolors.LinearSegmentedColormap.from_list(
    "peg_heat", ["#111118", "#7c2d12", "#f97316", "#fde68a"]
)

fig, ax = plt.subplots(figsize=(9, 8))
fig.patch.set_facecolor(BG)
ax.set_facecolor(SURFACE)

data = pivot.values
im = ax.imshow(data, cmap=cmap, aspect="auto")

ax.set_xticks(range(len(col_labels)))
ax.set_xticklabels(col_labels, color=TEXT, fontsize=10)
ax.set_yticks(range(len(row_labels)))
ax.set_yticklabels(row_labels, color=TEXT, fontsize=9)
ax.tick_params(length=0)

# Annotate cells
for r in range(data.shape[0]):
    for c in range(data.shape[1]):
        val = data[r, c]
        text_color = TEXT if val < data.max() * 0.6 else "#0a0a0f"
        ax.text(c, r, f"{val:.1f}%", ha="center", va="center",
                fontsize=7.5, color=text_color)

cbar = fig.colorbar(im, ax=ax, fraction=0.025, pad=0.02)
cbar.ax.yaxis.set_tick_params(color=MUTED)
cbar.set_label("Median PEG overhead (%)", color=MUTED, fontsize=9)
plt.setp(cbar.ax.yaxis.get_ticklabels(), color=MUTED)
cbar.outline.set_edgecolor("#1e1e2e")

ax.set_title("PEG parser overhead per query × scale factor", color=TEXT, fontsize=13, pad=14)
ax.spines[:].set_edgecolor("#1e1e2e")

os.makedirs("results/plots", exist_ok=True)
fig.tight_layout()
fig.savefig(OUT, dpi=150, facecolor=BG)
print(f"Saved {OUT}")
