"""
Plot: Average parser overhead (%) by parser and scale factor.
Corresponds to the "Average parser overhead" query in queries.sql.

Usage:
    python analysis/plot_overview.py [results/benchmark_results.duckdb]
"""
import sys
import duckdb
import matplotlib.pyplot as plt

DB = sys.argv[1] if len(sys.argv) > 1 else "results/benchmark_results.duckdb"
OUT = "results/plots/overview.png"

con = duckdb.connect(DB, read_only=True)
df = con.execute("""
    SELECT parser, scale_factor, round(avg(relative_pct), 4) AS avg_pct
    FROM results
    WHERE scale_factor > 0
    GROUP BY ALL
    ORDER BY scale_factor, parser
""").df()
con.close()

PEG_COLOR = "#f97316"
PG_COLOR = "#38bdf8"
BG = "#0a0a0f"
SURFACE = "#111118"
MUTED = "#475569"
TEXT = "#e2e8f0"

fig, ax = plt.subplots(figsize=(9, 5))
fig.patch.set_facecolor(BG)
ax.set_facecolor(SURFACE)

sfs = sorted(df["scale_factor"].unique())
sf_labels = [f"SF {v:g}" for v in sfs]
x_pos = list(range(len(sfs)))
sf_to_x = {sf: i for i, sf in enumerate(sfs)}

for parser, color, label in [("peg", PEG_COLOR, "PEG parser"), ("postgres", PG_COLOR, "PostgreSQL parser")]:
    d = df[df["parser"] == parser].sort_values("scale_factor")
    xs = [sf_to_x[sf] for sf in d["scale_factor"]]
    ax.plot(xs, d["avg_pct"], color=color, linewidth=2.5,
            marker="o", markersize=6, label=label, zorder=3)
    ax.fill_between(xs, d["avg_pct"], alpha=0.07, color=color)
    for x, (_, row) in zip(xs, d.iterrows()):
        ax.annotate(f"{row['avg_pct']:.2f}%",
                    (x, row["avg_pct"]),
                    textcoords="offset points", xytext=(0, 10),
                    ha="center", fontsize=8.5, color=color, alpha=0.9)

ax.set_xticks(x_pos)
ax.set_xticklabels(sf_labels)
ax.set_xlabel("Scale Factor", color=MUTED, fontsize=10)
ax.set_ylabel("Parser overhead (% of latency)", color=MUTED, fontsize=10)
ax.set_title("Avg. parser time / total latency", color=TEXT, fontsize=13, pad=14)

ax.tick_params(colors=MUTED)
for spine in ax.spines.values():
    spine.set_edgecolor("#1e1e2e")
ax.grid(True, color="#1a1a2e", linestyle="--", linewidth=0.7, zorder=0)

legend = ax.legend(facecolor=SURFACE, edgecolor="#1e1e2e", labelcolor=TEXT, fontsize=10)

import os; os.makedirs("results/plots", exist_ok=True)
fig.tight_layout()
fig.savefig(OUT, dpi=150, facecolor=BG)
print(f"Saved {OUT}")
