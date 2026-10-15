#!/usr/bin/env bash
# ==================================================================
# The experiment harness.
#
#   scripts/experiment.sh TC-01 .. TC-06   one scenario
#   scripts/experiment.sh all              four boundary tests, the control, and the TC-06 gate
#   scripts/experiment.sh clean            delete the lab's cluster and registry
#
# Every scenario starts from a FRESH cluster: leakage between paths is the
# most likely way to corrupt the measurement silently. Each scenario deletes
# and recreates the k3d cluster named in scripts/versions.env (t27); no other
# cluster is touched.
#
# Runner: a CLI triggered by a person, not an OpenTofu controller. That is
# why nothing here claims "OpenTofu under a reconciler".
# ==================================================================
set -uo pipefail
. "$(dirname "$0")/lib.sh"

CMD="${1:-}"
[ -n "$CMD" ] || { sed -n '3,15p' "$0" | sed 's/^# \?//'; exit 2; }

pins_load
require k3d kubectl jq tofu

# ------------------------------------------------------------------
# Cluster life cycle
# ------------------------------------------------------------------
scenario_cluster(){ # scenario_cluster [TC-xx]
  local tc="${1:-general}" adir
  cluster_remove || return 1
  echo "-- creating k3d cluster ($K3S_IMAGE) [$tc]"
  # AUDIT DIRECTORY PER SCENARIO. With a single mounted directory k3s would
  # keep appending to the SAME file on every new cluster: the TC-05 control
  # log would contain the second-writer mutations of TC-01/TC-02 and check 09
  # would produce a WRONG FAILED.
  case "$tc" in TC-*) adir="$RUN_ROOT/$tc/audit" ;; *) adir="$RUN_ROOT/audit" ;; esac
  # Registry: Flux's desired state is fed as an OCI artifact. Hosting Git adds
  # nothing to the claim; what matters is that the REVISION used is recorded.
  cluster_create "$adir" "$(kubeconfig_path)" || return 1
  export KUBECONFIG="$(kubeconfig_path)"

  kubectl create namespace "$NS"       >/dev/null
  kubectl create namespace "$STATE_NS" >/dev/null

  # Is the audit log really written? If not verified here, a "no write
  # happened" result could be produced, which is FORBIDDEN.
  kubectl -n "$NS" create configmap audit-canary --from-literal=x=1 >/dev/null
  kubectl -n "$NS" delete configmap audit-canary >/dev/null
  sleep 2
  # The log is root:600 inside the container: a direct grep from the host
  # gives a PERMISSION ERROR, which must not read as "no write happened".
  # The snapshot is taken from the container.
  if audit_capture "${tc}" && grep -q 'audit-canary' "$AUDIT_LAST" 2>/dev/null; then
    echo "-- audit canary seen ($(wc -l < "$AUDIT_LAST") lines)"
  else
    echo "WARNING: audit canary not seen: check 02 will return 77 (observation gap)" >&2
  fi
}

actors_setup(){
  # Separate actor identities.
  #
  # NO IMPERSONATION. With --as the AUTHENTICATED user in the audit log is
  # still admin; the actor shows up only in impersonatedUser. "The second
  # writer wrote" would then be indistinguishable from admin writing on its
  # own behalf. So a real ServiceAccount TOKEN is issued and written to a
  # separate kubeconfig; in the audit log user.username = system:serviceaccount:...
  for a in second-writer; do
    kubectl create serviceaccount "$a" -n "$NS" >/dev/null 2>&1 || true
    kubectl create clusterrolebinding "t27-$a" \
      --clusterrole=edit --serviceaccount="$NS:$a" >/dev/null 2>&1 || true
    local tok kc="$RUN_ROOT/kubeconfig.$a"
    tok=$(kubectl create token "$a" -n "$NS" --duration=2h 2>/dev/null) || continue
    cp "$(kubeconfig_path)" "$kc"
    kubectl --kubeconfig "$kc" config set-credentials "$a" --token="$tok" >/dev/null
    kubectl --kubeconfig "$kc" config set-context --current --user="$a" >/dev/null
    chmod 600 "$kc"
  done
}

# ------------------------------------------------------------------
# Run directory and manifest
# ------------------------------------------------------------------
run_start(){
  RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
  RUN_ROOT="$RUNS_DIR/$RUN_ID"
  mkdir -p "$RUN_ROOT"
  export RUN_ID RUN_ROOT
  jq -n --arg run "$RUN_ID" --arg utc "$(date -u +%FT%TZ)" \
        --arg tofu "$TOFU_VERSION" --arg flux "$FLUX_VERSION" --arg k3d "$K3D_VERSION" \
        --arg kubectl "$KUBECTL_VERSION" --arg k3s "$K3S_IMAGE" \
        --arg prov "$K8S_PROVIDER_VERSION" --arg git "$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo none)" \
        --arg ns "$NS" --arg cm "$CM" --arg sns "$STATE_NS" --arg ssec "$STATE_SECRET" --arg ks "$KS" \
    '{run_id:$run,started:$utc,
      pins:{tofu:$tofu,flux:$flux,k3d:$k3d,kubectl:$kubectl,k3s_image:$k3s,k8s_provider:$prov},
      source_commit:$git,
      target:{ns:$ns,configmap:$cm,state_ns:$sns,state_secret:$ssec,kustomization:$ks},
      runner:{kind:"person-triggered-cli",note:"no OpenTofu controller"}}' \
    > "$RUN_ROOT/run.json"
  echo "== run $RUN_ID  ->  $RUN_ROOT"
}

# ------------------------------------------------------------------
# Approval record
# ------------------------------------------------------------------
approval_write(){ # approval_write <tc-dir> <binding_kind> <binding_value> [plan-file]
  local d="$1" kind="$2" val="$3" plan="${4:-}" hash=""
  [ -n "$plan" ] && [ -f "$plan" ] && hash=$(sha256sum "$plan" | awk '{print $1}')
  jq -n --arg who "${APPROVER:-$(id -un)}" --arg at "$(date -u +%FT%TZ)" \
        --arg k "$kind" --arg v "$val" --arg h "$hash" \
    '{approver:$who,approved_at:$at,binding_kind:$k,binding_value:$v,
      reviewed_plan_sha256:$h,
      note:"the approver identity is NOT verified just because the file names it"}' \
    > "$d/approval.json"
}

# ------------------------------------------------------------------
# State capture
# ------------------------------------------------------------------
object_capture(){ # object_capture <tc-dir> <phase>
  kubectl get --raw "/api/v1/namespaces/$NS/configmaps/$CM" \
    > "$1/object.$2.json" 2>/dev/null || echo '{"absent":true}' > "$1/object.$2.json"
}
state_capture(){ # state_capture <tc-dir> <phase>
  ( cd "$ROOT/tofu" && tofu state pull ) > "$1/state.$2.json" 2>/dev/null || : > "$1/state.$2.json"
  jq '{lineage,serial,version,terraform_version}' "$1/state.$2.json" \
    > "$1/state.$2.summary.json" 2>/dev/null || echo '{}' > "$1/state.$2.summary.json"
  kubectl -n "$STATE_NS" get secret "$STATE_SECRET" -o json > "$1/backend.$2.json" 2>/dev/null || : > "$1/backend.$2.json"
  kubectl -n "$STATE_NS" get leases -o json          > "$1/leases.$2.json"  2>/dev/null || : > "$1/leases.$2.json"
}

tofu_prepare(){
  export KUBECONFIG TF_IN_AUTOMATION=1
  # The run's kubeconfig is passed EXPLICITLY (backend + provider).
  export TF_VAR_kubeconfig="$KUBECONFIG"
  # .terraform/ keeps the previous cluster's backend record; on a new cluster
  # init fails with "backend configuration changed". Every scenario starts
  # fresh, and so does the backend.
  rm -rf "$ROOT/tofu/.terraform"
  # argv is RECORDED: which backend init used must be readable from the file
  # afterwards, not remembered.
  ( cd "$ROOT/tofu" && record "$RUN_ROOT/tofu-init" \
       tofu init -input=false -upgrade=false -reconfigure \
       -backend-config="config_path=$KUBECONFIG" ) \
    || { echo "tofu init failed: see $RUN_ROOT/tofu-init.stderr" >&2; return 1; }
}

# ------------------------------------------------------------------
# Scenarios
# ------------------------------------------------------------------
tc_common_setup(){ # tc_common_setup <tc>
  local tc="$1" d="$RUN_ROOT/$1"
  mkdir -p "$d"
  scenario_cluster "$tc" || return 1
  actors_setup
  export KUBECONFIG="$(kubeconfig_path)"
  tofu_prepare || return 1
  # Start: data.value = A
  ( cd "$ROOT/tofu" && record "$d/bootstrap" tofu apply -input=false -auto-approve -var "value=A" ) || true
  object_capture "$d" "00-start"
  state_capture "$d" "00-start"
  event "$tc" "setup" "harness" "$d/bootstrap.stdout" "start value=A"
}

second_writer_write(){ # second_writer_write <tc-dir> <tc> <value>
  local kc="$RUN_ROOT/kubeconfig.second-writer"
  [ -s "$kc" ] || { echo "WARNING: no second-writer kubeconfig, intervention skipped" >&2; return 1; }
  record "$1/second-writer" kubectl --kubeconfig "$kc" -n "$NS" \
    patch configmap "$CM" --type=merge -p "{\"data\":{\"value\":\"$3\"}}" || true
  event "$2" "intervention" "system:serviceaccount:$NS:second-writer" "$1/second-writer.stdout" "data.value <- $3"
}

tc01(){ local d="$RUN_ROOT/TC-01"; tc_common_setup TC-01 || return 1
  # The approval is bound to the GIT REVISION: a no-op plan.
  ( cd "$ROOT/tofu" && record "$d/reviewed-plan" tofu plan -input=false -var "value=A" -out "$d/reviewed.tfplan" ) || true
  ( cd "$ROOT/tofu" && tofu show -json "$d/reviewed.tfplan" > "$d/reviewed.plan.json" 2>/dev/null ) || true
  approval_write "$d" "git_revision" "$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo none)" ""

  second_writer_write "$d" TC-01 C
  object_capture "$d" "10-after-intervention"

  # A FRESH plan: the approval was given to the configuration.
  ( cd "$ROOT/tofu" && record "$d/fresh-plan" tofu plan -input=false -var "value=A" -out "$d/applied.tfplan" ) || true
  ( cd "$ROOT/tofu" && tofu show -json "$d/applied.tfplan" > "$d/applied.plan.json" 2>/dev/null ) || true
  ( cd "$ROOT/tofu" && record "$d/apply" tofu apply -input=false "$d/applied.tfplan" ) || true
  object_capture "$d" "20-after-apply"; state_capture "$d" "20-after-apply"
  audit_capture TC-01 || echo "WARNING: TC-01 audit snapshot not captured" >&2
}

tc02(){ local d="$RUN_ROOT/TC-02"; tc_common_setup TC-02 || return 1
  # The approval is bound to the EXACT SAVED ARTIFACT: A -> B
  ( cd "$ROOT/tofu" && record "$d/reviewed-plan" tofu plan -input=false -var "value=B" -out "$d/reviewed.tfplan" ) || true
  ( cd "$ROOT/tofu" && tofu show -json "$d/reviewed.tfplan" > "$d/reviewed.plan.json" 2>/dev/null ) || true
  approval_write "$d" "plan_artifact" "reviewed.tfplan" "$d/reviewed.tfplan"

  second_writer_write "$d" TC-02 C
  object_capture "$d" "10-after-intervention"; state_capture "$d" "10-after-intervention"

  # Apply the same file WITHOUT a plan or refresh in between.
  cp "$d/reviewed.tfplan" "$d/applied.tfplan"
  ( cd "$ROOT/tofu" && record "$d/apply" tofu apply -input=false "$d/applied.tfplan" ) || true
  object_capture "$d" "20-after-apply"; state_capture "$d" "20-after-apply"
  audit_capture TC-02 || echo "WARNING: TC-02 audit snapshot not captured" >&2
}

tc03(){ local d="$RUN_ROOT/TC-03"; tc_common_setup TC-03 || return 1

  # --- Lock precondition ------------------------------------------
  # First remove the object so the CREATE provisioner runs; while create waits
  # on the FIFO the apply HOLDS the state lock. Meanwhile a second runner tries
  # with -lock-timeout=1s. Without SHOWING this precondition, TC-03's state
  # rejection cannot be read as "the lock was working".
  ( cd "$ROOT/tofu" && tofu destroy -input=false -auto-approve -var "value=A" ) >/dev/null 2>&1 || true
  local fifo="$d/lock.fifo"; rm -f "$fifo"; mkfifo "$fifo"
  ( cd "$ROOT/tofu" && tofu apply -input=false -auto-approve -var "value=A" -var "lock_fifo=$fifo" \
      > "$d/lock-holder.stdout" 2> "$d/lock-holder.stderr" ) &
  local holder=$!
  sleep 8   # until the provisioner reaches the FIFO
  ( cd "$ROOT/tofu" && record "$d/lock-contention" tofu plan -input=false -lock-timeout=1s -var "value=B" ) || true
  echo continue > "$fifo" 2>/dev/null || true
  wait $holder 2>/dev/null || true
  rm -f "$fifo"
  event TC-03 "lock-precondition" "harness" "$d/lock-contention.stderr" "second runner tried while the lock was held"
  object_capture "$d" "05-after-lock"; state_capture "$d" "05-after-lock"

  ( cd "$ROOT/tofu" && record "$d/reviewed-plan" tofu plan -input=false -var "value=B" -out "$d/reviewed.tfplan" ) || true
  ( cd "$ROOT/tofu" && tofu show -json "$d/reviewed.tfplan" > "$d/reviewed.plan.json" 2>/dev/null ) || true
  approval_write "$d" "plan_artifact" "reviewed.tfplan" "$d/reviewed.tfplan"

  # Competing apply on the SAME backend/workspace: the serial advances.
  ( cd "$ROOT/tofu" && record "$d/competing-apply" tofu apply -input=false -auto-approve -var "value=C" ) || true
  state_capture "$d" "10-after-competitor"
  object_capture "$d" "10-after-competitor"

  # Try the earlier artifact. Expected: REJECTED because the state moved on.
  ( cd "$ROOT/tofu" && record "$d/stale-plan-apply" tofu apply -input=false "$d/reviewed.tfplan" ) || true
  object_capture "$d" "20-after-stale-plan"; state_capture "$d" "20-after-stale-plan"
  audit_capture TC-03 || echo "WARNING: TC-03 audit snapshot not captured" >&2
}

tc04(){ local d="$RUN_ROOT/TC-04"; tc_common_setup TC-04 || return 1
  require flux
  # Flux is installed SUSPENDED; its source carries the intent value=C.
  record "$d/flux-install" flux install --namespace=flux-system --components=source-controller,kustomize-controller || true
  "$ROOT/scripts/gitops-setup.sh" "$d" || { echo "gitops source could not be set up" >&2; }
  flux suspend kustomization "$KS" -n flux-system >/dev/null 2>&1 || true

  ( cd "$ROOT/tofu" && record "$d/reviewed-plan" tofu plan -input=false -var "value=B" -out "$d/reviewed.tfplan" ) || true
  ( cd "$ROOT/tofu" && tofu show -json "$d/reviewed.tfplan" > "$d/reviewed.plan.json" 2>/dev/null ) || true
  approval_write "$d" "plan_artifact" "reviewed.tfplan" "$d/reviewed.tfplan"
  ( cd "$ROOT/tofu" && record "$d/apply" tofu apply -input=false "$d/reviewed.tfplan" ) || true
  object_capture "$d" "10-after-apply"; state_capture "$d" "10-after-apply"

  # Apply completion barrier: do NOT go on until the API shows B.
  local v; v=$(jq -r '.data.value // empty' "$d/object.10-after-apply.json")
  printf '%s\n' "${v:-NONE}" > "$d/barrier.value"
  if [ "${v:-}" != "B" ]; then
    event TC-04 "barrier" "harness" "$d/barrier.value" "B NOT seen after apply: TC-04 inconclusive"
  fi

  # Reconciliation window: 120 s, target 3 completed opportunities.
  flux resume kustomization "$KS" -n flux-system >/dev/null 2>&1 || true
  local end=$((SECONDS+120)) i=0
  : > "$d/opportunities.jsonl"
  while [ $SECONDS -lt $end ]; do
    i=$((i+1))
    record "$d/reconcile-$i" flux reconcile kustomization "$KS" -n flux-system --timeout=60s || true
    kubectl -n flux-system get kustomization "$KS" -o json \
      | jq -c --argjson n "$i" '{opportunity:$n,
          requestedAt:(.metadata.annotations["reconcile.fluxcd.io/requestedAt"] // null),
          lastHandledReconcileAt:(.status.lastHandledReconcileAt // null),
          observedGeneration:(.status.observedGeneration // null),
          revision:(.status.lastAppliedRevision // null)}' >> "$d/opportunities.jsonl" 2>/dev/null || true
    object_capture "$d" "20-opportunity-$i"
    [ $i -ge 3 ] && break
  done
  kubectl -n flux-system logs deployment/kustomize-controller --timestamps=true \
    > "$d/kustomize-controller.log" 2>/dev/null || true
  object_capture "$d" "30-window-end"
  audit_capture TC-04 || echo "WARNING: TC-04 audit snapshot not captured" >&2
}

tc05(){ # Four single-writer sub-runs: the SAME phases, NO outside intervention.
  local top="$RUN_ROOT/TC-05"; mkdir -p "$top"
  for sub in 01 02 03 04; do
    local d="$top/sub-$sub"; mkdir -p "$d"
    scenario_cluster "TC-05" || return 1; actors_setup
    export KUBECONFIG="$(kubeconfig_path)"
    tofu_prepare || return 1
    ( cd "$ROOT/tofu" && record "$d/bootstrap" tofu apply -input=false -auto-approve -var "value=A" ) || true
    object_capture "$d" "00-start"
    case "$sub" in
      01) ( cd "$ROOT/tofu" && record "$d/plan" tofu plan -input=false -var "value=A" -out "$d/p.tfplan" ) || true ;;
      *)  ( cd "$ROOT/tofu" && record "$d/plan" tofu plan -input=false -var "value=B" -out "$d/p.tfplan" ) || true ;;
    esac
    approval_write "$d" "plan_artifact" "p.tfplan" "$d/p.tfplan"
    ( cd "$ROOT/tofu" && record "$d/apply" tofu apply -input=false "$d/p.tfplan" ) || true
    object_capture "$d" "20-after-apply"; state_capture "$d" "20-after-apply"
    # The control produces NO fake reconciliation opportunity.
    event "TC-05" "control" "harness" "$d/apply.stdout" "sub-$sub done"
    # The four sub-runs mount the SAME audit directory, so k3s appends to one
    # file. The control's claim holds for ALL four sub-runs, so that is the
    # right behaviour; no merge is done (it would duplicate).
    audit_capture "TC-05" 2>/dev/null || true
  done
}

tc06(){ # TC-02 with a pre-apply drift gate, measured two ways, on two sub-paths:
  #   drift: the second writer sets C after the plan is saved (TC-02's situation)
  #   clean: no second writer (does the gate let the approved plan through?)
  # Gate 1, exit code: `tofu plan -refresh-only -detailed-exitcode` (0 none, 2 changes). Recorded only.
  # Gate 2, drift report: `tofu plan -refresh-only -json`, counting resource_drift messages. Recorded only.
  # Gate 3, the decision: a saved refresh-only plan (`-out`, then `tofu show -json`), looking for drift only in the
  #   attributes the reviewed plan changes. Gates 1 and 2 react to any attribute the provider reports as changed
  #   (with this provider: binary_data null -> {} on every refresh), so they cannot tell the two sub-paths apart.
  # No gate writes state: a refresh-only plan is not applied.
  local top="$RUN_ROOT/TC-06"; mkdir -p "$top"
  local sub d drift fdrift
  for sub in drift clean; do
    d="$top/$sub"; mkdir -p "$d"
    scenario_cluster "TC-06" || return 1; actors_setup
    export KUBECONFIG="$(kubeconfig_path)"
    tofu_prepare || return 1
    ( cd "$ROOT/tofu" && record "$d/bootstrap" tofu apply -input=false -auto-approve -var "value=A" ) || true
    object_capture "$d" "00-start"; state_capture "$d" "00-start"
    ( cd "$ROOT/tofu" && record "$d/reviewed-plan" tofu plan -input=false -var "value=B" -out "$d/reviewed.tfplan" ) || true
    ( cd "$ROOT/tofu" && tofu show -json "$d/reviewed.tfplan" > "$d/reviewed.plan.json" 2>/dev/null ) || : > "$d/reviewed.plan.json"
    approval_write "$d" "plan_artifact" "reviewed.tfplan" "$d/reviewed.tfplan"
    [ "$sub" = drift ] && second_writer_write "$d" TC-06 C
    object_capture "$d" "10-before-gate"; state_capture "$d" "10-before-gate"

    ( cd "$ROOT/tofu" && record "$d/gate-exitcode" tofu plan -input=false -refresh-only -detailed-exitcode -var "value=B" ) || true
    ( cd "$ROOT/tofu" && record "$d/gate-json" tofu plan -input=false -refresh-only -json -var "value=B" ) || true
    drift=$(jq -s '[.[] | select(.type == "resource_drift")] | length' "$d/gate-json.stdout" 2>/dev/null)
    case "$drift" in ''|*[!0-9]*) drift=UNKNOWN ;; esac
    printf '%s\n' "$drift" > "$d/gate.drift-count"
    ( cd "$ROOT/tofu" && record "$d/gate-refresh-plan" tofu plan -input=false -refresh-only -var "value=B" -out "$d/refresh.tfplan" ) || true
    ( cd "$ROOT/tofu" && tofu show -json "$d/refresh.tfplan" > "$d/refresh.plan.json" 2>/dev/null ) || : > "$d/refresh.plan.json"
    # resources the reviewed plan changes, and for each the top-level attributes whose planned value differs from the
    # value it was planned from (present before, after, or both); drift counts when one of those attributes changed
    # outside OpenTofu. Fails closed: a failed or errored plan, an empty or unreadable plan JSON, an action other
    # than update, or any value unknown until apply is an error (jq exits non-zero), which makes the result UNKNOWN
    # and the decision block; so is a failed reviewed or refresh-only plan command.
    fdrift=$(jq -n --slurpfile r "$d/reviewed.plan.json" --slurpfile f "$d/refresh.plan.json" '
      if ($r | length) != 1 or ($f | length) != 1 or ($r[0].format_version | type) != "string"
         or ($f[0].format_version | type) != "string" or ($r[0].resource_changes | type) != "array"
      then error("plan JSON missing or unreadable")
      elif ($r[0].errored // false) != false or ($f[0].errored // false) != false then error("errored plan")
      else . end
      | [ $r[0].resource_changes[] | select(.change.actions != ["no-op"]) | . as $c
        | if $c.change.actions != ["update"] then error("unsupported action \($c.change.actions) at \($c.address)") else . end
        | if [ $c.change.after_unknown // {} | .. | select(. == true) ] != []
          then error("value unknown until apply at \($c.address)") else . end
        | ([ ($c.change.before // {} | keys), ($c.change.after // {} | keys) ] | add | unique) as $keys
        | [ $keys[] | select($c.change.before[.] != $c.change.after[.]) ] as $planned
        | [ $f[0].resource_drift // [] | .[] | select(.address == $c.address) ] as $drs
        | select(any($drs[]; . as $dr | any($planned[]; $dr.change.before[.] != $dr.change.after[.]))) ]
      | length' 2>/dev/null) || fdrift=UNKNOWN
    [ "$(cat "$d/reviewed-plan.rc" 2>/dev/null)" = 0 ] && [ "$(cat "$d/gate-refresh-plan.rc" 2>/dev/null)" = 0 ] || fdrift=UNKNOWN
    case "$fdrift" in ''|*[!0-9]*) fdrift=UNKNOWN ;; esac
    printf '%s\n' "$fdrift" > "$d/gate.planned-field-drift"
    if [ "$fdrift" = 0 ]; then
      printf 'apply\n' > "$d/gate.decision"
      ( cd "$ROOT/tofu" && record "$d/apply" tofu apply -input=false "$d/reviewed.tfplan" ) || true
    else
      # drift in a planned attribute, or the result could not be computed: the saved plan is not applied
      printf 'block\n' > "$d/gate.decision"
    fi
    event TC-06 "gate" "harness" "$d/gate.decision" "sub=$sub drift=$drift planned-field-drift=$fdrift decision=$(cat "$d/gate.decision")"
    object_capture "$d" "20-after-gate"; state_capture "$d" "20-after-gate"
    audit_capture "TC-06" 2>/dev/null || true
  done
}

# ------------------------------------------------------------------
finish(){
  # Last snapshot: taken BEFORE the archive closes.
  audit_capture "closing" || echo "WARNING: closing audit snapshot not captured" >&2
  # The archive manifest; only the experiment cluster is removed afterwards.
  ( cd "$RUN_ROOT" && find . -type f ! -name 'MANIFEST.sha256' -print0 \
      | sort -z | xargs -0 sha256sum > MANIFEST.sha256 ) 2>/dev/null || true
  echo
  echo "== run finished: $RUN_ROOT"
  echo "   MANIFEST.sha256 digest: $(sha256sum "$RUN_ROOT/MANIFEST.sha256" 2>/dev/null | awk '{print $1}')"
  echo "   ^ keep this digest SOMEWHERE ELSE (the archive cannot verify itself)"
  echo
  echo "   the cluster is still up. remove it with: scripts/experiment.sh clean"
}

case "$CMD" in
  clean) cluster_remove || exit 1; echo "cluster removed"; exit 0 ;;
  TC-01) run_start; tc01; finish ;;
  TC-02) run_start; tc02; finish ;;
  TC-03) run_start; tc03; finish ;;
  TC-04) run_start; tc04; finish ;;
  TC-05) run_start; tc05; finish ;;
  TC-06) run_start; tc06; finish ;;
  all)   run_start; tc01; tc02; tc03; tc04; tc05; tc06; finish ;;
  *) echo "unknown: $CMD" >&2; exit 2 ;;
esac
