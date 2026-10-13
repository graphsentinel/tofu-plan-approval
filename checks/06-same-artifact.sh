#!/usr/bin/env bash
# @trace EV-006 · TC-02
# Claim: the SAME artifact was applied to a changed object with an UNCHANGED
#        state identity, and the outcome was CLASSIFIED.
# Expected: equal hash + same state identity + classifiable apply outcome -> 0.
# Whether the apply writes B or is rejected is NOT FIXED in advance.
. "$(dirname "$0")/../scripts/lib.sh"
require jq; run_find
d=$(scenario_dir TC-02) || exit 77
required_files "$d/reviewed.tfplan" "$d/applied.tfplan" \
               "$d/object.10-after-intervention.json" "$d/apply.rc"

h1=$(sha256sum "$d/reviewed.tfplan" | awk '{print $1}')
h2=$(sha256sum "$d/applied.tfplan"  | awk '{print $1}')
[ "$h1" = "$h2" ] || fail "the approved and the applied artifact DIFFER (a re-plan leaked in)"

l1=$(jq -r '.lineage // empty' "$d/state.00-start.summary.json" 2>/dev/null)
l2=$(jq -r '.lineage // empty' "$d/state.10-after-intervention.summary.json" 2>/dev/null)
s1=$(jq -r '.serial  // empty' "$d/state.00-start.summary.json" 2>/dev/null)
s2=$(jq -r '.serial  // empty' "$d/state.10-after-intervention.summary.json" 2>/dev/null)
[ -n "$l1" ] && [ -n "$l2" ] || cannot_run "state summary missing"
[ "$l1" = "$l2" ] && [ "$s1" = "$s2" ] \
  || fail "the intervention changed the state (lineage $l1->$l2, serial $s1->$s2): TC-02 assumption broken"

v=$(jq -r '.data.value // "?"' "$d/object.10-after-intervention.json")
[ "$v" = "C" ] || cannot_run "the second writer could not write C (seen: $v)"

rc=$(cat "$d/apply.rc")
end=$(jq -r '.data.value // "?"' "$d/object.20-after-apply.json" 2>/dev/null)
if [ "$rc" -eq 0 ]; then class="SUCCEEDED(end=$end)"
elif grep -qiE 'conflict|field manager|immutable' "$d/apply.stderr" 2>/dev/null; then class="API_CONFLICT"
elif grep -qiE 'saved plan is stale|state.*chang' "$d/apply.stderr" 2>/dev/null; then class="STALE_STATE"
else class="UNCLASSIFIED"; fi
[ "$class" != "UNCLASSIFIED" ] || fail "the apply outcome could not be classified (rc=$rc)"
pass "hash equal, state identity same, outside value C, apply outcome: $class"
