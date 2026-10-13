#!/usr/bin/env bash
# ==================================================================
# Shared library: the experiment harness and the checks source this.
#
# Exit code contract (every check in checks/):
#   0  PASSED         the claim holds
#   1  FAILED         the claim is FALSE: that is a finding, not an error
#   77 COULD NOT RUN  environment or record missing: NOT counted as passed
# ==================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export ROOT
export BIN="$ROOT/bin"
export RUNTIME="$ROOT/lab/.runtime"
export PINS="$RUNTIME/pins.env"
export RUNS_DIR="${RUNS_DIR:-$ROOT/runs}"
PATH="$BIN:$PATH"; export PATH
# OpenTofu providers are downloaded once and reused by every scenario's init (no effect on what is measured)
export TF_PLUGIN_CACHE_DIR="$RUNTIME/plugin-cache"; mkdir -p "$TF_PLUGIN_CACHE_DIR"

# --- exit codes ----------------------------------------------------
PASS=0; FAIL=1; SKIP=77
export PASS FAIL SKIP

pass(){ [ $# -gt 0 ] && printf 'PASSED: %s\n' "$*"; exit 0; }
fail(){ printf 'FAILED: %s\n' "$*" >&2; exit 1; }
cannot_run(){ printf 'COULD NOT RUN: %s\n' "$*" >&2; exit 77; }

# --- pinned versions -----------------------------------------------
# The versions are fixed in scripts/versions.env, written to pins.env at install
# time, and then ENFORCED (checks/01-pins.sh).
pins_load(){
  [ -f "$PINS" ] || cannot_run "lab/.runtime/pins.env missing: run scripts/platform.sh install first"
  # shellcheck disable=SC1090
  . "$PINS"
  for v in TOFU_VERSION FLUX_VERSION K3S_IMAGE K3D_VERSION KUBECTL_VERSION; do
    [ -n "${!v:-}" ] || cannot_run "pins.env lacks $v"
  done
}

# --- required binaries ---------------------------------------------
require(){
  local missing=""
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 || missing="$missing $c"; done
  [ -z "${missing// }" ] || cannot_run "missing binary:$missing"
}

# --- run directory -------------------------------------------------
# Checks read the records under RUN_ROOT; a missing input gives 77.
run_find(){
  if [ -n "${RUN_ROOT:-}" ]; then
    [ -d "$RUN_ROOT" ] || cannot_run "RUN_ROOT does not exist: $RUN_ROOT"
  else
    RUN_ROOT="$(ls -1d "$RUNS_DIR"/*/ 2>/dev/null | sort | tail -1)" || true
    [ -n "${RUN_ROOT:-}" ] || cannot_run "no run yet: run scripts/experiment.sh first"
    RUN_ROOT="${RUN_ROOT%/}"
  fi
  export RUN_ROOT
}

scenario_dir(){   # scenario_dir TC-02  -> $RUN_ROOT/TC-02 (77 when missing)
  local tc="$1"; local d="$RUN_ROOT/$tc"
  [ -d "$d" ] || cannot_run "$tc was not run ($d missing)"
  printf '%s' "$d"
}

required_files(){ # required_files a.json b.json ...: 77 when one is missing or empty
  local missing=""
  for f in "$@"; do [ -s "$f" ] || missing="$missing $(basename "$f")"; done
  [ -z "${missing// }" ] || cannot_run "record missing:$missing"
}

# --- event log (JSONL) ---------------------------------------------
# Measurement contract: run_id, scenario_id, phase, actor, utc, monotonic
# sequence, link to the raw source. NO CAUSALITY is inferred from timestamps.
: "${EVENT_SEQ:=0}"
event(){ # event <scenario> <phase> <actor> <source> <message>
  local tc="$1" ph="$2" ac="$3" src="$4"; shift 4
  EVENT_SEQ=$((EVENT_SEQ+1))
  jq -cn --arg run "${RUN_ID:-?}" --arg tc "$tc" --arg ph "$ph" --arg ac "$ac" \
        --arg utc "$(date -u +%FT%TZ)" --argjson seq "$EVENT_SEQ" --arg src "$src" \
        --arg msg "$*" \
    '{run_id:$run,scenario_id:$tc,phase:$ph,actor:$ac,utc:$utc,seq:$seq,source:$src,message:$msg}' \
    >> "$RUN_ROOT/events.jsonl"
}

# --- command record ------------------------------------------------
# argv, stdout, stderr, the NATURAL exit code and the duration are kept
# separately. The natural code and a check's code are NEVER mixed.
record(){ # record <output-prefix> <command...>
  local out="$1"; shift
  local b s rc
  b=$(date +%s%N)
  printf '%s\n' "$*" > "$out.argv"
  "$@" > "$out.stdout" 2> "$out.stderr"; rc=$?
  s=$(( ($(date +%s%N) - b) / 1000000 ))
  printf '%s\n' "$rc" > "$out.rc"
  printf '%s\n' "$s"  > "$out.ms"
  return $rc
}

# --- k3d -----------------------------------------------------------
cluster_name(){ printf '%s' "${CLUSTER:-t27}"; }
kubeconfig_path(){ printf '%s/kubeconfig' "$RUN_ROOT"; }

# 0 = exists, 1 = does not exist; a failing k3d stops the caller (77) instead of reading as "absent"
cluster_exists(){
  local list; list=$(k3d cluster list -o json 2>/dev/null) || cannot_run "k3d cluster list failed"
  jq -e --arg n "$(cluster_name)" 'map(select(.name==$n)) | length > 0' <<<"$list" >/dev/null 2>&1
}

# --- container runtime ---------------------------------------------
container_runtime(){ # which runtime k3d runs on: docker | podman
  if docker ps >/dev/null 2>&1; then printf 'docker'
  elif podman ps >/dev/null 2>&1; then printf 'podman'
  else printf ''; fi
}

# The lab labels the server container of every cluster it creates; a cluster with the same name and without
# the label belongs to someone else and is never deleted.
LAB_LABEL="tofu-plan-approval/lab"
cluster_owned(){
  local rt; rt=$(container_runtime); [ -n "$rt" ] || return 1
  [ "$("$rt" inspect "k3d-$(cluster_name)-server-0" --format "{{index .Config.Labels \"$LAB_LABEL\"}}" 2>/dev/null)" = true ]
}

# Deletes ONLY the lab's cluster and registry (names from scripts/versions.env).
cluster_remove(){
  if cluster_exists && ! cluster_owned; then
    echo "refusing: a k3d cluster named $(cluster_name) exists and was not created by this lab (no $LAB_LABEL label)" >&2
    return 1
  fi
  k3d cluster delete "$(cluster_name)" >/dev/null 2>&1 || true
  registry_remove
}

# The registry is deleted only when k3d created it for the lab's cluster (label k3d.cluster=<cluster>).
registry_remove(){
  local rt reg="${REGISTRY:-t27-reg}" owner; rt=$(container_runtime); [ -n "$rt" ] || return 0
  "$rt" inspect "$reg" >/dev/null 2>&1 || return 0
  owner=$("$rt" inspect "$reg" --format '{{index .Config.Labels "k3d.cluster"}}' 2>/dev/null)
  if [ "$owner" != "$(cluster_name)" ]; then
    echo "refusing: a container named $reg exists and is not the registry k3d made for cluster $(cluster_name)" >&2
    return 1
  fi
  k3d registry delete "$reg" >/dev/null 2>&1 || true
}

# cluster_create <audit-dir> <kubeconfig-out>: the lab's k3d cluster, its local
# registry and the audit policy. Used by every scenario and by platform.sh.
cluster_create(){
  local adir="$1" kc="$2"
  mkdir -p "$adir"
  # The audit file stays on the HOST so log rotation and read markers can be
  # archived. The registry feeds Flux's desired state as an OCI artifact.
  registry_remove || return 1
  k3d cluster create "$(cluster_name)" \
      --image "$K3S_IMAGE" \
      --registry-create "${REGISTRY:-t27-reg}:0.0.0.0:${REGISTRY_PORT:-5111}" \
      --agents 0 \
      --runtime-label "$LAB_LABEL=true@server:0" \
      --volume "$ROOT/k3d/audit-policy.yaml:/var/lib/rancher/k3s/server/audit-policy.yaml@server:0" \
      --volume "$adir:/var/log/k3s-audit@server:0" \
      --k3s-arg "--kube-apiserver-arg=audit-policy-file=/var/lib/rancher/k3s/server/audit-policy.yaml@server:0" \
      --k3s-arg "--kube-apiserver-arg=audit-log-path=/var/log/k3s-audit/audit.log@server:0" \
      --k3s-arg "--kube-apiserver-arg=audit-log-maxage=0@server:0" \
      --k3s-arg "--kube-apiserver-arg=audit-log-maxbackup=0@server:0" \
      --wait >/dev/null || { echo "k3d cluster could not be created" >&2; return 1; }
  k3d kubeconfig get "$(cluster_name)" > "$kc"
  chmod 600 "$kc"
}

# --- audit -----------------------------------------------------------
# audit.log is written as root:root 0600 inside the container; the host
# CANNOT read it directly. Reading a permission error as "no write happened"
# is FORBIDDEN, so the snapshot is taken from the container and the read is
# marked.
AUDIT_LAST=""
audit_capture(){ # audit_capture <TC-xx|general>
  local tag="${1:-general}" rt target; rt=$(container_runtime)
  [ -n "$rt" ] || { echo "WARNING: no container runtime, audit not captured" >&2; return 1; }
  case "$tag" in
    TC-*) mkdir -p "$RUN_ROOT/$tag"; target="$RUN_ROOT/$tag/audit.jsonl" ;;
    *)    mkdir -p "$RUN_ROOT/audit"; target="$RUN_ROOT/audit/audit.jsonl" ;;
  esac
  "$rt" exec "k3d-$(cluster_name)-server-0" cat /var/log/k3s-audit/audit.log \
      > "$target" 2>/dev/null || return 1
  AUDIT_LAST="$target"; export AUDIT_LAST
  mkdir -p "$RUN_ROOT/audit"
  jq -n --arg tag "$tag" --arg utc "$(date -u +%FT%TZ)" --arg f "$target" \
        --argjson lines "$(wc -l < "$target")" --arg rt "$rt" \
    '{marker:$tag,utc:$utc,file:$f,lines:$lines,runtime:$rt,
      note:"read marker: anything after this line is NOT in this snapshot"}' \
    >> "$RUN_ROOT/audit/read-markers.jsonl"
}

# Checks ask for the audit log WITH THIS:  audit_prepare; ... "$AUDIT_LOG"
#
# NOT CALLED IN A COMMAND SUBSTITUTION. With log=$(audit_file), cannot_run's
# exit 77 would close only the SUBSHELL, the script would continue with an
# empty variable and produce a WRONG FAILED for "no events at all". That is
# exactly the inference the measurement contract forbids, so a global is set.
AUDIT_LOG=""
audit_prepare(){ # audit_prepare [TC-xx]
  local tc="${1:-}" snap
  if [ -n "$tc" ] && [ -s "$RUN_ROOT/$tc/audit.jsonl" ]; then
    AUDIT_LOG="$RUN_ROOT/$tc/audit.jsonl"; return 0
  fi
  snap="$RUN_ROOT/audit/audit.jsonl"
  if [ -s "$snap" ] && [ -r "$snap" ]; then AUDIT_LOG="$snap"; return 0; fi
  if [ -e "$RUN_ROOT/audit/audit.log" ] && [ ! -r "$RUN_ROOT/audit/audit.log" ]; then
    cannot_run "the raw audit log EXISTS but cannot be read (permissions): an observation gap, NOT 'no write happened'"
  fi
  cannot_run "no audit snapshot${tc:+ ($tc)}: run scripts/experiment.sh first"
}

# Check 11 looks at every scenario: it combines the per-scenario files.
audit_all(){
  local out="$RUN_ROOT/audit/combined.jsonl"
  : > "$out"
  for f in "$RUN_ROOT"/TC-*/audit.jsonl "$RUN_ROOT/audit/audit.jsonl"; do
    [ -s "$f" ] && cat "$f" >> "$out"
  done
  [ -s "$out" ] || cannot_run "no audit snapshot at all"
  AUDIT_LOG="$out"
}
