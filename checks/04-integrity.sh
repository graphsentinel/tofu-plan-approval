#!/usr/bin/env bash
# @trace EV-004
# Claim: the archive files match MANIFEST.sha256.
# LIMIT: this checks the archive against ITS OWN list. It is NOT independent
# tamper evidence; keep the manifest digest somewhere else.
. "$(dirname "$0")/../scripts/lib.sh"
run_find
m="$RUN_ROOT/MANIFEST.sha256"
[ -s "$m" ] || cannot_run "no MANIFEST.sha256: the run was not closed"
( cd "$RUN_ROOT" && sha256sum -c --quiet MANIFEST.sha256 ) \
  || fail "the archive does not match its manifest"
pass "the archive matches its own manifest (NOT independent evidence)"
