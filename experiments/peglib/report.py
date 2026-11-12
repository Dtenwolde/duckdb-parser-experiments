#!/usr/bin/env python3
"""Summarise a bench CSV: per corpus and variant, acceptance, total time, time per token and ratios.

Usage: report.py results.csv [--markdown]
"""
import csv
import sys
from collections import defaultdict

# what each variant is compared against: the fastest DuckDB PEG path that produces at least as much
BASELINE = {"recognize": ("duckdb", "tree", ""), "tree": ("duckdb", "tree", ""), "ast": ("duckdb", "ast", "")}


def main():
    path = sys.argv[1]
    markdown = "--markdown" in sys.argv
    rows = list(csv.DictReader(open(path)))
    grammar = [r for r in rows if r["corpus"] == "__grammar__"]
    rows = [r for r in rows if r["corpus"] != "__grammar__"]

    order, totals = [], defaultdict(lambda: defaultdict(float))
    for r in rows:
        key = (r["corpus"], r["engine"], r["level"], r["config"])
        if key not in totals:
            order.append(key)
        t = totals[key]
        t["inputs"] += 1
        t["accepted"] += int(r["accepted"])
        t["tokens"] += int(r["tokens"])
        t["ns"] += float(r["median_ns"])

    header = ["corpus", "engine", "output", "config", "accepted", "total ms", "ns/token", "vs DuckDB PEG"]
    table = []
    for key in order:
        corpus, engine, level, config = key
        t = totals[key]
        base = totals.get((corpus,) + BASELINE[level]) if level in BASELINE else None
        ratio = f"{t['ns'] / base['ns']:.2f}x" if base and base["ns"] else ""
        per_token = f"{t['ns'] / t['tokens']:.0f}" if t["tokens"] else ""
        table.append([corpus, engine, level, config, f"{int(t['accepted'])}/{int(t['inputs'])}",
                      f"{t['ns'] / 1e6:.3f}", per_token, ratio])
    for r in grammar:
        table.append(["(grammar)", r["engine"], "construction", r["config"], "", f"{float(r['median_ns']) / 1e6:.3f}",
                      "", ""])

    if markdown:
        print("| " + " | ".join(header) + " |")
        print("|" + "|".join("---" for _ in header) + "|")
        for line in table:
            print("| " + " | ".join(line) + " |")
    else:
        widths = [max(len(str(x)) for x in col) for col in zip(header, *table)]
        for line in [header] + table:
            print("  ".join(str(x).ljust(w) for x, w in zip(line, widths)))


if __name__ == "__main__":
    main()
