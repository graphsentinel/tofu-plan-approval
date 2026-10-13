#!/usr/bin/env bash
# @trace EV-001
# Claim: the identities of the running components EQUAL the pins (lab/.runtime/pins.env).
# Expected: 0 when every pin matches the running version; 1 on a mismatch; 77 when a binary is missing.
. "$(dirname "$0")/../scripts/lib.sh"
pins_load
require tofu flux k3d kubectl

drift=""
compare(){ # compare <name> <expected> <actual>
  [ -n "$3" ] || cannot_run "$1 version could not be read"
  [ "$2" = "$3" ] || drift="$drift $1(expected=$2 actual=$3)"
}
compare tofu    "$TOFU_VERSION"    "$(tofu version | awk 'NR==1{sub(/^v/,"",$2);print $2}')"
compare flux    "$FLUX_VERSION"    "$(flux version --client 2>/dev/null | awk '{sub(/^v/,"",$2);print $2}')"
compare k3d     "$K3D_VERSION"     "$(k3d version | awk '/k3d version/{print $3}')"
compare kubectl "$KUBECTL_VERSION" "$(kubectl version --client -o json 2>/dev/null | jq -r .clientVersion.gitVersion)"

# Provider version: tofu/versions.tf and the pins must agree.
tf=$(grep -oP 'version\s*=\s*"\K[0-9.]+' "$ROOT/tofu/versions.tf" | head -1)
compare k8s-provider "$K8S_PROVIDER_VERSION" "$tf"

[ -z "${drift// }" ] || fail "pin drift:$drift"
pass "every pin equals pins.env"
