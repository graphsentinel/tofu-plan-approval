#!/usr/bin/env bash
# @trace EV-011
# Claim: the EXPERIMENT ACTORS did not write outside the experiment, and the
#        experiment cluster was removed.
# Expected: no actor spill-over + no lab cluster -> 0.
#
# SCOPE NOTE. Because of the audit policy's catch-all "level: Metadata" rule,
# EVERY configmap operation in the cluster is logged: k3s leader election,
# Flux's own records, kube-system housekeeping. Those are NOT isolation
# violations. The question is whether the EXPERIMENT ACTORS (the OpenTofu
# runner = system:admin, and the second-writer SA) wrote outside the
# experiment namespaces.
. "$(dirname "$0")/../scripts/lib.sh"
require jq k3d
run_find
audit_all; log="$AUDIT_LOG"

# k3d WRITES kube-public/local-registry-hosting as system:admin when it sets
# up the registry. That is cluster provisioning, not the experiment. It is
# excepted BY NAME instead of widening the rule: any other name fails the gate.
EXCEPT='kube-public/local-registry-hosting'

# second-writer: the actor's name; dis-yazar: its name in the reference runs (recorded before the translation)
spill=$(jq -r --arg ex "$EXCEPT" '
  select(
    .objectRef.resource == "configmaps"
    and (.verb | test("create|update|patch|delete"))
    and .stage == "ResponseComplete"
    and ((.responseStatus.code // 0) < 300)
    and .objectRef.namespace != null
    and ((.objectRef.namespace | test("^t27$|^t27-state$")) | not)
    and ((((.user.username // "") + " " + (.impersonatedUser.username // ""))
          | test("second-writer|dis-yazar")) or ((.user.username // "") == "system:admin"))
  )
  | (.objectRef.namespace + "/" + (.objectRef.name // "?"))
  | select(. != $ex)
' "$log" 2>/dev/null | sort -u | tr '\n' ' ')

[ -z "${spill// }" ] || fail "experiment actors wrote outside the experiment: $spill"

cluster_exists && fail "the experiment cluster is still up: scripts/experiment.sh clean"
pass "experiment actors did not write outside the experiment, cluster removed"
