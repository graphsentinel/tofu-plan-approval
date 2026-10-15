#!/usr/bin/env bash
# ==================================================================
# Runs the checks in checks/ledger.tsv against a recorded run and reports by EXIT CODE, never by output text.
#
#   scripts/verify.sh                   the latest run in runs/ (and the one before it, for the pair checks)
#   scripts/verify.sh --run DIR         a given run directory; its parent holds the runs the pair checks compare
#   scripts/verify.sh --reference       the published reference runs (evidence/reference), on a temporary copy;
#                                       needs only bash, jq and coreutils, no cluster
#   scripts/verify.sh --publish         also the publication gate EV-018 (PUBLISH_URL in publish.env)
#   --out FILE                          also write the result table (TSV) to FILE
#
# Exit code contract (unchanged from the checks):
#   0  every auto check PASSED, the manual ones reported as MANUAL
#   1  at least one check FAILED: the claim is false (takes precedence over 2)
#   2  at least one check COULD NOT RUN where it was expected to run (also: script missing, empty ledger,
#      result table not writable). A skip is never counted as passed.
#
# Expected non-runs, each named in the output, never silent:
#   MANUAL   kind=manual checks (EV-015/016/017) exit 77 by design: a human judgement
#   N/A      scope=host checks with --reference (they test this machine, not the record);
#            scope=tc06 checks with --reference (the reference runs were recorded before TC-06 existed);
#            scope=pair checks when only one run exists (they compare two runs)
#   GATE     EV-018 without --publish (it needs the published URL); with --publish a 77 there is a failure
# ==================================================================
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 2
RUN=""; REFERENCE=0; PUBLISH=0; OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --run)       RUN="${2:?--run needs a directory}"; shift ;;
    --reference) REFERENCE=1 ;;
    --publish)   PUBLISH=1 ;;
    --out)       OUT="${2:?--out needs a file}"; shift ;;
    *) sed -n '3,25p' "$0" | sed 's/^# \?//'; exit 2 ;;
  esac
  shift
done

if [ "$REFERENCE" = 1 ]; then
  [ -d evidence/reference ] || { echo "evidence/reference missing" >&2; exit 2; }
  # checks write derived files (metrics.json, combined.jsonl) into a run: never into the published evidence
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
  mkdir -p "$TMP/runs"
  for d in evidence/reference/*/; do [ -f "$d/MANIFEST.sha256" ] && cp -a "$d" "$TMP/runs/"; done
  # the reference is two runs: with fewer, the pair checks would turn into N/A instead of running
  [ "$(ls -1d "$TMP"/runs/*/ 2>/dev/null | wc -l)" -ge 2 ] || { echo "evidence/reference must hold two runs with a MANIFEST.sha256" >&2; exit 2; }
  export RUNS_DIR="$TMP/runs"
  RUN_ROOT="$(ls -1d "$RUNS_DIR"/*/ | sort | tail -1)"; RUN_ROOT="${RUN_ROOT%/}"
elif [ -n "$RUN" ]; then
  RUN_ROOT="$(cd "$RUN" && pwd)" || exit 2
  RUNS_DIR="$(dirname "$RUN_ROOT")"; export RUNS_DIR
else
  export RUNS_DIR="${RUNS_DIR:-$ROOT/runs}"
  RUN_ROOT="$(ls -1d "$RUNS_DIR"/*/ 2>/dev/null | sort | tail -1)"; RUN_ROOT="${RUN_ROOT%/}"
  [ -n "$RUN_ROOT" ] || { echo "no run in $RUNS_DIR: run scripts/lab.sh test (or use --reference)" >&2; exit 2; }
fi
export RUN_ROOT
# runs up to and including this one: the pair checks compare the last two of them
NRUNS=$(ls -1d "$RUNS_DIR"/*/ 2>/dev/null | sort | awk -v r="$RUN_ROOT/" '{print} $0==r{exit}' | wc -l)
# EV-010 compares the latest two runs in RUNS_DIR, so only the latest run can be verified
if [ "$(ls -1d "$RUNS_DIR"/*/ 2>/dev/null | sort | tail -1)" != "$RUN_ROOT/" ]; then
  echo "error: $RUN_ROOT is not the latest run in $RUNS_DIR (the pair checks compare the latest two)" >&2; exit 2
fi

P=0; F=0; S=0; M=0; N=0
ROWS=""
row(){ ROWS+="$1	$2	$3"$'\n'; printf '  %-8s %-7s %s\n' "$1" "$2" "$3"; }
echo "run: $(basename "$RUN_ROOT")  (runs available for the pair checks: $NRUNS)"
NROWS=0
while IFS=$'\t' read -r id claim script kind scope || [ -n "$id" ]; do
  case "$id" in \#*|id|"") continue ;; esac
  NROWS=$((NROWS+1))
  if [ "$kind" = gate ] && [ "$PUBLISH" = 0 ]; then row "$id" GATE "publication gate: scripts/verify.sh --publish"; N=$((N+1)); continue; fi
  if [ "$scope" = host ] && [ "$REFERENCE" = 1 ] && [ "$kind" != gate ]; then row "$id" N/A "checks this machine, not the recorded run"; N=$((N+1)); continue; fi
  if [ "$scope" = pair ] && [ "$NRUNS" -lt 2 ]; then row "$id" N/A "compares two runs; only one exists so far"; N=$((N+1)); continue; fi
  if [ "$scope" = tc06 ] && [ "$REFERENCE" = 1 ]; then row "$id" N/A "reads TC-06, which the reference runs predate"; N=$((N+1)); continue; fi
  [ -x "$script" ] || { row "$id" SKIPPED "script missing or not executable: $script"; S=$((S+1)); continue; }
  msg=$("$script" 2>&1 | tail -1); rc=${PIPESTATUS[0]}
  case "$rc:$kind" in
    0:manual) row "$id" FAILED "a manual check must not pass by itself: $msg"; F=$((F+1)) ;;
    0:*)      row "$id" PASSED "${msg#PASSED: }"; P=$((P+1)) ;;
    77:manual) row "$id" MANUAL "${msg#COULD NOT RUN: }"; M=$((M+1)) ;;
    77:*)     row "$id" SKIPPED "${msg#COULD NOT RUN: }"; S=$((S+1)) ;;
    *)        row "$id" FAILED "${msg#FAILED: }"; F=$((F+1)) ;;
  esac
done < checks/ledger.tsv

# a ledger that yields no check, or a result table that cannot be written, is an incomplete verification
[ "$NROWS" -gt 0 ] || { echo "checks/ledger.tsv yields no check" >&2; exit 2; }
if [ -n "$OUT" ]; then printf 'id\tresult\tmessage\n%s' "$ROWS" > "$OUT" || { echo "cannot write $OUT" >&2; exit 2; }; fi
printf '\npassed=%d  failed=%d  could-not-run=%d  manual=%d  not-applicable=%d\n' "$P" "$F" "$S" "$M" "$N"
[ "$F" -gt 0 ] && exit 1
[ "$S" -gt 0 ] && exit 2
exit 0
