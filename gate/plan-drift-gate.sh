#!/usr/bin/env bash
# ==================================================================
# Pre-apply check for an approved OpenTofu saved plan: at every path the plan changes, is the live value still the
# one recorded in the approved plan? Run it in the root module, right before `tofu apply <plan>`, with the same
# variables the plan was made with.
#
#   gate/plan-drift-gate.sh [--strict] <reviewed.tfplan> [-var ... | -var-file=... | -lock-timeout=...]
#   gate/plan-drift-gate.sh [--strict] --compare <reviewed.json> <refresh.json>   only the comparison, on
#                                                                                 `tofu show -json` output
#   --strict   also block on drift outside the planned paths (by default it is reported, not blocked)
#
# What it does: `tofu show -json` of the reviewed plan; a refresh-only saved plan (`tofu plan -refresh-only -out`),
# which reads the live infrastructure without changing it or the state; `tofu show -json` of that; then the
# comparison in gate/planned-drift.jq (which paths count, and what is not checked, is described there).
#
# Exit status:
#   0  apply: no path the plan changes differs from the approved plan's recorded value
#   1  block: one does; re-plan and re-approve
#   2  could not decide (a command failed; a plan is empty, unreadable, errored or unsupported; options that would
#      narrow or change the refresh; different variables). Treat it as block.
# stdout: the report (JSON: decision, conflicts, drift outside the planned paths); addresses and paths, no values.
# GATE_DIR=<dir> keeps the intermediate files; they hold live values and may hold secrets (created mode 0600).
# By default they go to a temporary directory that is removed.
#
# Not covered: a write between this check and the apply; inputs the plan was computed from; values the provider
# does not read back; objects outside the state; anything another writer does after the apply. The refresh runs in
# the current workspace and data directory (TF_WORKSPACE, TF_DATA_DIR): run it where the apply will run.
# ==================================================================
set -uo pipefail
umask 077
HERE="$(cd "$(dirname "$0")" && pwd)"
JQ_PROG="$HERE/planned-drift.jq"
usage(){ sed -n '3,13p' "$0" | sed 's/^# \?//' >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "plan-drift-gate: jq not found" >&2; exit 2; }
# jq builds that compare numbers as doubles would see 2^53 and 2^53+1 as equal: such a jq cannot be trusted here
[ "$(jq -n --argjson a 9007199254740992 --argjson b 9007199254740993 '$a == $b' 2>/dev/null)" = false ] \
  || { echo "plan-drift-gate: this jq compares large integers imprecisely (use jq 1.7 or later)" >&2; exit 2; }

STRICT=false
[ "${1:-}" = --strict ] && { STRICT=true; shift; }

decide(){ # decide <reviewed.json> <refresh.json>
  local out
  out=$(jq -n --slurpfile r "$1" --slurpfile f "$2" --argjson strict "$STRICT" -f "$JQ_PROG") \
    || { echo "plan-drift-gate: could not decide (see the jq error above); treat as block" >&2; exit 2; }
  printf '%s\n' "$out"
  case "$(jq -r '.decision' <<<"$out")" in
    apply) exit 0 ;;
    block) echo "plan-drift-gate: BLOCK: re-plan and re-approve" >&2; exit 1 ;;
    *)     exit 2 ;;
  esac
}

if [ "${1:-}" = --compare ]; then
  [ $# -eq 3 ] || usage
  decide "$2" "$3"
fi
[ $# -ge 1 ] || usage
case "$1" in -*) usage ;; esac
PLAN="$1"; shift
[ -f "$PLAN" ] || { echo "plan-drift-gate: no such plan file: $PLAN" >&2; exit 2; }
# The refresh must cover what the plan covers, under the same inputs: only variable, lock (on) and output options
# pass; TF_CLI_ARGS* (options added from the environment) is refused. Variables set through TF_VAR_* are not
# inspected here; their effect is caught by the comparison, which requires both plans to have the same variables.
for a in "$@"; do
  case "$a" in
    -var|-var=*|-var-file|-var-file=*|-lock|-lock=true|-lock-timeout|-lock-timeout=*|-parallelism=*|-no-color|-compact-warnings) ;;
    -*) echo "plan-drift-gate: option not allowed for the refresh: $a" >&2; exit 2 ;;
  esac
done
for v in $(compgen -v TF_CLI_ARGS); do
  [ -z "${!v:-}" ] || { echo "plan-drift-gate: $v is set; unset it so the refresh is the one you see" >&2; exit 2; }
done

command -v tofu >/dev/null 2>&1 || { echo "plan-drift-gate: tofu not found" >&2; exit 2; }

if [ -n "${GATE_DIR:-}" ]; then
  D="$GATE_DIR"; mkdir -p "$D" || exit 2
else
  D=$(mktemp -d) || exit 2; trap 'rm -rf "$D"' EXIT
fi

# files left by an earlier run would keep their permissions and contents: start from none
rm -f "$D/reviewed.json" "$D/reviewed-show.log" "$D/refresh.tfplan" "$D/refresh-plan.log" "$D/refresh.json" "$D/refresh-show.log"
tofu show -json "$PLAN" > "$D/reviewed.json" 2> "$D/reviewed-show.log" \
  || { echo "plan-drift-gate: tofu show of the reviewed plan failed" >&2; exit 2; }
tofu plan -input=false -refresh-only "$@" -out "$D/refresh.tfplan" > "$D/refresh-plan.log" 2>&1 \
  || { echo "plan-drift-gate: the refresh-only plan failed" >&2; exit 2; }
tofu show -json "$D/refresh.tfplan" > "$D/refresh.json" 2> "$D/refresh-show.log" \
  || { echo "plan-drift-gate: tofu show of the refresh-only plan failed" >&2; exit 2; }
decide "$D/reviewed.json" "$D/refresh.json"
