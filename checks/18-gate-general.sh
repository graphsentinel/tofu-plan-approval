#!/usr/bin/env bash
# @trace EV-021 · TC-06
# Claim: the pre-apply check (gate/plan-drift-gate.sh) is not tied to TC-02's field: on a real cluster it lets
#        through a plan when the second writer changed something the plan does not change (an annotation), blocks
#        a plan that adds a label when the second writer set that label, lets the same plan through when nobody
#        did (although the provider reads empty annotations back as {}), and does not treat a create as drift.
# Expected: unrelated -> apply, B, the annotation reported as drift outside the planned paths;
#           labels-drift -> block, label team stays c, state serial unchanged; labels-clean -> apply, label team b;
#           create-clean -> apply, B, t27-extra created.  0 when all hold.
. "$(dirname "$0")/../scripts/lib.sh"
require jq; run_find
top=$(scenario_dir TC-06) || exit 77
for sub in unrelated labels-drift labels-clean create-clean; do
  required_files "$top/$sub/gate.stdout" "$top/$sub/gate.rc" "$top/$sub/gate.decision" \
                 "$top/$sub/object.20-after-gate.json" "$top/$sub/state.10-before-gate.summary.json" \
                 "$top/$sub/state.20-after-gate.summary.json"
done
v(){ jq -r '.data.value // "?"' "$1"; }
lab(){ jq -r '.metadata.labels.team // "none"' "$1"; }
s(){ jq -r '.serial // empty' "$1"; }
dec(){ cat "$top/$1/gate.decision"; }
applied(){ [ "$(dec "$1")" = apply ] && [ "$(cat "$top/$1/apply.rc" 2>/dev/null)" = 0 ]; }
for sub in unrelated labels-drift labels-clean create-clean; do
  case "$(cat "$top/$sub/gate.rc")" in 0|1) ;; *) cannot_run "$sub: the check could not decide (exit $(cat "$top/$sub/gate.rc"))" ;; esac
done
U="$top/unrelated"
[ "$(jq -r '.metadata.annotations.note // "none"' "$U/object.10-before-gate.json")" = second-writer ] \
  || cannot_run "unrelated: the second writer's annotation is not on the object before the gate"
applied unrelated || fail "unrelated: a change outside the planned paths blocked the plan"
[ "$(v "$U/object.20-after-gate.json")" = B ] || fail "unrelated: the field is not B after the apply"
jq -e '[.unplanned_drift[].path] | any(test("annotations"))' "$U/gate.stdout" >/dev/null \
  || fail "unrelated: the annotation was not reported as drift outside the planned paths"
L="$top/labels-drift"
[ "$(lab "$L/object.10-before-gate.json")" = c ] || cannot_run "labels-drift: the second writer did not set team=c"
[ "$(dec labels-drift)" = block ] && [ ! -e "$L/apply.rc" ] || fail "labels-drift: the plan was applied over the changed label"
jq -e '[.conflicts[].path] | any(test("^metadata\\[0\\]\\.labels"))' "$L/gate.stdout" >/dev/null \
  || fail "labels-drift: the conflict is not on the labels path"
[ "$(lab "$L/object.20-after-gate.json")" = c ] || fail "labels-drift: the label changed although the plan was blocked"
[ "$(s "$L/state.10-before-gate.summary.json")" = "$(s "$L/state.20-after-gate.summary.json")" ] \
  || fail "labels-drift: the gate changed the state serial"
applied labels-clean || fail "labels-clean: the plan was blocked with no second writer"
[ "$(lab "$top/labels-clean/object.20-after-gate.json")" = b ] || fail "labels-clean: label team is not b after the apply"
applied create-clean || fail "create-clean: a plan with a create was blocked with no second writer"
[ "$(v "$top/create-clean/object.20-after-gate.json")" = B ] || fail "create-clean: the field is not B after the apply"
[ "$(v "$top/create-clean/extra.20-after-gate.json")" = extra ] || fail "create-clean: t27-extra was not created"
pass "unrelated annotation -> applied (reported as drift outside the plan); label conflict -> blocked; labels and create without a second writer -> applied"
