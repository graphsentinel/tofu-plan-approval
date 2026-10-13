#!/usr/bin/env bash
# Compares the pins in scripts/versions.env with the latest upstream stable releases.
# Read-only: it changes nothing. The published result holds for the pinned versions; a newer version is a separate
# measurement (edit versions.env on a branch, run scripts/platform.sh install and scripts/lab.sh all, compare).
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=versions.env
source "$ROOT/scripts/versions.env"

gh_latest() { curl -fsSL "https://api.github.com/repos/$1/releases/latest" | jq -r .tag_name 2>/dev/null || echo "?"; }
tf_latest() { curl -fsSL "https://registry.opentofu.org/v1/providers/hashicorp/kubernetes/versions" 2>/dev/null \
  | jq -r '[.versions[].version | select(test("^[0-9]+\\.[0-9]+\\.[0-9]+$"))] | sort_by(split(".")|map(tonumber)) | last' 2>/dev/null || echo "?"; }

row() { local s="same"; [ "${2#v}" != "${3#v}" ] && s="NEWER AVAILABLE"; [ "$3" = "?" ] || [ -z "$3" ] && s="unknown"; printf '%-14s %-26s %-26s %s\n' "$1" "$2" "$3" "$s"; }
printf '%-14s %-26s %-26s %s\n' COMPONENT PINNED LATEST STATUS
row opentofu     "$TOFU_VERSION"         "$(gh_latest opentofu/opentofu)"
row flux         "$FLUX_VERSION"         "$(gh_latest fluxcd/flux2)"
row k3d          "$K3D_VERSION"          "$(gh_latest k3d-io/k3d)"
row kubectl      "$KUBECTL_VERSION"      "$(curl -fsSL https://dl.k8s.io/release/stable.txt)"
row k3s          "${K3S_IMAGE##*:}"      "$(gh_latest k3s-io/k3s | tr + -)"
row k8s-provider "$K8S_PROVIDER_VERSION" "$(tf_latest)"
