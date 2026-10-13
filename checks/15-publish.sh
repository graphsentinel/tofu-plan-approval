#!/usr/bin/env bash
# @trace EV-018
# Claim: the published repository is REALLY reachable.
# 0  = PUBLISH_URL answers HTTP 200 and LICENSE + README.md are in place
# 1  = PUBLISH_URL is set but not reachable (the claim is FALSE)
# 77 = PUBLISH_URL is still empty (not published yet: NOT counted as passed)
# scripts/verify.sh --publish treats 77 as a failure: a publication gate is never skipped silently.
. "$(dirname "$0")/../scripts/lib.sh"
require curl
[ -f "$ROOT/publish.env" ] || cannot_run "publish.env missing"
# shellcheck disable=SC1091
. "$ROOT/publish.env"
[ -n "${PUBLISH_URL:-}" ] || cannot_run "PUBLISH_URL is empty: not published yet"

CODE=$(curl -sSL -o /dev/null -w '%{http_code}' --max-time 20 "$PUBLISH_URL" 2>/dev/null)
[ "$CODE" = "200" ] || fail "PUBLISH_URL not reachable (HTTP ${CODE:-none}): $PUBLISH_URL"

# A reachable version also needs run instructions and a license
for f in LICENSE README.md; do
  [ -s "$ROOT/$f" ] || fail "$f missing: a published lab needs a reachable version, run instructions and a license"
done
pass "published and reachable (HTTP 200), LICENSE and README in place: $PUBLISH_URL"
