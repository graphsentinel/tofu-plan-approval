#!/usr/bin/env bash
# @trace EV-019 · TC-06
# Claim: the pre-apply check (gate/plan-drift-gate.sh), which compares the live values with the values the reviewer
#        saw only at the paths the reviewed plan changes, stops the saved plan when a second writer changed such a
#        path, and lets it through when nobody did.
# Expected: drift path -> planned-field drift found, plan not applied, field stays C, state serial unchanged;
#           clean path -> no planned-field drift, plan applied, field A -> B.  0 when both hold.
. "$(dirname "$0")/../scripts/lib.sh"
require jq; run_find
top=$(scenario_dir TC-06) || exit 77
for sub in drift clean; do
  required_files "$top/$sub/gate.planned-field-drift" "$top/$sub/gate.decision" \
                 "$top/$sub/object.10-before-gate.json" "$top/$sub/object.20-after-gate.json" \
                 "$top/$sub/state.10-before-gate.summary.json" "$top/$sub/state.20-after-gate.summary.json"
done
v(){ jq -r '.data.value // "?"' "$1"; }
s(){ jq -r '.serial // empty' "$1"; }
D="$top/drift"; C="$top/clean"
[ "$(v "$D/object.10-before-gate.json")" = C ] || cannot_run "drift path: the second writer did not set C"
[ "$(v "$C/object.10-before-gate.json")" = A ] || cannot_run "clean path: the object was not A before the gate"
fd=$(cat "$D/gate.planned-field-drift"); fc=$(cat "$C/gate.planned-field-drift")
case "$fd$fc" in *UNKNOWN*|'') cannot_run "the gate could not compute planned-field drift" ;; esac
[ "$fd" -gt 0 ] || fail "drift path: the gate found no drift in a planned attribute although the field was C"
[ "$(cat "$D/gate.decision")" = block ] && [ ! -e "$D/apply.rc" ] || fail "drift path: the saved plan was applied"
[ "$(v "$D/object.20-after-gate.json")" = C ] || fail "drift path: the field changed although the plan was blocked"
[ "$(s "$D/state.10-before-gate.summary.json")" = "$(s "$D/state.20-after-gate.summary.json")" ] \
  || fail "drift path: the gate changed the state serial"
[ "$fc" = 0 ] || fail "clean path: the gate reported drift in a planned attribute with no second writer ($fc)"
[ "$(cat "$C/gate.decision")" = apply ] && [ "$(cat "$C/apply.rc" 2>/dev/null)" = 0 ] || fail "clean path: the approved plan was not applied"
[ "$(v "$C/object.20-after-gate.json")" = B ] || fail "clean path: the field is not B after the apply"
pass "drift path blocked (field stays C, serial unchanged); clean path applied A -> B"
