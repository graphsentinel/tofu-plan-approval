#!/usr/bin/env python3
"""Compares every run of the last 'scripts/lab.sh test' with lab/expected.tsv.

  summary.py --run-list lab/.runtime/test-runs --runs 5 --ledger checks/ledger.tsv [--runner-failures file]
             [--incomplete] [--markdown out.md] lab/expected.tsv results/

results/<run_id>/verify.tsv holds the check results (scripts/verify.sh), results/<run_id>/measurements.tsv the
measurement rows (scripts/collect.py). The runs are the ones 'scripts/lab.sh test' listed in --run-list as it made
them (exactly --runs of them, each with its results), every expected
row must be present in every run with the expected value, and nothing unexpected may appear. A check that could
not run is a failure, except the ones lab/expected.tsv names: MANUAL (a human judgement), GATE (publication, run
with verify.sh --publish) and N/A for a pair check in the first run of a fresh machine (no earlier run to compare
with; only checks whose scope in checks/ledger.tsv is "pair"). A runner that exited with an error, or a test that did not reach its end, is a failure. Exit 0 only when
everything matches.
"""
import argparse
import collections
import csv
import json
import os
import sys


def read_tsv(path):
    with open(path) as f:
        return list(csv.DictReader((line for line in f if not line.startswith("#")), delimiter="\t"))


def keyed(rows, key, what, problems):
    """rows by key; a duplicate key is a problem (a later row must not hide an earlier failure)."""
    out = {}
    for r in rows:
        k = key(r)
        if k in out:
            problems.append(f"{what}: duplicate {k}")
        out[k] = r
    return out


# the shell check EV-012 (TC-04/metrics.json) against the Python rows of scripts/collect.py: the same numbers
SHELL_VS_PYTHON = {"opportunities": "completed_opportunities", "calls": "api_calls_total", "flux_calls": "flux_api_calls",
                   "flux_dry_runs": "flux_dry_runs", "flux_writes": "flux_persisted_writes",
                   "mutations": "field_mutations_total", "flux_mutations": "flux_field_mutations"}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--run-list", required=True)
    ap.add_argument("--ledger", required=True)
    ap.add_argument("--runs", type=int, required=True)
    ap.add_argument("--runner-failures")
    ap.add_argument("--incomplete", action="store_true")
    ap.add_argument("--markdown")
    ap.add_argument("expected")
    ap.add_argument("results")
    a = ap.parse_args()

    exp = read_tsv(a.expected)
    exp_checks = {r["name"]: r["expected"] for r in exp if r["kind"] == "check"}
    exp_metrics = {(r["test"], r["name"]): r["expected"] for r in exp if r["kind"] == "metric"}

    pair = {r["id"] for r in read_tsv(a.ledger) if r["scope"] == "pair"}
    problems = []
    if a.runs < 1:
        problems.append("--runs must be at least 1")
    if not exp_checks or not exp_metrics:
        problems.append(f"{a.expected} lists no checks or no measurement rows")
    if a.incomplete:
        problems.append("the test did not reach its end (interrupted or aborted)")
    if a.runner_failures and os.path.exists(a.runner_failures):
        problems += [f"runner failed: {x.strip()}" for x in open(a.runner_failures) if x.strip()]
    try:
        runs = [x.strip() for x in open(a.run_list) if x.strip()]
    except FileNotFoundError:
        runs = []
    if len(runs) != a.runs:
        problems.append(f"{len(runs)} runs listed in {a.run_list}, expected {a.runs}")

    cells: collections.Counter = collections.Counter()   # (kind, name) -> runs matching
    na_pair = 0
    if len(set(runs)) != len(runs):
        problems.append(f"{a.run_list} lists a run twice")
    for idx, run in enumerate(runs):
        d = os.path.join(a.results, run)
        try:
            checks = keyed(read_tsv(os.path.join(d, "verify.tsv")), lambda r: r["id"], f"{run} verify.tsv", problems)
        except FileNotFoundError:
            problems.append(f"{run}: no verify.tsv")
            checks = {}
        for cid, want in exp_checks.items():
            got = checks.get(cid)
            if got is None:
                problems.append(f"{run} {cid}: no result")
                continue
            res = got["result"]
            # N/A only for a pair check, only in the first run of this test, only when verify saw a single run
            ok = res == want or (want == "PASSED" and res == "N/A" and cid in pair and idx == 0
                                 and "only one exists" in got["message"])
            if res == "N/A" and ok:
                na_pair += 1
            if ok:
                cells[("check", cid)] += 1
            else:
                problems.append(f"{run} {cid}: {res}, expected {want} ({got['message'][:120]})")
        for cid in checks:
            if cid not in exp_checks:
                problems.append(f"{run} {cid}: result not in lab/expected.tsv")
        try:
            mrows = read_tsv(os.path.join(d, "measurements.tsv"))
            for r in mrows:
                if r["run_id"] != run:
                    problems.append(f"{run} measurements.tsv: a row of run {r['run_id']}")
            rows = {k: r["value"] for k, r in keyed(mrows, lambda r: (r["test"], r["metric"]), f"{run} measurements.tsv", problems).items()}
        except FileNotFoundError:
            problems.append(f"{run}: no measurements.tsv")
            rows = {}
        for key, want in exp_metrics.items():
            got = rows.get(key)
            if got == want:
                cells[("metric",) + key] += 1
            else:
                problems.append(f"{run} {key[0]} {key[1]}: {got if got is not None else 'missing'}, expected {want}")
        try:
            shell = json.load(open(os.path.join(d, "metrics.json")))
            for sk, pk in SHELL_VS_PYTHON.items():
                if str(shell.get(sk)) != rows.get(("TC-04", pk)):
                    problems.append(f"{run} TC-04 {pk}: shell check says {shell.get(sk)}, collect.py says {rows.get(('TC-04', pk))}")
        except FileNotFoundError:
            problems.append(f"{run}: no metrics.json from EV-012 (the shell count) to compare with collect.py")
        for key in rows:
            if key not in exp_metrics:
                problems.append(f"{run} {key[0]} {key[1]}: measured but not in lab/expected.tsv")

    n_checks, n_metrics = len(exp_checks), len(exp_metrics)
    full_c = sum(1 for k in exp_checks if cells[("check", k)] == len(runs) and runs)
    full_m = sum(1 for k in exp_metrics if cells[("metric",) + k] == len(runs) and runs)
    lines = ["| | expected | matching in every run |", "|---|---|---|",
             f"| check results | {n_checks} | {full_c} |", f"| measurement rows | {n_metrics} | {full_m} |"]
    table = "\n".join(lines)
    print(f"\nRuns of this test: {len(runs)} (expected {a.runs}): {' '.join(runs)}\n")
    print(table)
    if na_pair:
        print(f"\npair checks N/A in the first run (no earlier run on this machine): {na_pair}")
    if problems:
        print("\nCHECKS FAILED:")
        for p in problems[:60]:
            print("  - " + p)
        if len(problems) > 60:
            print(f"  ... and {len(problems) - 60} more")
    else:
        print("\nALL CHECKS PASSED")
    if a.markdown:
        with open(a.markdown, "w") as f:
            f.write(f"Runs of this test: {len(runs)} ({', '.join(runs)})\n\n{table}\n\n")
            f.write("Checks: " + ("all passed\n" if not problems else "FAILED\n" + "".join(f"- {p}\n" for p in problems)))
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
