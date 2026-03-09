"""
Plot: Heatmap of median PEG parser overhead (%) per query × scale factor.
TPC-H shows all 22 queries; TPC-DS shows the top TOP_N queries by median PEG overhead.

Usage:
    python analysis/plot_heatmap.py [results/benchmark_results.duckdb]
"""
import sys
import os
import duckdb
import matplotlib.pyplot as plt
import matplotlib.colors as mcolors

DB  = sys.argv[1] if len(sys.argv) > 1 else "results/benchmark_results.duckdb"
OUT = "results/plots/heatmap_peg_overhead.png"

TOP_N_TPCDS = 20

con = duckdb.connect(DB, read_only=True)

df_tpch = con.execute("""
    SELECT printf('SF %g', scale_factor) AS sf_label, scale_factor,
           query_nr,
           round(median(relative_pct), 3) AS median_peg_pct
    FROM results
    WHERE parser = 'peg' AND benchmark = 'tpch'
    GROUP BY scale_factor, query_nr
    ORDER BY scale_factor, query_nr
""").df()

# Pick the top TOP_N query numbers by their overall median overhead, then fetch all SFs for those
df_tpcds = con.execute("""
    WITH top_queries AS (
        SELECT query_nr
        FROM results
        WHERE parser = 'peg' AND benchmark = 'tpcds'
        GROUP BY query_nr
        ORDER BY median(relative_pct) DESC
        LIMIT ?
    )
    SELECT printf('SF %g', scale_factor) AS sf_label, scale_factor,
           query_nr,
           round(median(relative_pct), 3) AS median_peg_pct
    FROM results
    WHERE parser = 'peg' AND benchmark = 'tpcds'
      AND query_nr IN (SELECT query_nr FROM top_queries)
    GROUP BY scale_factor, query_nr
    ORDER BY scale_factor, query_nr
""", [TOP_N_TPCDS]).df()

con.close()

BG      = "#0a0a0f"
SURFACE = "#111118"
MUTED   = "#64748b"
TEXT    = "#e2e8f0"

cmap = mcolors.LinearSegmentedColormap.from_list(
    "peg_heat", ["#111118", "#7c2d12", "#f97316", "#fde68a"]
)

def sf_col_order(df):
    return (
        df[["sf_label", "scale_factor"]]
        .drop_duplicates()
        .sort_values("scale_factor")
        ["sf_label"]
        .tolist()
    )

panels = []
for bm_label, df in [("TPC-H  ·  all 22 queries", df_tpch),
                     (f"TPC-DS  ·  top {TOP_N_TPCDS} by PEG overhead", df_tpcds)]:
    if df.empty:
        continue
    cols = sf_col_order(df)
    pivot = df.pivot(index="query_nr", columns="sf_label", values="median_peg_pct")
    pivot = pivot[cols].sort_index()
    panels.append((bm_label, pivot))

fig, axes = plt.subplots(1, len(panels), figsize=(8 * len(panels), max(8, TOP_N_TPCDS * 0.45)))
fig.patch.set_facecolor(BG)
if len(panels) == 1:
    axes = [axes]

for ax, (title, pivot) in zip(axes, panels):
    ax.set_facecolor(SURFACE)
    col_labels = pivot.columns.tolist()
    row_labels = [f"Q{q}" for q in pivot.index]
    data = pivot.values

    im = ax.imshow(data, cmap=cmap, aspect="auto")

    ax.set_xticks(range(len(col_labels)))
    ax.set_xticklabels(col_labels, color=TEXT, fontsize=10)
    ax.set_yticks(range(len(row_labels)))
    ax.set_yticklabels(row_labels, color=TEXT, fontsize=9)
    ax.tick_params(length=0)

    for r in range(data.shape[0]):
        for c in range(data.shape[1]):
            val = data[r, c]
            if not (val != val):  # skip NaN
                text_color = TEXT if val < data[~(data != data)].max() * 0.6 else "#0a0a0f"
                ax.text(c, r, f"{val:.1f}%", ha="center", va="center",
                        fontsize=7.5, color=text_color)

    cbar = fig.colorbar(im, ax=ax, fraction=0.025, pad=0.02)
    cbar.ax.yaxis.set_tick_params(color=MUTED)
    cbar.set_label("Median PEG overhead (%)", color=MUTED, fontsize=9)
    plt.setp(cbar.ax.yaxis.get_ticklabels(), color=MUTED)
    cbar.outline.set_edgecolor("#1e1e2e")

    ax.set_title(f"PEG overhead per query × SF  ·  {title}", color=TEXT, fontsize=12, pad=14)
    ax.spines[:].set_edgecolor("#1e1e2e")

os.makedirs("results/plots", exist_ok=True)
fig.tight_layout()
fig.savefig(OUT, dpi=150, facecolor=BG)
print(f"Saved {OUT}")
