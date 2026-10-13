#!/usr/bin/env bash
# @trace EV-009 · TC-05
# Claim: the four single-writer sub-runs give A,B,B,B in order and contain NO
#        mutation by a second actor.
# Expected: values as expected + no foreign-actor mutation -> 0.
# An unexplained change in the control invalidates the CAUSAL attribution to
# the second writer; it is NOT a refutation of the hypothesis.
. "$(dirname "$0")/../scripts/lib.sh"
require jq; run_find
top="$RUN_ROOT/TC-05"
[ -d "$top" ] || cannot_run "TC-05 was not run"
exp=(A B B B); i=0; bad=""
for sub in 01 02 03 04; do
  f="$top/sub-$sub/object.20-after-apply.json"
  [ -s "$f" ] || cannot_run "sub-$sub record missing"
  v=$(jq -r '.data.value // "?"' "$f")
  [ "$v" = "${exp[$i]}" ] || bad="$bad sub-$sub(expected=${exp[$i]} actual=$v)"
  i=$((i+1))
done
[ -z "${bad// }" ] || fail "UNEXPLAINED value in the control:$bad: causal attribution invalid"

audit_prepare TC-05; log="$AUDIT_LOG"
if [ -s "$log" ]; then
  # second-writer: the actor's name; dis-yazar: its name in the reference runs (recorded before the translation)
  foreign=$(jq -c 'select(.objectRef.resource=="configmaps" and .objectRef.name=="t27"
        and (.verb|test("update|patch")) and .stage=="ResponseComplete"
        and (((.user.username // "") + " " + (.impersonatedUser.username // "")) | test("second-writer|dis-yazar|kustomize-controller|flux")))' "$log" | wc -l)
  [ "$foreign" -eq 0 ] || fail "$foreign foreign-actor mutations in the single-writer control: isolation broken"
fi
pass "four controls A,B,B,B; no foreign-actor mutation"
