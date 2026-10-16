#!/usr/bin/env bash
# @trace EV-022
# Claim: the pre-apply check gives the expected decision on synthetic plans covering update, nested paths, values
#        unknown until apply, drift the reviewer already saw, create, delete, replace, data sources, child modules,
#        and fails closed on empty, unreadable or errored plans and unknown actions.
# Expected: gate/test/run.sh exits 0. Needs only bash and jq; reads no run.
. "$(dirname "$0")/../scripts/lib.sh"
require jq
out=$("$(dirname "$0")/../gate/test/run.sh" 2>&1); rc=$?
[ "$rc" = 0 ] || fail "gate unit tests: $(printf '%s\n' "$out" | grep -E 'FAIL|passed=' | head -3 | tr '\n' ' ')"
pass "gate unit tests: $(printf '%s\n' "$out" | tail -1)"
