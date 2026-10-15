#!/usr/bin/env bash
# @trace EV-020 · TC-06
# Claim: in this pinned setup the two obvious pre-apply drift gates cannot tell the two TC-06 paths apart: on the
#        clean path, with no second writer, `tofu plan -refresh-only -detailed-exitcode` exits 2 and the refresh-only
#        JSON reports drift, although the object's values did not change: the provider stores empty maps as null
#        (binary_data, metadata.annotations, metadata.labels) and reads them back as {} on refresh.
# Expected: clean path gate1 exit 2, gate2 >= 1, and the object's before/after differ only by null <-> {} -> 0.
. "$(dirname "$0")/../scripts/lib.sh"
require jq; run_find
top=$(scenario_dir TC-06) || exit 77
C="$top/clean"
required_files "$C/gate-exitcode.rc" "$C/gate.drift-count" "$C/refresh.plan.json"
g1=$(cat "$C/gate-exitcode.rc"); g2=$(cat "$C/gate.drift-count")
case "$g2" in ''|*[!0-9]*) cannot_run "gate 2 drift count not produced" ;; esac
[ "$g1" = 2 ] || fail "clean path: refresh-only -detailed-exitcode exited $g1, not 2"
[ "$g2" -ge 1 ] || fail "clean path: the refresh-only JSON reported no drift"
# every difference is an empty map read back where the state had null: equal once {} is treated as null
only_empty=$(jq -r 'def norm: walk(if . == {} then null else . end);
  [.resource_drift[]? | select(.address == "kubernetes_config_map.t27") | .change
   | {raw: (.before != .after), norm: ((.before | norm) == (.after | norm))}] | first
  | if . == null then "none" elif .raw and .norm then "yes" else "no" end' "$C/refresh.plan.json")
[ "$only_empty" = yes ] || fail "clean path: the object's drift is not only null -> {} ($only_empty)"
pass "clean path: gate1 exit $g1, gate2 $g2 drift report(s); the only differences are empty maps stored as null and read back as {}"
