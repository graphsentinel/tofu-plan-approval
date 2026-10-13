#!/usr/bin/env bash
# @trace EV-010
# Claim: the normalized actions/rejections/field transitions of two CLEAN
#        repetitions are equal.
# Expected: at least two runs + equal normalized summaries -> 0.
# Equal times, UIDs or resourceVersions are NOT expected.
. "$(dirname "$0")/../scripts/lib.sh"
require jq; run_find
mapfile -t runs < <(ls -1d "$RUNS_DIR"/*/ 2>/dev/null | sort | tail -2)
[ "${#runs[@]}" -ge 2 ] || cannot_run "no second clean repetition (${#runs[@]} run)"

summary(){ # normalized: action set, rejection class, field transitions only
  local r="${1%/}"
  for tc in TC-01 TC-02 TC-03 TC-04; do
    [ -d "$r/$tc" ] || continue
    printf '%s|' "$tc"
    jq -r '[.resource_changes[]?.change.actions[]?]|sort|join(",")' "$r/$tc/applied.plan.json" 2>/dev/null \
      || jq -r '[.resource_changes[]?.change.actions[]?]|sort|join(",")' "$r/$tc/reviewed.plan.json" 2>/dev/null || printf '-'
    printf '|'
    for a in "$r/$tc"/object.*.json; do jq -r '.data.value // "?"' "$a" 2>/dev/null | tr -d '\n'; done
    printf '|'
    cat "$r/$tc"/*.rc 2>/dev/null | tr '\n' ','
    printf '\n'
  done
}
a=$(summary "${runs[0]}"); b=$(summary "${runs[1]}")
[ -n "$a" ] || cannot_run "the first run has no record that can be normalized"
[ "$a" = "$b" ] || fail "the two repetitions differ: $(diff <(echo "$a") <(echo "$b") | head -4 | tr '\n' ' ')"
pass "the normalized summaries of two clean repetitions are equal"
