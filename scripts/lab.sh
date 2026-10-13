#!/usr/bin/env bash
# Layer 2, the lab, on the cluster that scripts/platform.sh cluster-up created.
#
#   scripts/lab.sh build       pull the k3s and registry images; fetch the OpenTofu provider and check it against
#                              tofu/.terraform.lock.hcl
#   scripts/lab.sh install     the starting point of every path, on the platform cluster: namespaces t27 and
#                              t27-state, the second writer's service account, ConfigMap t27 = A applied by
#                              OpenTofu (state in the kubernetes backend), Flux installed with its source
#                              (gitops/, value C) suspended. For walking through the paths by hand.
#   scripts/lab.sh uninstall   remove what 'install' created (tofu destroy, flux uninstall, the lab's namespaces
#                              and binding), then check nothing of it is left; the cluster stays
#   scripts/lab.sh reinstall   uninstall + install
#   scripts/lab.sh test        the measured experiment, RUNS times: scripts/experiment.sh all (four boundary
#                              tests + control, each on a FRESH cluster that replaces t27), the checks
#                              (scripts/verify.sh) and the measurement rows (scripts/collect.py) of every run;
#                              then summary. The platform cluster is recreated (empty) at the end if it was up.
#   scripts/lab.sh summary     compare the last 'test' with lab/expected.tsv (exit 1 on any difference)
#   scripts/lab.sh status      cluster, lab objects, OpenTofu state, Flux
#   scripts/lab.sh all         build + install + test
#
# Options (environment): RUNS=5  runs of the full experiment (the reference results are 2 runs on 2026-09-29)
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=lib.sh
. "$ROOT/scripts/lib.sh"
set -e
RUNS=${RUNS:-5}
STATE="$RUNTIME"; KC="$RUNTIME/kubeconfig"; RESULTS="$ROOT/results"
LABEL="$LAB_LABEL"
log() { printf '\n==> %s\n' "$*"; }
die() { echo "error: $*" >&2; exit 1; }

# right after 'platform.sh install' the docker group is not active in this shell yet: run again under it
if command -v docker >/dev/null && ! docker info >/dev/null 2>&1 \
   && [ -z "${LAB_SG:-}" ] && getent group docker | grep -qw "$(id -un)" && command -v sg >/dev/null; then
  export LAB_SG=1; exec sg docker -c "$(printf '%q ' "$0" "$@")"
fi
[ -f "$PINS" ] || die "lab/.runtime/pins.env missing: scripts/platform.sh install"
# shellcheck disable=SC1090
. "$PINS"
K="kubectl --kubeconfig $KC"

need_cluster() {
  local list
  list=$(k3d cluster list -o json) || die "k3d cluster list failed"
  jq -e --arg n "$CLUSTER" 'map(select(.name==$n))|length>0' <<<"$list" >/dev/null || die "cluster $CLUSTER not running: scripts/platform.sh cluster-up"
  cluster_owned || die "cluster $CLUSTER was not created by this lab"
  # the kubeconfig is always taken from the verified k3d cluster, never trusted from disk
  k3d kubeconfig get "$CLUSTER" > "$KC.tmp" && mv "$KC.tmp" "$KC" && chmod 600 "$KC" || die "k3d kubeconfig get failed"
  $K get --raw /readyz >/dev/null 2>&1 || die "cluster $CLUSTER not reachable"
}

# get_name <kubectl get args...>: the object's name, empty when it does not exist; non-zero on an API error.
# Callers use it as  x=$(get_name …) || exit 1 : a die inside $(…) would only end the subshell.
get_name() { $K get "$@" --ignore-not-found -o name || { echo "error: kubectl get $* failed (API error)" >&2; return 1; }; }

# ---------------------------------------------------------------- build
cmd_build() {
  local rt; rt=$(container_runtime); [ -n "$rt" ] || die "no usable container engine"
  log "images: $K3S_IMAGE, registry:2 (k3d's local registry)"
  $rt pull -q "$K3S_IMAGE" >/dev/null
  $rt pull -q docker.io/library/registry:2 >/dev/null
  log "OpenTofu provider hashicorp/kubernetes $K8S_PROVIDER_VERSION, checked against tofu/.terraform.lock.hcl"
  # -lockfile=readonly: a provider that does not match the committed lock file fails here
  ( cd "$ROOT/tofu" && rm -rf .terraform && tofu init -backend=false -input=false -lockfile=readonly >/dev/null ) \
    || die "tofu init (provider fetch) failed"
  rm -rf "$ROOT/tofu/.terraform"
  echo "ready"
}

# ---------------------------------------------------------------- install
# never adopt an object the lab did not create: uninstall deletes everything carrying the lab label
adopt_check() { # adopt_check <kind> <name> [namespace]
  local ns=() val
  [ -n "${3:-}" ] && ns=(-n "$3")
  local n; n=$(get_name "$1" "$2" "${ns[@]}") || exit 1
  [ -n "$n" ] || return 0
  val=$($K get "$1" "$2" "${ns[@]}" -o jsonpath="{.metadata.labels.tofu-plan-approval/lab}") || die "could not read $1 $2 (API error)"
  [ "$val" = true ] || die "$1 $2 exists and was not created by this lab"
}

tofu_env() { export KUBECONFIG="$KC" TF_IN_AUTOMATION=1 TF_VAR_kubeconfig="$KC"; }

cmd_install() {
  need_cluster
  for ns in "$NS" "$STATE_NS" flux-system; do adopt_check namespace "$ns"; done
  adopt_check clusterrolebinding t27-second-writer
  # Flux is cluster-wide: its CRDs may exist only as the lab's own (flux-system labelled by the lab)
  local crds; crds=$($K get crd -o name) || die "kubectl get crd failed (API error)"
  local fns; fns=$(get_name namespace flux-system) || exit 1
  if grep -q 'toolkit\.fluxcd\.io' <<<"$crds" && [ -z "$fns" ]; then
    die "Flux CRDs exist on this cluster without the lab's flux-system namespace: not the lab's Flux"
  fi

  log "namespaces $NS, $STATE_NS; service account second-writer (edit role)"
  # created with the label in one step: an interrupted install never leaves an unlabelled lab namespace
  for ns in "$NS" "$STATE_NS"; do
    printf 'apiVersion: v1\nkind: Namespace\nmetadata:\n  name: %s\n  labels:\n    %s: "true"\n' "$ns" "$LABEL" | $K apply -f - >/dev/null
  done
  $K -n "$NS" create serviceaccount second-writer --dry-run=client -o yaml | $K apply -f - >/dev/null
  $K create clusterrolebinding t27-second-writer --clusterrole=edit --serviceaccount="$NS:second-writer" \
    --dry-run=client -o json | jq --arg l "$LABEL" '.metadata.labels[$l]="true"' | $K apply -f - >/dev/null

  log "OpenTofu: ConfigMap $NS/$CM = A, state in secret $STATE_NS/$STATE_SECRET"
  tofu_env
  ( cd "$ROOT/tofu" && rm -rf .terraform \
    && tofu init -input=false -reconfigure -backend-config="config_path=$KC" >/dev/null \
    && tofu apply -input=false -auto-approve -var value=A >/dev/null ) || die "tofu apply failed"

  log "Flux $FLUX_VERSION (source-controller, kustomize-controller); source gitops/ (value C), suspended"
  # the namespace is created with the lab label before Flux, so an interrupted install never leaves it unlabelled
  printf 'apiVersion: v1\nkind: Namespace\nmetadata:\n  name: flux-system\n  labels:\n    %s: "true"\n' "$LABEL" | $K apply -f - >/dev/null
  flux install --namespace=flux-system --components=source-controller,kustomize-controller >/dev/null \
    || die "flux install failed"
  $K label namespace flux-system "$LABEL=true" --overwrite >/dev/null
  mkdir -p "$STATE/install"
  KUBECONFIG="$KC" RUN_ROOT="$STATE/install" "$ROOT/scripts/gitops-setup.sh" "$STATE/install" >/dev/null \
    || die "gitops source failed: lab/.runtime/install/flux-push.stderr"
  flux --kubeconfig "$KC" suspend kustomization "$KS" -n flux-system >/dev/null || die "flux suspend failed"
  cmd_status
  cat <<EOF

Installed. Walk a path by hand, for example TC-02:
  export KUBECONFIG=$KC PATH=$ROOT/bin:\$PATH TF_VAR_kubeconfig=$KC; cd $ROOT/tofu
  tofu plan -var value=B -out=/tmp/b.tfplan                      # the plan you approve: A -> B
  kubectl -n $NS patch configmap $CM --type=merge -p '{"data":{"value":"C"}}'   # a second writer
  tofu apply /tmp/b.tfplan                                       # applies, C -> B; nothing noticed C
  flux resume kustomization $KS -n flux-system                   # TC-04: Flux writes its C back
EOF
}

# ---------------------------------------------------------------- uninstall
cmd_uninstall() {
  need_cluster
  log "OpenTofu destroy (ConfigMap $NS/$CM), Flux uninstall, the lab's namespaces and binding"
  tofu_env
  # the state is destroyed only in the lab's own state namespace
  local sval
  sval=$($K get namespace "$STATE_NS" --ignore-not-found -o jsonpath="{.metadata.labels.tofu-plan-approval/lab}") \
    || die "could not read namespace $STATE_NS (API error)"
  local sns ssec; sns=$(get_name namespace "$STATE_NS") || exit 1
  if [ -n "$sns" ] && [ "$sval" != true ]; then die "namespace $STATE_NS was not created by this lab"; fi
  ssec=""; [ "$sval" = true ] && { ssec=$(get_name secret "$STATE_SECRET" -n "$STATE_NS") || exit 1; }
  if [ -n "$ssec" ]; then
    ( cd "$ROOT/tofu" && rm -rf .terraform \
      && tofu init -input=false -reconfigure -backend-config="config_path=$KC" >/dev/null \
      && tofu destroy -input=false -auto-approve -var value=A >/dev/null ) || die "tofu destroy failed"
  fi
  local val
  val=$($K get namespace flux-system --ignore-not-found -o jsonpath="{.metadata.labels.tofu-plan-approval/lab}") \
    || die "could not read namespace flux-system (API error)"
  if [ "$val" = true ]; then
    flux --kubeconfig "$KC" uninstall --namespace=flux-system --silent >/dev/null || die "flux uninstall failed"
  fi
  $K delete clusterrolebinding -l "$LABEL=true" --ignore-not-found >/dev/null
  $K delete namespace -l "$LABEL=true" --ignore-not-found --wait=true --timeout=300s >/dev/null
  rm -rf "$ROOT/tofu/.terraform" "$STATE/install"
  local left more more2 named crds
  left=$($K get namespace,clusterrolebinding -l "$LABEL=true" -o name) || die "could not verify the removal (API error)"
  crds=$($K get crd -o name) || die "could not verify the removal (API error)"
  more=$(grep -E 'toolkit\.fluxcd\.io' <<<"$crds" || true)
  # the named inventory too, independent of labels
  local x; named=""
  for x in "namespace $NS" "namespace $STATE_NS" "clusterrolebinding t27-second-writer"; do
    # shellcheck disable=SC2086
    more2=$(get_name $x) || exit 1; named+="$more2"
  done
  if [ "$val" = true ]; then more2=$(get_name namespace flux-system) || exit 1; named+="$more2"; fi
  [ -z "$left$more$named" ] || die "still present after uninstall: $(echo $left $more $named)"
  echo "removed; the cluster is still there (scripts/platform.sh cluster-down deletes it)"
}

cmd_status() {
  log "lab objects on cluster $CLUSTER"
  $K get namespace -l "$LABEL=true" --no-headers 2>/dev/null | sed 's/^/  ns  /' || echo "  none"
  $K -n "$NS" get configmap "$CM" -o jsonpath='  ConfigMap {.metadata.namespace}/{.metadata.name}: data.value={.data.value}{"\n"}' 2>/dev/null \
    || echo "  ConfigMap $NS/$CM: not present"
  $K -n flux-system get kustomization "$KS" --no-headers 2>/dev/null | sed 's/^/  flux kustomization  /' || true
}

# ---------------------------------------------------------------- test
cmd_test() {
  local was_up=0 i rc dir id
  cluster_exists && cluster_owned && was_up=1
  mkdir -p "$RESULTS" "$RUNS_DIR"
  rm -f "$STATE/test-plan"
  date -u +%Y%m%dT%H%M%SZ > "$STATE/test-started"
  : > "$STATE/runner-failures"; : > "$STATE/test-runs"
  # the plan is written before anything runs; summary fails unless the run reached the end ('complete')
  printf 'runs=%s\ncomplete=0\n' "$RUNS" > "$STATE/test-plan"
  for i in $(seq 1 "$RUNS"); do
    log "run $i/$RUNS: scripts/experiment.sh all (about 10 minutes; each scenario recreates cluster $CLUSTER)"
    rc=0; "$ROOT/scripts/experiment.sh" all > "$STATE/experiment-$i.log" 2>&1 || rc=$?
    grep -E '^== run |^-- |WARNING' "$STATE/experiment-$i.log" | tail -4 || true
    [ "$rc" = 0 ] || { echo "run $i: experiment exit $rc" | tee -a "$STATE/runner-failures" >&2; tail -5 "$STATE/experiment-$i.log" >&2; }
    # the isolation check (EV-011) asks that the experiment cluster is gone
    rc=0; "$ROOT/scripts/experiment.sh" clean >/dev/null 2>&1 || rc=$?
    [ "$rc" = 0 ] || echo "run $i: clean exit $rc" | tee -a "$STATE/runner-failures" >&2
    # the run this iteration made, by the id experiment.sh printed ("== run <id>  ->  <dir>")
    id=$(sed -n 's/^== run \([0-9TZ]*\) .*/\1/p' "$STATE/experiment-$i.log" | head -1); dir="$RUNS_DIR/$id"
    if [ -z "$id" ] || [ ! -d "$dir" ] || grep -qx "$id" "$STATE/test-runs"; then
      echo "run $i: no run id in experiment-$i.log" | tee -a "$STATE/runner-failures" >&2; continue
    fi
    basename "$dir" >> "$STATE/test-runs"
    mkdir -p "$RESULTS/$(basename "$dir")"
    # verify: 0 all passed, 1 a claim failed, 2 a check could not run; all three are results, compared by summary
    rc=0; "$ROOT/scripts/verify.sh" --run "$dir" --out "$RESULTS/$(basename "$dir")/verify.tsv" \
      > "$RESULTS/$(basename "$dir")/verify.log" 2>&1 || rc=$?
    echo "  verify: exit $rc ($(tail -1 "$RESULTS/$(basename "$dir")/verify.log"))"
    cp "$dir/TC-04/metrics.json" "$RESULTS/$(basename "$dir")/metrics.json" 2>/dev/null || true
    rc=0; python3 "$ROOT/scripts/collect.py" "$dir" > "$RESULTS/$(basename "$dir")/measurements.tsv" || rc=$?
    [ "$rc" = 0 ] || echo "run $i: collect exit $rc" | tee -a "$STATE/runner-failures" >&2
  done
  sed -i 's/^complete=0$/complete=1/' "$STATE/test-plan"
  if [ "$was_up" = 1 ]; then log "the platform cluster was up before the test: recreating it (empty)"; "$ROOT/scripts/platform.sh" cluster-up >/dev/null; fi
  cmd_summary
}

cmd_summary() {
  [ -f "$STATE/test-plan" ] || die "no test plan recorded: run scripts/lab.sh test"
  local runs complete
  # shellcheck disable=SC1091
  . "$STATE/test-plan"
  local extra=(); [ "$complete" = 1 ] || extra+=(--incomplete)
  python3 "$ROOT/scripts/summary.py" --run-list "$STATE/test-runs" --ledger "$ROOT/checks/ledger.tsv" --runs "$runs" \
    --runner-failures "$STATE/runner-failures" --markdown "$STATE/summary.md" "${extra[@]}" \
    "$ROOT/lab/expected.tsv" "$RESULTS"
}

case "${1:-}" in
  build) cmd_build ;;
  install) cmd_install ;;
  uninstall) cmd_uninstall ;;
  reinstall) cmd_uninstall; cmd_install ;;
  test) cmd_test ;;
  summary) cmd_summary ;;
  status) need_cluster; cmd_status ;;
  all) cmd_build; cmd_install; cmd_test ;;
  *) sed -n '2,24p' "$0"; exit 2 ;;
esac
