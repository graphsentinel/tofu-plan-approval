#!/usr/bin/env bash
# @trace EV-008 · TC-04
# Claim: AFTER a successful apply and B in the API, a B->C change on the SAME
#        UID is seen and attributed to the Flux actor.
# Expected: barrier passed + same UID + Flux-actor mutation in the audit log -> 0.
# The final value being C alone is NOT ENOUGH.
. "$(dirname "$0")/../scripts/lib.sh"
require jq; run_find
d=$(scenario_dir TC-04) || exit 77
required_files "$d/object.10-after-apply.json" "$d/object.30-window-end.json" "$d/opportunities.jsonl"

# Apply completion barrier: without B, TC-04 is not valid.
b=$(jq -r '.data.value // "?"' "$d/object.10-after-apply.json")
[ "$b" = "B" ] || cannot_run "B not seen after apply ($b): TC-04 inconclusive, not a refutation"

u1=$(jq -r '.metadata.uid // empty' "$d/object.10-after-apply.json")
u2=$(jq -r '.metadata.uid // empty' "$d/object.30-window-end.json")
[ -n "$u1" ] && [ "$u1" = "$u2" ] \
  || fail "UID changed ($u1 -> $u2): it CANNOT be concluded that the same object was overwritten"

# Opportunities: did a reconciliation really complete inside the window.
f=$(jq -s '[.[] | select(.lastHandledReconcileAt != null)] | length' "$d/opportunities.jsonl")
[ "$f" -gt 0 ] || cannot_run "no completed reconciliation opportunity: the opportunity metric is undefined"

# Actor: the AUTHENTICATED user. A fieldManager name alone is NOT an identity.
# Only a PERSISTED write counts: Flux dry-runs every apply (?dryRun=All), and a dry run writes nothing.
# The change is read from the persisted writes in resourceVersion order (checks/target-writes.jq): B before,
# C after, by the Flux actor, on the namespace t27 object whose UID the snapshots recorded.
audit_prepare TC-04; log="$AUDIT_LOG"

w=$(jq -s -c --arg ns t27 --arg name t27 -f "$ROOT/checks/target-writes.jq" "$log") || cannot_run "the audit log could not be read"
[ "$(jq -r '.incomplete' <<<"$w")" = 0 ] || cannot_run "persisted writes without resourceVersion or uid"
[ "$(jq -r '.ambiguous' <<<"$w")" = 0 ]  || cannot_run "equal resourceVersions written by different actors: attribution ambiguous"
# every persisted write is to the object the snapshots show (same uid): no other object's transition counts
[ "$(jq -c '.uids' <<<"$w")" = "[\"$u1\"]" ] || fail "persisted writes span another object than UID $u1"
fluxbc=$(jq -r '[.flux_transitions | split(",")[] | select(. == "B->C")] | length' <<<"$w")
case "$fluxbc" in ''|*[!0-9]*) cannot_run "the audit log could not be read" ;; esac
[ "$fluxbc" -gt 0 ] || fail "$f opportunities ran but NO persisted Flux-actor write changed B to C: expectation falsified"

end=$(jq -r '.data.value // "?"' "$d/object.30-window-end.json")
pass "barrier B, UID stable, $f opportunities, $fluxbc persisted Flux-actor B->C write(s), window end=$end"
