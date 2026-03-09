"""
Compare PEG parser performance between two versions.

Queries the results DB for parser='peg' rows across both versions and shows
per-query improvement (positive = faster, negative = regression).

Usage:
    python analysis/compare_versions.py <baseline> <new> [results/benchmark_results.duckdb]

    baseline  – VERSION label of the reference run (e.g. the original peg branch)
    new       – VERSION label of the run to evaluate (e.g. peg-caching)

Lists available peg-parser versions when called with no arguments.

Examples:
    python analysis/compare_versions.py
    python analysis/compare_versions.py abc1234 peg-caching
    python analysis/compare_versions.py baseline peg-caching results/benchmark_results.duckdb
"""
import sys
import os
import duckdb
import matplotlib.pyplot as plt

DB = "results/benchmark_results.duckdb"

args = sys.argv[1:]
if args and args[-1].endswith(".duckdb"):
    DB = args.pop()

con = duckdb.connect(DB, read_only=True)

if len(args) < 2:
    versions = con.execute("""
        SELECT version, count(*) AS rows
        FROM results
        WHERE parser = 'peg'
        GROUP BY version
        ORDER BY min(run_at)
    """).df()
    print("Available versions with peg-parser data:")
    print(versions.to_string(index=False))
    print("\nUsage: python analysis/compare_versions.py <baseline> <new>")
    con.close()
    sys.exit(0)

V1, V2 = args[0], args[1]

df = con.execute(f"""
    WITH agg AS (
        SELECT benchmark, scale_factor, query_nr, version,
               median(parser_ms)    AS med_parser_ms,
               median(relative_pct) AS med_relative_pct
        FROM results
        WHERE parser = 'peg' AND version IN ('{V1}', '{V2}')
        GROUP BY benchmark, scale_factor, query_nr, version
    ),
    compared AS (
        SELECT
            benchmark, scale_factor, query_nr,
            MAX(CASE WHEN version = '{V1}' THEN med_parser_ms    END) AS v1_ms,
            MAX(CASE WHEN version = '{V2}' THEN med_parser_ms    END) AS v2_ms,
            MAX(CASE WHEN version = '{V1}' THEN med_relative_pct END) AS v1_pct,
            MAX(CASE WHEN version = '{V2}' THEN med_relative_pct END) AS v2_pct
        FROM agg
        GROUP BY benchmark, scale_factor, query_nr
        HAVING v1_ms IS NOT NULL AND v2_ms IS NOT NULL
    )
    SELECT *,
           round((1 - v2_ms / v1_ms) * 100, 2) AS improvement_pct,
           round(v1_ms - v2_ms, 4)              AS saved_ms
    FROM compared
    ORDER BY benchmark, scale_factor, improvement_pct DESC
""").df()
con.close()

if df.empty:
    print(f"No overlapping peg data found for versions '{V1}' and '{V2}'.")
    sys.exit(1)

# ── Console summary ────────────────────────────────────────────────────────────
summary = (
    df.groupby(["benchmark", "scale_factor"])
    .agg(
        queries=("query_nr", "count"),
        avg_improvement=("improvement_pct", "mean"),
        avg_v1_ms=("v1_ms", "mean"),
        avg_v2_ms=("v2_ms", "mean"),
    )
    .reset_index()
)
summary["avg_improvement"] = summary["avg_improvement"].round(2)
summary["avg_v1_ms"]       = summary["avg_v1_ms"].round(4)
summary["avg_v2_ms"]       = summary["avg_v2_ms"].round(4)

print(f"\nPEG parser comparison: '{V1}'  →  '{V2}'")
print("Positive improvement_pct = faster in '{V2}'\n")
print(summary.to_string(index=False))

# ── Plot ───────────────────────────────────────────────────────────────────────
BG       = "#0a0a0f"
SURFACE  = "#111118"
MUTED    = "#475569"
TEXT     = "#e2e8f0"
FASTER   = "#4ade80"   # green  – improvement
SLOWER   = "#f87171"   # red    – regression
NEUTRAL  = "#94a3b8"

groups = df.groupby(["benchmark", "scale_factor"])
n_panels = len(groups)
fig, axes = plt.subplots(1, n_panels, figsize=(max(8, 9 * n_panels), 10))
fig.patch.set_facecolor(BG)
if n_panels == 1:
    axes = [axes]

for ax, ((bm, sf), grp) in zip(axes, groups):
    grp = grp.sort_values("improvement_pct", ascending=True)   # barh: bottom = worst
    labels = [f"Q{q}" for q in grp["query_nr"]]
    values = grp["improvement_pct"].tolist()
    colors = [FASTER if v >= 0 else SLOWER for v in values]

    ax.set_facecolor(SURFACE)
    bars = ax.barh(labels, values, color=colors, edgecolor="none", height=0.7)

    for bar, val in zip(bars, values):
        x_off = 0.15 if val >= 0 else -0.15
        ha    = "left"  if val >= 0 else "right"
        color = FASTER  if val >= 0 else SLOWER
        ax.text(
            bar.get_width() + x_off,
            bar.get_y() + bar.get_height() / 2,
            f"{val:+.1f}%",
            va="center", ha=ha, fontsize=8, color=color,
        )

    ax.axvline(0, color=NEUTRAL, linewidth=0.8, linestyle="--")
    ax.set_xlabel("Parser-time improvement  (%, positive = faster)", color=MUTED, fontsize=10)
    ax.set_title(
        f"{bm.upper()}  ·  SF {sf:g}\n'{V1}'  →  '{V2}'",
        color=TEXT, fontsize=12, pad=14,
    )
    ax.tick_params(colors=MUTED)
    ax.spines["top"].set_visible(False)
    ax.spines["right"].set_visible(False)
    for spine in ax.spines.values():
        spine.set_edgecolor("#1e1e2e")
    ax.grid(True, axis="x", color="#1a1a2e", linestyle="--", linewidth=0.7, zorder=0)

OUT = f"results/plots/compare_{V1}_vs_{V2}.png"
os.makedirs("results/plots", exist_ok=True)
fig.tight_layout()
fig.savefig(OUT, dpi=150, facecolor=BG)
print(f"\nSaved {OUT}")
