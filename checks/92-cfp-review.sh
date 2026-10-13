#!/usr/bin/env bash
# @trace EV-017
# MANUAL. The abstract's sentences, the reachable publication and the license
# need a human review. A reachability check does not prove the meaning is right.
. "$(dirname "$0")/../scripts/lib.sh"
cannot_run "human review: does every abstract sentence meet the condition next to it"
