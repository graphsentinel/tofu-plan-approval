#!/usr/bin/env bash
# @trace EV-014
# DECISION GATE. H: on the pinned setup, with the saved plan identity kept and
# state locking in use, an independent writer can change data.value in TC-02
# or TC-04.
#
#   0  = H SUPPORTED
#   1  = H REFUTED       only with valid controls and complete observation
#   77 = INCONCLUSIVE    a precondition or observation is missing; NOT a refutation
#
# Broken RBAC, an unreachable source, a controller that did not start or an
# audit gap does NOT count as a refutation.
. "$(dirname "$0")/../scripts/lib.sh"
require jq; run_find
K="$(dirname "$0")"

# --- preconditions: no refutation can be written before these pass ---
"$K/09-control.sh" >/dev/null 2>&1 || cannot_run "inconclusive: the single-writer control is not valid"
"$K/02-audit.sh"   >/dev/null 2>&1 || cannot_run "inconclusive: audit observation incomplete"
"$K/03-lock.sh"    >/dev/null 2>&1 || cannot_run "inconclusive: lock precondition not shown"
"$K/10-repeat.sh"  >/dev/null 2>&1 || cannot_run "inconclusive: no two full repetitions"

# --- support ---
support=""
# Plain and unambiguous on purpose: `cmd && x=$? || x=$?` works but is hard
# to read, and $? semantics were already measured wrong once in this project.
"$K/06-same-artifact.sh"   >/dev/null 2>&1; d2=$?
"$K/08-later-overwrite.sh" >/dev/null 2>&1; d4=$?
[ "$d4" -eq 77 ] && cannot_run "inconclusive: TC-04 inconclusive (barrier/opportunity missing)"

# TC-02 support: the outside writer could change the field AFTER the approval.
# Check 06 must pass too; otherwise the observation is incomplete, not support.
[ "$d2" -eq 77 ] && cannot_run "inconclusive: TC-02 observation incomplete"
t2=$(scenario_dir TC-02 2>/dev/null) && \
  v2=$(jq -r '.data.value // "?"' "$t2/object.10-after-intervention.json" 2>/dev/null) || v2="?"
[ "$v2" = "C" ] && [ "$d2" -eq 0 ] && support="$support TC-02"
# TC-04 support: if 08 passed, the Flux-actor B->C is verified.
[ "$d4" -eq 0 ] && support="$support TC-04"

if [ -n "${support// }" ]; then
  echo "H SUPPORTED ->$support  (the GitOps-specific sentence needs TC-04: $([ "$d4" -eq 0 ] && echo PRESENT || echo ABSENT))"
  exit 0
fi
fail "refuted: with valid controls and complete observation the second writer could not change the field in TC-02/TC-04; H rejected for this setup"
