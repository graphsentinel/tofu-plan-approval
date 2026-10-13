#!/usr/bin/env python3
"""Derives the measurement rows of one run from its raw records, without the shell checks.

  collect.py <run-dir> [<run-dir> ...]          rows (TSV) to stdout
  collect.py --check <runs-dir> <tsv>           re-derive every run under <runs-dir> and compare with <tsv>

Each row is (run_id, test, metric, value). The checks in checks/ decide pass/fail on the same records; this is a
second, independent reading in another language, so a bug in one of them shows up as a difference
(scripts/summary.py compares both with lab/expected.tsv). Reads only: nothing in the run is written.
"""
import csv
import hashlib
import json
import os
import re
import sys

ANSI = re.compile(r"\x1b\[[0-9;]*m")
# the second writer's service account; "dis-yazar" is its name in the reference runs recorded before the translation
SECOND_WRITER = re.compile(r"second-writer|dis-yazar")
FLUX = re.compile(r"kustomize-controller|flux")


def load(path):
    with open(path) as f:
        return json.load(f)


def value(run, rel):
    p = os.path.join(run, rel)
    if not os.path.exists(p) or os.path.getsize(p) == 0:
        return "MISSING"
    return load(p).get("data", {}).get("value", "ABSENT")


def actions(run, rel):
    p = os.path.join(run, rel)
    if not os.path.exists(p):
        return "MISSING"
    acts = sorted(a for rc in load(p).get("resource_changes", []) for a in rc["change"]["actions"])
    return ",".join(acts) or "none"


def text(run, rel):
    p = os.path.join(run, rel)
    return ANSI.sub("", open(p, errors="replace").read()) if os.path.exists(p) else ""


def rc(run, rel):
    t = text(run, rel).strip()
    return t if t else "MISSING"


def summary(run, rel, key):
    p = os.path.join(run, rel)
    if not os.path.exists(p) or os.path.getsize(p) == 0:
        return "MISSING"
    v = load(p).get(key)
    return "MISSING" if v is None else str(v)


def reason(stderr):
    """The class of a tofu rejection, from its error title."""
    if "Saved plan is stale" in stderr:
        return "stale-plan"
    if "Error acquiring the state lock" in stderr:
        return "state-lock"
    return "other" if stderr.strip() else "none"


def audit(run, tc):
    p = os.path.join(run, tc, "audit.jsonl")
    if not os.path.exists(p) or os.path.getsize(p) == 0:
        return None
    with open(p) as f:
        return [json.loads(line) for line in f if line.strip()]


def actor(e):
    return (e.get("user", {}).get("username") or "") + " " + ((e.get("impersonatedUser") or {}).get("username") or "")


def cm_calls(events):
    """Completed create/update/patch calls on ConfigMap t27/t27 with an explicit 2xx status (dry runs included)."""
    out = []
    for e in events:
        o = e.get("objectRef", {})
        code = (e.get("responseStatus") or {}).get("code")
        if (o.get("resource") == "configmaps" and o.get("name") == "t27" and o.get("namespace") == "t27"
                and e.get("verb") in ("create", "update", "patch") and e.get("stage") == "ResponseComplete"
                and isinstance(code, int) and 200 <= code < 300):
            out.append(e)
    return out


def dry(e):
    return re.search(r"[?&]dryRun=All(&|$)", e.get("requestURI") or "") is not None


def field(obj):
    return obj.get("data", {}).get("value") if isinstance(obj, dict) else None


def rv(e):
    o = e.get("responseObject")
    try:
        return int(o["metadata"]["resourceVersion"])
    except (TypeError, KeyError, ValueError):
        return None


def uid(e):
    o = e.get("responseObject")
    return o.get("metadata", {}).get("uid") if isinstance(o, dict) else None


def transitions(events):
    """(actor, before, after) for every persisted change of data.value in resourceVersion order, and the
    attribution status: ok | incomplete (a write without resourceVersion/uid) | recreated (several uids) |
    ambiguous (one resourceVersion written by several actors or with several values)."""
    persisted = [e for e in cm_calls(events) if not dry(e)]
    if any(rv(e) is None or uid(e) is None for e in persisted):
        return [], "incomplete"
    if len({uid(e) for e in persisted}) != 1:
        return [], "recreated"
    groups = {}
    for e in sorted(persisted, key=lambda e: (rv(e), e.get("stageTimestamp") or "")):
        groups.setdefault(rv(e), []).append(e)
    if any(len({actor(e) for e in g}) > 1 or len({field(e.get("responseObject")) for e in g}) > 1 for g in groups.values()):
        return [], "ambiguous"
    seq = [g[0] for _, g in sorted(groups.items())]
    out = [(actor(b), field(a.get("responseObject")), field(b.get("responseObject")))
           for a, b in zip(seq, seq[1:]) if field(a.get("responseObject")) != field(b.get("responseObject"))]
    return out, "ok"


def collect(run):
    rid = os.path.basename(run.rstrip("/"))
    rows = []

    def add(tc, metric, val):
        rows.append((rid, tc, metric, str(val)))

    # TC-01: approval bound to the configuration (git revision), runner re-plans before applying
    add("TC-01", "reviewed_actions", actions(run, "TC-01/reviewed.plan.json"))
    add("TC-01", "applied_actions", actions(run, "TC-01/applied.plan.json"))
    add("TC-01", "value_after_second_writer", value(run, "TC-01/object.10-after-intervention.json"))
    add("TC-01", "apply_exit", rc(run, "TC-01/apply.rc"))
    add("TC-01", "value_after_apply", value(run, "TC-01/object.20-after-apply.json"))

    # TC-02: the exact saved artifact applied after an out-of-band edit
    h = [hashlib.sha256(open(os.path.join(run, "TC-02", f), "rb").read()).hexdigest()
         if os.path.exists(os.path.join(run, "TC-02", f)) else None for f in ("reviewed.tfplan", "applied.tfplan")]
    add("TC-02", "artifact_identical", "yes" if h[0] and h[0] == h[1] else "no")
    ids = [(summary(run, "TC-02/state.00-start.summary.json", k), summary(run, "TC-02/state.10-after-intervention.summary.json", k))
           for k in ("lineage", "serial")]
    add("TC-02", "state_identity_unchanged_by_second_writer",
        "MISSING" if any(v in ("MISSING", "None") for pair in ids for v in pair) else ("yes" if all(a == b for a, b in ids) else "no"))
    add("TC-02", "value_after_second_writer", value(run, "TC-02/object.10-after-intervention.json"))
    add("TC-02", "apply_exit", rc(run, "TC-02/apply.rc"))
    add("TC-02", "apply_rejection", reason(text(run, "TC-02/apply.stderr")))
    add("TC-02", "value_after_apply", value(run, "TC-02/object.20-after-apply.json"))

    # TC-03: lock precondition, then a competing apply advances the state, then the earlier artifact
    add("TC-03", "lock_contention_exit", rc(run, "TC-03/lock-contention.rc"))
    add("TC-03", "lock_contention_rejection", reason(text(run, "TC-03/lock-contention.stderr")))
    # the plan is made from the state after the lock precondition (which destroys and re-creates the object)
    l0, l1 = (summary(run, f"TC-03/state.{x}.summary.json", "lineage") for x in ("05-after-lock", "10-after-competitor"))
    add("TC-03", "lineage_unchanged", "MISSING" if "MISSING" in (l0, l1) else ("yes" if l0 == l1 else "no"))
    add("TC-03", "serial_plan_made_from", summary(run, "TC-03/state.05-after-lock.summary.json", "serial"))
    add("TC-03", "serial_after_competitor", summary(run, "TC-03/state.10-after-competitor.summary.json", "serial"))
    add("TC-03", "value_after_competitor", value(run, "TC-03/object.10-after-competitor.json"))
    add("TC-03", "stale_apply_exit", rc(run, "TC-03/stale-plan-apply.rc"))
    add("TC-03", "stale_apply_rejection", reason(text(run, "TC-03/stale-plan-apply.stderr")))
    add("TC-03", "value_after_stale_apply", value(run, "TC-03/object.20-after-stale-plan.json"))

    # TC-04: the approved artifact applied cleanly, then Flux reconciles a different desired state
    add("TC-04", "apply_exit", rc(run, "TC-04/apply.rc"))
    add("TC-04", "value_after_apply", value(run, "TC-04/object.10-after-apply.json"))
    p = os.path.join(run, "TC-04", "opportunities.jsonl")
    opp = sum(1 for line in open(p) if line.strip() and json.loads(line).get("lastHandledReconcileAt")) if os.path.exists(p) else "MISSING"
    add("TC-04", "completed_opportunities", opp)
    ev = audit(run, "TC-04")
    if ev is None:
        for m in ("api_calls_total", "flux_api_calls", "flux_dry_runs", "flux_persisted_writes", "attribution",
                  "field_mutations_total", "flux_field_mutations", "flux_transition"):
            add("TC-04", m, "MISSING")
        ftr = None
    else:
        calls = [e for e in cm_calls(ev) if e.get("verb") != "create"]
        flux = [e for e in calls if FLUX.search(actor(e))]
        add("TC-04", "api_calls_total", len(calls))
        add("TC-04", "flux_api_calls", len(flux))
        add("TC-04", "flux_dry_runs", sum(1 for e in flux if dry(e)))
        add("TC-04", "flux_persisted_writes", sum(1 for e in flux if not dry(e)))
        tr, status = transitions(ev)
        add("TC-04", "attribution", status)
        add("TC-04", "field_mutations_total", len(tr) if status == "ok" else status.upper())
        ftr = [(a, x, y) for a, x, y in tr if FLUX.search(a)] if status == "ok" else None
        add("TC-04", "flux_field_mutations", len(ftr) if ftr is not None else status.upper())
        add("TC-04", "flux_transition", (",".join(f"{x}->{y}" for _, x, y in ftr) or "none") if ftr is not None else status.upper())
    uids = [load(os.path.join(run, "TC-04", f"object.{x}.json")).get("metadata", {}).get("uid")
            for x in ("10-after-apply", "30-window-end") if os.path.exists(os.path.join(run, "TC-04", f"object.{x}.json"))]
    add("TC-04", "uid_stable", "yes" if len(uids) == 2 and uids[0] and uids[0] == uids[1] else "no")
    add("TC-04", "value_at_window_end", value(run, "TC-04/object.30-window-end.json"))

    # TC-05: the same four paths with no second writer
    add("TC-05", "values", ",".join(value(run, f"TC-05/sub-0{i}/object.20-after-apply.json") for i in range(1, 5)))
    ev5 = audit(run, "TC-05")
    if ev5 is None:
        add("TC-05", "foreign_actor_writes", "MISSING")
    else:
        add("TC-05", "foreign_actor_writes", sum(1 for e in cm_calls(ev5) if e.get("verb") != "create"
                                                 and (SECOND_WRITER.search(actor(e)) or FLUX.search(actor(e)))))

    # protection engaged: the earlier/approved intent was stopped AND the target kept its value
    for tc in ("TC-01", "TC-02"):
        x = rc(run, f"{tc}/apply.rc")
        add(tc, "protection_engaged", "UNKNOWN" if x == "MISSING" else ("no" if x == "0" else "yes"))
    x = rc(run, "TC-03/stale-plan-apply.rc")
    v1, v2 = value(run, "TC-03/object.10-after-competitor.json"), value(run, "TC-03/object.20-after-stale-plan.json")
    add("TC-03", "protection_engaged", "UNKNOWN" if "MISSING" in (x, v1, v2) else ("yes" if x != "0" and v1 == v2 else "no"))
    add("TC-04", "protection_engaged", "UNKNOWN" if ftr is None else ("no" if ftr else "yes"))
    return rows


HEADER = ("run_id", "test", "metric", "value")


def main(argv):
    if argv[:1] == ["--check"]:
        runs_dir, tsv = argv[1], argv[2]
        runs = sorted(d for d in os.listdir(runs_dir) if os.path.isfile(os.path.join(runs_dir, d, "MANIFEST.sha256")))
        fresh = [r for d in runs for r in collect(os.path.join(runs_dir, d))]
        with open(tsv) as f:
            stored = [tuple(r) for r in csv.reader(f, delimiter="\t")][1:]
        a, b = set(fresh), set(stored)
        for r in sorted(a - b):
            print("re-derived, not in the file:", "\t".join(r))
        for r in sorted(b - a):
            print("in the file, not re-derived:", "\t".join(r))
        print(f"{len(fresh)} rows re-derived from {len(runs)} runs; differences: {len(a ^ b)}")
        return 1 if a ^ b or len(fresh) != len(stored) else 0
    w = csv.writer(sys.stdout, delimiter="\t", lineterminator="\n")
    w.writerow(HEADER)
    for run in argv:
        w.writerows(collect(run))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
