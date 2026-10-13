#!/usr/bin/env bash
# @trace EV-016
# MANUAL. The approver identity and the origin of the INDEPENDENT digest need a
# human check. A file EXISTING is not enough: the archive verifying its own
# hash list is NOT independent assurance.
. "$(dirname "$0")/../scripts/lib.sh"
run_find 2>/dev/null || true
cannot_run "human check: is the approver in approval.json real; was the MANIFEST.sha256 digest kept OUTSIDE the archive"
