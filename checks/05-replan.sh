#!/usr/bin/env bash
# @trace EV-005 · TC-01
# Claim: an UPDATE was applied instead of the reviewed no-op plan, and the API wrote C->A.
# Expected: a SEMANTIC difference between the two plans + a real write by the apply -> 0.
# A file hash difference alone is NOT ENOUGH.
. "$(dirname "$0")/../scripts/lib.sh"
require jq; run_find
d=$(scenario_dir TC-01) || exit 77
required_files "$d/reviewed.plan.json" "$d/applied.plan.json" \
               "$d/object.10-after-intervention.json" "$d/object.20-after-apply.json"

acts(){ jq -r '[.resource_changes[]?.change.actions[]?] | sort | join(",")' "$1"; }
r=$(acts "$d/reviewed.plan.json"); a=$(acts "$d/applied.plan.json")
[ "$r" != "$a" ] || fail "reviewed and applied plans have the SAME action set ($r): expectation falsified"

before=$(jq -r '.data.value // "?"' "$d/object.10-after-intervention.json")
after=$(jq -r '.data.value // "?"'  "$d/object.20-after-apply.json")
[ "$before" = "C" ] || cannot_run "the second writer could not write C (seen: $before): causality cannot be attributed"
[ "$after" = "A" ] || fail "value after apply is not A: $after"
pass "plan difference: [$r] -> [$a]; API $before -> $after"
