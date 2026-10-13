#!/usr/bin/env bash
# Flux source: the gitops/ directory is pushed as an OCI artifact to the k3d
# registry and reconciled through an OCIRepository + Kustomization.
#
# Hosting a Git server adds nothing to the claim. What matters is that the
# REVISION used is recorded and stays FIXED between runs.
set -uo pipefail
. "$(dirname "$0")/lib.sh"
D="${1:?tc directory required}"
pins_load
export KUBECONFIG="${KUBECONFIG:-$(kubeconfig_path)}"
: "${REGISTRY:=t27-reg}"; : "${REGISTRY_PORT:=5111}"

SHA=$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo 0000000000000000000000000000000000000000)
REV="main@sha1:$SHA"
TAG="v1"

# Pushed from the host: localhost:PORT. Read from inside the cluster: the registry's IP on the k3d network.
flux push artifact "oci://localhost:${REGISTRY_PORT}/t27-gitops:${TAG}" \
    --path="$ROOT/gitops" --source="local://t27" --revision="$REV" \
    --reproducible --insecure-registry > "$D/flux-push.stdout" 2> "$D/flux-push.stderr" \
  || { echo "OCI artifact could not be pushed" >&2; cat "$D/flux-push.stderr" >&2; return 1 2>/dev/null || exit 1; }

# Pods do NOT resolve the registry container NAME through CoreDNS (on the k3d
# network the container DNS is open to the node, not to pods). So the
# OCIRepository url uses the IP on the k3d network, and the IP is RECORDED in
# the run, otherwise "which source was reconciled" cannot be answered later.
RT=$(container_runtime)
REG_IP=$("$RT" inspect "$REGISTRY" \
  --format "{{(index .NetworkSettings.Networks \"k3d-$(cluster_name)\").IPAddress}}" 2>/dev/null)
[ -n "$REG_IP" ] || { echo "registry IP not found" >&2; exit 1; }
printf '%s\n' "$REG_IP" > "$D/gitops.registry-ip"

cat <<EOF | kubectl apply -f - > "$D/flux-source.stdout" 2> "$D/flux-source.stderr"
apiVersion: source.toolkit.fluxcd.io/v1
kind: OCIRepository
metadata:
  name: ${KS}
  namespace: flux-system
spec:
  interval: 1m
  insecure: true
  url: oci://${REG_IP}:5000/t27-gitops
  ref:
    tag: ${TAG}
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: ${KS}
  namespace: flux-system
spec:
  interval: 1m
  path: ./
  prune: false
  force: false
  targetNamespace: ${NS}
  sourceRef:
    kind: OCIRepository
    name: ${KS}
EOF

printf '%s\n' "$REV" > "$D/gitops.revision"
echo "gitops source set up (revision $REV)"
