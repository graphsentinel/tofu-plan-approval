#!/usr/bin/env bash
# @trace EV-015
# MANUAL. Whether the workflow failure is USEFUL, and its value as a talk, is a
# human judgement; a script cannot give it and does NOT try to.
# An ordinary drift demonstration does not turn into talk value automatically.
. "$(dirname "$0")/../scripts/lib.sh"
cannot_run "human judgement: is the finding a useful workflow failure, or a tutorial/regression suite"
