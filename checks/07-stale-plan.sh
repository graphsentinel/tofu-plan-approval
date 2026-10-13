#!/usr/bin/env bash
# @trace EV-007 · TC-03
# Claim: after a competing apply advanced the serial on the SAME lineage, the earlier plan is
#        rejected FOR THE STATE and does NOT change the target.
# The baseline is the state the plan was made from (after the lock precondition, which itself
# destroys and re-creates the object and so moves the serial), not the scenario's start.
# Expected: rejection + stale-state reason + no target mutation -> 0.
# Any non-zero code does NOT count as a "stale plan rejection".
. "$(dirname "$0")/../scripts/lib.sh"
require jq; run_find
d=$(scenario_dir TC-03) || exit 77
required_files "$d/state.05-after-lock.summary.json" "$d/stale-plan-apply.rc" "$d/stale-plan-apply.stderr" \
               "$d/state.10-after-competitor.summary.json" "$d/object.20-after-stale-plan.json"

l0=$(jq -r '.lineage // empty' "$d/state.05-after-lock.summary.json")
l1=$(jq -r '.lineage // empty' "$d/state.10-after-competitor.summary.json")
s0=$(jq -r '.serial  // empty' "$d/state.05-after-lock.summary.json")
s1=$(jq -r '.serial  // empty' "$d/state.10-after-competitor.summary.json")
[ -n "$l0" ] && [ -n "$s0" ] && [ -n "$s1" ] || cannot_run "state summary missing"
[ "$l0" = "$l1" ] || cannot_run "lineage changed ($l0 -> $l1): this test needs the serial to advance on the SAME lineage"
[ "$s1" -gt "$s0" ] || cannot_run "serial did not advance ($s0 -> $s1): the competing apply had no effect, test not valid"

rc=$(cat "$d/stale-plan-apply.rc")
[ "$rc" -ne 0 ] || fail "the earlier plan was APPLIED (rc=0): the protection expectation is falsified"
# the diagnostic title of the pinned OpenTofu, ANSI colours removed; a different error does not pass
sed 's/\x1b\[[0-9;]*m//g' "$d/stale-plan-apply.stderr" | grep -q 'Error: Saved plan is stale' \
  || fail "rejected, but the reason is not stale state: class unclear (an unrelated error does not pass this test)"

before=$(jq -r '.data.value // "?"' "$d/object.10-after-competitor.json")
after=$(jq -r '.data.value // "?"' "$d/object.20-after-stale-plan.json")
[ "$before" = "$after" ] || fail "the target changed after the rejected attempt ($before -> $after)"
pass "competing apply moved the serial $s0->$s1, earlier plan rejected for the state, target unchanged ($after)"
