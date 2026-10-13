#!/usr/bin/env bash
# @trace EV-002
# Claim: the audit records exist WITH THE REQUIRED BODIES; no observation gap.
# Expected: RequestResponse events with responseObject for the target CM -> 0.
# NOTE: a missing file must NOT be read as "no write happened".
. "$(dirname "$0")/../scripts/lib.sh"
require jq
run_find
audit_all; log="$AUDIT_LOG"


pol="$ROOT/k3d/audit-policy.yaml"
[ -s "$pol" ] || cannot_run "audit policy not archived"

total=$(wc -l < "$log")
target=$(jq -c 'select(.objectRef.resource=="configmaps" and .objectRef.namespace=="t27")' "$log" 2>/dev/null | wc -l)
[ "$target" -gt 0 ] || fail "no configmap audit event at all for the target namespace ($total lines exist)"

# Was the RequestResponse level really applied: responseObject on mutations
mut=$(jq -c 'select(.objectRef.resource=="configmaps" and .objectRef.namespace=="t27"
             and (.verb|test("create|update|patch|delete")) and .stage=="ResponseComplete")' "$log" | wc -l)
[ "$mut" -gt 0 ] || cannot_run "no completed mutation event: the scenario may not have run"
nobody=$(jq -c 'select(.objectRef.resource=="configmaps" and .objectRef.namespace=="t27"
             and (.verb|test("create|update|patch")) and .stage=="ResponseComplete"
             and (.responseObject==null))' "$log" | wc -l)
[ "$nobody" -eq 0 ] || fail "$nobody mutations lack responseObject: RequestResponse level not applied"
pass "$target audit events, $mut completed mutations, bodies complete"
