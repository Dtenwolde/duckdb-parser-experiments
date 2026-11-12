#!/usr/bin/env python3
"""Summarise a bench CSV: per corpus and variant, acceptance, total time, time per token and ratios.

The CSV holds one row per (DuckDB build, pass, corpus, input, variant). Per input the median over passes is taken,
then inputs are summed per corpus. cpp-peglib and the PostgreSQL parser do not depend on the DuckDB build; they are
reported once (median over all builds) and their spread across builds is printed as a check on the comparison.

Usage: report.py results.csv [--markdown]
"""
import csv
import statistics
import sys
from collections import defaultdict

# what each variant is compared against: the fastest path of the reference DuckDB build that produces as much
BASELINE = {"recognize": ("duckdb", "tree", ""), "tree": ("duckdb", "tree", ""), "ast": ("duckdb", "ast", "")}
SHARED_ENGINES = ("peglib", "postgres")


def main():
    path = sys.argv[1]
    markdown = "--markdown" in sys.argv
    rows = list(csv.DictReader(open(path)))

    labels, commits = [], {}
    for r in rows:
        if r["duckdb"] not in commits:
            labels.append(r["duckdb"])
            commits[r["duckdb"]] = r["commit"]
    reference = labels[0]

    # (label, corpus, engine, level, config) -> input -> [median_ns per pass]
    samples = defaultdict(lambda: defaultdict(list))
    meta = {}
    order = []
    for r in rows:
        variant = (r["corpus"], r["engine"], r["level"], r["config"])
        if variant not in order:
            order.append(variant)
        samples[(r["duckdb"],) + variant][r["input"]].append(float(r["median_ns"]))
        meta[(r["duckdb"],) + variant + (r["input"],)] = (int(r["tokens"]), int(r["accepted"]))

    def total(label, variant):
        per_input = samples.get((label,) + variant)
        if not per_input:
            return None
        ns = sum(statistics.median(v) for v in per_input.values())
        tokens = sum(meta[(label,) + variant + (i,)][0] for i in per_input)
        accepted = sum(meta[(label,) + variant + (i,)][1] for i in per_input)
        return {"ns": ns, "tokens": tokens, "accepted": accepted, "inputs": len(per_input)}

    header = ["corpus", "engine", "build", "output", "config", "accepted", "total ms", "ns/token",
              f"vs DuckDB PEG ({reference})"]
    table, spreads = [], []
    for variant in order:
        corpus, engine, level, config = variant
        if engine in SHARED_ENGINES:
            totals = [t for t in (total(label, variant) for label in labels) if t]
            t = dict(totals[0], ns=statistics.median(x["ns"] for x in totals))
            if len(totals) > 1 and corpus != "__grammar__":
                values = [x["ns"] for x in totals]
                spreads.append((max(values) / min(values) - 1, corpus, engine, level, config))
            entries = [("all", t)]
        else:
            entries = [(label, total(label, variant)) for label in labels]
        for label, t in entries:
            if not t:
                continue
            if corpus == "__grammar__":
                table.append(["(grammar)", engine, label, "construction", config, "", f"{t['ns'] / 1e6:.3f}", "", ""])
                continue
            base = total(reference, (corpus,) + BASELINE[level]) if level in BASELINE else None
            ratio = f"{t['ns'] / base['ns']:.2f}x" if base else ""
            per_token = f"{t['ns'] / t['tokens']:.0f}" if t["tokens"] else ""
            table.append([corpus, engine, label, level, config, f"{t['accepted']}/{t['inputs']}",
                          f"{t['ns'] / 1e6:.3f}", per_token, ratio])

    builds = ", ".join(f"{label} = {commits[label]}" for label in labels)
    if markdown:
        print(f"DuckDB builds: {builds}\n")
        print("| " + " | ".join(header) + " |")
        print("|" + "|".join("---" for _ in header) + "|")
        for line in table:
            print("| " + " | ".join(line) + " |")
    else:
        print(f"DuckDB builds: {builds}")
        widths = [max(len(str(x)) for x in col) for col in zip(header, *table)]
        for line in [header] + table:
            print("  ".join(str(x).ljust(w) for x, w in zip(line, widths)))
    if spreads:
        worst = max(spreads)
        print(f"\nAnchor check: cpp-peglib and PostgreSQL totals differ by at most {worst[0] * 100:.1f}% between the "
              f"bench binaries ({worst[1]} {worst[2]} {worst[3]} {worst[4]}).")


if __name__ == "__main__":
    main()
