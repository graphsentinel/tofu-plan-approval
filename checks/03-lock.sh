#!/usr/bin/env bash
# @trace EV-003
# Claim: while a real lock holder exists, a SECOND runner is rejected FOR THE LOCK.
# Expected: second run non-zero + lock reason in stderr -> 0. A rejection for
# another reason does NOT count as lock evidence.
. "$(dirname "$0")/../scripts/lib.sh"
run_find
d=$(scenario_dir TC-03) || exit 77
lk="$d/lock-contention.stderr"
[ -s "$lk" ] || cannot_run "lock contention precondition not run ($lk missing)"
rc=$(cat "$d/lock-contention.rc" 2>/dev/null || echo 0)
[ "$rc" -ne 0 ] || fail "the second runner SUCCEEDED while the lock was held (rc=0)"
grep -qiE 'lock|Locking|state blob is already locked' "$lk" \
  || fail "rejected, but the reason is not the lock: class unclear"
pass "lock contention observed and the reason is the lock"
