"""
Plot: PEG parser overhead per TPC-H query, sorted highest to lowest.
Corresponds to the "Queries where PEG overhead is highest (at SF=1)" query in queries.sql.

A scale factor can be passed as the second argument (default: 1.0).

Usage:
    python analysis/plot_per_query.py [results/benchmark_results.duckdb] [scale_factor]
"""
import sys
import os
import duckdb
import matplotlib.pyplot as plt

DB = sys.argv[1] if len(sys.argv) > 1 else "results/benchmark_results.duckdb"
SF = float(sys.argv[2]) if len(sys.argv) > 2 else 1.0
OUT = "results/plots/per_query_peg.png"

con = duckdb.connect(DB, read_only=True)
df = con.execute("""
    SELECT
        query_nr,
        round(median(relative_pct), 3) AS median_peg_pct,
        round(median(latency_ms),   3) AS median_latency_ms
    FROM results
    WHERE parser = 'peg' AND scale_factor = ?
    GROUP BY query_nr
    ORDER BY median_peg_pct DESC
""", [SF]).df()
con.close()

PEG_COLOR = "#f97316"
BG = "#0a0a0f"
SURFACE = "#111118"
MUTED = "#475569"
TEXT = "#e2e8f0"

# Colour intensity by rank
max_pct = df["median_peg_pct"].max()
colors = [plt.matplotlib.colors.to_rgba(PEG_COLOR, alpha=0.4 + 0.6 * (v / max_pct))
          for v in df["median_peg_pct"]]

fig, ax = plt.subplots(figsize=(8, 7))
fig.patch.set_facecolor(BG)
ax.set_facecolor(SURFACE)

labels = [f"Q{q}" for q in df["query_nr"]]
bars = ax.barh(labels, df["median_peg_pct"], color=colors, edgecolor="none", height=0.7)

for bar, val in zip(bars, df["median_peg_pct"]):
    ax.text(bar.get_width() + 0.05, bar.get_y() + bar.get_height() / 2,
            f"{val:.2f}%", va="center", fontsize=8.5, color=PEG_COLOR)

ax.invert_yaxis()
ax.set_xlabel("Median PEG parser overhead (% of latency)", color=MUTED, fontsize=10)
ax.set_title(f"PEG overhead per TPC-H query  ·  SF {SF:g}", color=TEXT, fontsize=13, pad=14)
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
