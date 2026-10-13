#!/usr/bin/env bash
# End-to-end check of the README quickstart in a fresh Ubuntu VM (multipass), from zero:
#   copy what a clone contains -> platform.sh install + cluster-up -> lab.sh all (build, install, test)
#   -> install + reinstall (a real uninstall) -> one more test run -> install + uninstall -> cluster-down.
#
#   scripts/multipass-e2e.sh                     Ubuntu 26.04, RUNS=5
#   UBUNTU=24.04 RUNS=1 scripts/multipass-e2e.sh
#
# Options (environment): UBUNTU (26.04), VM (tpa-e2e), CPUS (4), MEM (8G), DISK (30G), RUNS (5), KEEP (0: delete
#   the VM afterwards; a failed run always keeps it), OUT (output directory, must be OUTSIDE the repository:
#   raw run archives are not published as they are).
# Output: $OUT/<UTC>-ubuntu<ver>/ : step logs, summary.md, results/ (check results and measurement rows per run),
#   raw-runs-*.tar.gz (the VM's run archives without kubeconfig files), environment.txt, source.txt.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
UBUNTU=${UBUNTU:-26.04}; VM=${VM:-tpa-e2e}; CPUS=${CPUS:-4}; MEM=${MEM:-8G}; DISK=${DISK:-30G}
RUNS=${RUNS:-5}; KEEP=${KEEP:-0}
# the source state is read before this run writes anything
CLEAN=0; [ -z "$(cd "$ROOT" && git status --porcelain 2>/dev/null)" ] && CLEAN=1
BASE=${OUT:-$(dirname "$ROOT")/$(basename "$ROOT")-review/e2e-multipass}
mkdir -p "$BASE"; BASE=$(cd "$BASE" && pwd)
case "$BASE/" in "$ROOT"/*) echo "OUT must be outside the repository ($ROOT)" >&2; exit 1 ;; esac
OUT="$BASE/$(date -u +%Y%m%dT%H%M%SZ)-ubuntu$UBUNTU"; mkdir -p "$OUT"
log() { printf '\n==> %s\n' "$*" | tee -a "$OUT/host.log"; }

command -v multipass >/dev/null || { echo "multipass not installed (sudo snap install multipass)" >&2; exit 1; }
if multipass info "$VM" >/dev/null 2>&1; then echo "VM $VM exists; delete it first: multipass delete --purge $VM" >&2; exit 1; fi

log "launch $VM: Ubuntu $UBUNTU, $CPUS CPU, $MEM, $DISK"
multipass launch "$UBUNTU" --name "$VM" --cpus "$CPUS" --memory "$MEM" --disk "$DISK" --timeout 900
# the VM is kept when the run failed, so it can be inspected (delete it with: multipass delete --purge $VM)
cleanup() { local s=$?; [ "$KEEP" = 1 ] || [ "$s" != 0 ] || [ "${rc:-1}" != 0 ] || { multipass delete --purge "$VM" 2>/dev/null || true; }; }
trap cleanup EXIT

# Source: the committed tree (git archive HEAD) when the working tree is clean, which is exactly what a clone gets.
# With uncommitted changes the working tree is copied instead and recorded as such. evidence/ is not needed to run.
# Streamed over stdin: the multipass snap cannot read the host's /tmp.
if [ "$CLEAN" = 1 ]; then
  SRC="committed tree $(cd "$ROOT" && git rev-parse HEAD)"
  pack() { (cd "$ROOT" && git archive --format=tar.gz HEAD -- . ':(exclude)evidence'); }
else
  SRC="working tree with uncommitted changes (base $(cd "$ROOT" && git rev-parse --short HEAD 2>/dev/null || echo none)); NOT what a clone gets"
  pack() { (cd "$ROOT" && git ls-files -co --exclude-standard | grep -v -E '^evidence/' | tar -czf - -T -); }
fi
log "copy source: $SRC"
echo "$SRC" > "$OUT/source.txt"
[ "$CLEAN" = 1 ] || (cd "$ROOT" && git status --short) >> "$OUT/source.txt"
pack | multipass exec "$VM" -- bash -c 'mkdir -p ~/lab && tar -xzf - -C ~/lab && find ~/lab -type f | wc -l'

run() { # <log name> <command>: runs in a fresh login shell, so group changes from install apply
  local name=$1; shift
  log "$*"
  local start=$SECONDS rc=0
  multipass exec "$VM" -- sudo -iu ubuntu bash -lc "cd ~/lab && $*" 2>&1 | tee "$OUT/$name.log" || rc=$?
  echo "$name: exit $rc, $((SECONDS - start)) s" | tee -a "$OUT/host.log"
  return $rc
}

rc=0
step() { [ $rc = 0 ] || return 0; run "$@" || rc=$?; }
# raw run archives, kubeconfig files left out (client keys and tokens of the VM's lab clusters)
capture() {
  [ $rc = 0 ] || return 0
  multipass exec "$VM" -- bash -c "cd ~/lab && tar --exclude='kubeconfig' --exclude='kubeconfig.*' -czf - runs results lab/.runtime/summary.md lab/.runtime/test-started" \
    > "$OUT/raw-runs-$1.tar.gz" && tar -tzf "$OUT/raw-runs-$1.tar.gz" >/dev/null \
    && echo "raw runs: raw-runs-$1.tar.gz" | tee -a "$OUT/host.log" \
    || { echo "raw run export failed ($1)" | tee -a "$OUT/host.log"; rc=1; }
}
# install and cluster-up in one shell, as a reader pastes them: cluster-up must pick up the new docker group itself
step 01-platform-install-cluster-up "scripts/platform.sh install && scripts/platform.sh cluster-up"
step 02-lab-all "RUNS=$RUNS scripts/lab.sh all"
capture main
multipass exec "$VM" -- bash -c 'cp ~/lab/lab/.runtime/summary.md ~/summary-main.md; cp ~/lab/lab/.runtime/test-started ~/test-started-main' || rc=1
# install on the (empty) cluster, then reinstall = a real uninstall of an installed lab + install
step 03-lab-install-reinstall "scripts/lab.sh install && scripts/lab.sh reinstall && scripts/lab.sh status"
step 04-lab-test-after-reinstall "RUNS=1 scripts/lab.sh test"
capture after-reinstall
step 05-lab-install-uninstall "scripts/lab.sh install && scripts/lab.sh uninstall"
# cluster-down checks that neither the cluster nor the registry is left
step 06-platform-cluster-down "scripts/platform.sh cluster-down && scripts/platform.sh status"

log "fetch results"
# the summary and the per-run results are required: a failed or empty fetch fails the run
multipass exec "$VM" -- bash -c 'cat ~/summary-main.md' > "$OUT/summary.md" && [ -s "$OUT/summary.md" ] \
  || { echo "fetch failed: summary.md" | tee -a "$OUT/host.log"; rc=1; }
multipass exec "$VM" -- bash -c 'cat ~/lab/lab/.runtime/summary.md' > "$OUT/summary-after-reinstall.md" 2>/dev/null || true
multipass exec "$VM" -- bash -c 'cd ~/lab && tar -czf - results' | tar -xzf - -C "$OUT" \
  && [ "$(find "$OUT/results" -name measurements.tsv | wc -l)" -ge "$RUNS" ] \
  || { echo "fetch failed: results" | tee -a "$OUT/host.log"; rc=1; }
multipass exec "$VM" -- bash -c 'lsb_release -ds; uname -r; nproc; free -h | head -2; cd ~/lab && scripts/platform.sh status' \
  > "$OUT/environment.txt" 2>&1 || true
echo "result: exit $rc" | tee -a "$OUT/host.log"
echo "output: $OUT"
exit $rc
