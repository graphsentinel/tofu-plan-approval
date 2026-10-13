#!/usr/bin/env bash
# @trace EV-012
# Claim: the opportunity, API call and field mutation counts of TC-04 are re-derived from RAW records;
#        with a zero denominator the rate is null.
# Expected: 0 when the summary can be reproduced from the raw record.
# "Flaps per hour" is NOT used: it measures the scheduling policy.
#
# Counting rules (checks/target-writes.jq, shared with check 08), from the audit log of the target ConfigMap:
#   - an API call: a successful (code < 300) update/patch, completed;
#   - a dry run (dryRun=All) is an API call that writes nothing: counted, never a mutation.
#     Flux's kustomize-controller dry-runs every apply to detect drift;
#   - a field mutation: a persisted write whose data.value differs from the value before it. The value before
#     it is the previous persisted write in resourceVersion order. The request body cannot tell: a server-side
#     apply sends the NEW value, so request and response are equal even when the field changed.
. "$(dirname "$0")/../scripts/lib.sh"
require jq; run_find
d=$(scenario_dir TC-04) || exit 77
required_files "$d/opportunities.jsonl"
audit_prepare TC-04; log="$AUDIT_LOG"

opp=$(jq -s '[.[] | select(.lastHandledReconcileAt != null)] | length' "$d/opportunities.jsonl" 2>/dev/null)
m=$(jq -s -c --arg ns t27 --arg name t27 -f "$ROOT/checks/target-writes.jq" "$log" 2>"$RUN_ROOT/12-metrics.jq.stderr")

# FALSE-PASS GUARD: when jq fails nothing is computed and no result is produced.
fm=$(jq -r '.flux_mutations' <<<"${m:-null}" 2>/dev/null)
case "$fm" in
  ''|null|*[!0-9]*) cannot_run "mutation count not produced (jq error: $(head -1 "$RUN_ROOT/12-metrics.jq.stderr" 2>/dev/null | cut -c1-120))" ;;
esac
case "$opp" in
  ''|*[!0-9]*) cannot_run "opportunity count not produced" ;;
esac

[ "$(jq -r '.incomplete' <<<"$m")" = 0 ] || cannot_run "persisted writes without resourceVersion or uid: counts not attributable"
[ "$(jq -r '.ambiguous' <<<"$m")" = 0 ]  || cannot_run "equal resourceVersions written by different actors: attribution ambiguous"
[ "$(jq -r '.uids|length' <<<"$m")" = 1 ] || cannot_run "the object was recreated (or never written): counts span more than one object"
if [ "$opp" -eq 0 ]; then rate="null"; else rate=$(awk -v m="$fm" -v f="$opp" 'BEGIN{printf "%.3f", m/f}'); fi
jq -n --argjson f "$opp" --argjson m "$m" --arg o "$rate" \
   '{opportunities:$f} + $m + {flux_mutations_per_opportunity:(if $o=="null" then null else ($o|tonumber) end),
     note:"API calls and field mutations are counted SEPARATELY. A dry run writes nothing. A field mutation is a persisted write that changed data.value from the previous persisted value (resourceVersion order). The denominator is the number of completed opportunities; when it is zero the rate is null."}' \
   > "$d/metrics.json"
[ "$opp" -gt 0 ] || cannot_run "zero opportunities: rate null, no conclusion about non-convergence"
pass "opportunities=$opp flux_api_calls=$(jq -r .flux_calls <<<"$m") (dry_runs=$(jq -r .flux_dry_runs <<<"$m") writes=$(jq -r .flux_writes <<<"$m")) flux_field_mutations=$fm [$(jq -r .flux_transitions <<<"$m")] rate=$rate"
