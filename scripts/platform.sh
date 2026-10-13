#!/usr/bin/env bash
# Layer 1, the platform: tools and the lab's k3d cluster. The lab (scripts/lab.sh) is installed on top.
#
#   scripts/platform.sh install       install what is missing on an Ubuntu host (24.04 / 26.04, amd64 or arm64)
#   scripts/platform.sh cluster-up    the lab's k3d cluster (t27), its local registry (t27-reg) and audit policy
#   scripts/platform.sh cluster-down  delete that cluster and registry, then check nothing of them is left
#   scripts/platform.sh status        tool versions, cluster
#
# 'install' never replaces what is already there:
#   - Ubuntu's own packages, at the version Ubuntu ships, only the missing ones: Docker (docker.io), jq, curl,
#     ca-certificates, unzip, python3, git. An existing Docker engine of any source is left unchanged.
#   - tofu, flux, k3d and kubectl at the versions in scripts/versions.env go into this repository's bin/
#     (sha256-checked, no root). A tool already in bin/ at the pinned version is kept. Tools elsewhere on the
#     host are not touched; the lab's scripts put bin/ first on their PATH.
#   - lab/.runtime/pins.env is written from scripts/versions.env; checks/01-pins.sh enforces it.
#
# The cluster is the lab's own: every scenario of the experiment deletes and recreates it, so it cannot be an
# existing cluster. A cluster named t27 that this lab did not create is never deleted.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=versions.env
source "$ROOT/scripts/versions.env"
BIN="$ROOT/bin"; RUNTIME="$ROOT/lab/.runtime"
export PATH="$BIN:$PATH"
log() { printf '\n==> %s\n' "$*"; }
die() { echo "error: $*" >&2; exit 1; }
ME=$(id -un)

arch() { case "$(uname -m)" in x86_64) echo amd64 ;; aarch64|arm64) echo arm64 ;; *) die "unsupported architecture: $(uname -m)" ;; esac; }

# fetch <url> <checksum-url> <name-in-checksum-file> <out>: download and verify against the publisher's checksums
fetch() {
  local url=$1 sums=$2 name=$3 out=$4 want got
  curl -fsSLo "$out" "$url" || die "download failed: $url"
  want=$(curl -fsSL "$sums" | awk -v n="$name" '{f=$2; sub(/^\*/,"",f); k=f; sub(/.*\//,"",k)} f==n || k==n {print $1; exit}')
  [ -n "$want" ] || die "no checksum for $name in $sums"
  got=$(sha256sum "$out" | cut -d' ' -f1)
  [ "$want" = "$got" ] || die "checksum mismatch for $name: expected $want, got $got"
  echo "  sha256 ok  $name"
}

have() { [ -x "$BIN/$1" ] && [ "$("$1"_version 2>/dev/null)" = "$2" ]; }
tofu_version()    { "$BIN/tofu" version 2>/dev/null | awk 'NR==1{sub(/^v/,"",$2);print $2}'; }
flux_version()    { "$BIN/flux" version --client 2>/dev/null | awk '{sub(/^v/,"",$2);print $2}'; }
k3d_version()     { "$BIN/k3d" version 2>/dev/null | awk '/k3d version/{print $3}'; }
kubectl_version() { "$BIN/kubectl" version --client -o json 2>/dev/null | jq -r .clientVersion.gitVersion; }

# ---------------------------------------------------------------- install
cmd_install() {
  command -v apt-get >/dev/null || die "install supports Ubuntu (apt); elsewhere install docker, jq, curl, unzip, python3 and git yourself, then run this again"
  local a; a=$(arch)
  export DEBIAN_FRONTEND=noninteractive

  # only packages that are missing: 'apt-get install' of an installed package would also upgrade it
  missing_pkgs() { local p; for p in "$@"; do dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q "install ok installed" || echo "$p"; done; }
  local need; need=$(missing_pkgs jq curl ca-certificates unzip python3 git)
  if [ -n "$need" ]; then
    log "apt packages (Ubuntu's versions): $(echo $need)"
    sudo apt-get update -y
    # shellcheck disable=SC2086
    sudo -E apt-get install -y --no-install-recommends $need
  else
    log "apt packages: jq, curl, ca-certificates, unzip, python3, git already installed, left unchanged"
  fi

  local new_group=0
  if command -v docker >/dev/null 2>&1 || command -v podman >/dev/null 2>&1; then
    # any existing engine (docker-ce, docker.io, rootless, snap, Desktop, podman) is left as it is
    log "container engine already installed, left unchanged: $(docker --version 2>/dev/null || podman --version 2>/dev/null)"
  else
    log "Docker from Ubuntu's docker.io package, service enabled, $ME added to group docker"
    sudo apt-get update -y
    sudo -E apt-get install -y docker.io
    sudo systemctl enable --now docker
    if ! id -nG "$ME" | grep -qw docker; then sudo usermod -aG docker "$ME"; new_group=1; fi
  fi

  mkdir -p "$BIN" "$RUNTIME"
  local tmp; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' RETURN

  if have tofu "$TOFU_VERSION"; then log "tofu $TOFU_VERSION already in bin/"
  else
    log "OpenTofu $TOFU_VERSION (github.com/opentofu/opentofu)"
    local z="tofu_${TOFU_VERSION}_linux_${a}.zip" u="https://github.com/opentofu/opentofu/releases/download/v${TOFU_VERSION}"
    fetch "$u/$z" "$u/tofu_${TOFU_VERSION}_SHA256SUMS" "$z" "$tmp/$z"
    unzip -oq "$tmp/$z" tofu -d "$tmp" && install -m 0755 "$tmp/tofu" "$BIN/tofu"
  fi

  if have flux "$FLUX_VERSION"; then log "flux $FLUX_VERSION already in bin/"
  else
    log "Flux CLI $FLUX_VERSION (github.com/fluxcd/flux2)"
    local t="flux_${FLUX_VERSION}_linux_${a}.tar.gz" u="https://github.com/fluxcd/flux2/releases/download/v${FLUX_VERSION}"
    fetch "$u/$t" "$u/flux_${FLUX_VERSION}_checksums.txt" "$t" "$tmp/$t"
    tar -xzf "$tmp/$t" -C "$tmp" flux && install -m 0755 "$tmp/flux" "$BIN/flux"
  fi

  if have k3d "$K3D_VERSION"; then log "k3d $K3D_VERSION already in bin/"
  else
    log "k3d $K3D_VERSION (github.com/k3d-io/k3d)"
    local u="https://github.com/k3d-io/k3d/releases/download/$K3D_VERSION"
    fetch "$u/k3d-linux-$a" "$u/checksums.txt" "k3d-linux-$a" "$tmp/k3d"
    install -m 0755 "$tmp/k3d" "$BIN/k3d"
  fi

  if have kubectl "$KUBECTL_VERSION"; then log "kubectl $KUBECTL_VERSION already in bin/"
  else
    log "kubectl $KUBECTL_VERSION (dl.k8s.io)"
    local u="https://dl.k8s.io/release/$KUBECTL_VERSION/bin/linux/$a"
    curl -fsSLo "$tmp/kubectl" "$u/kubectl" || die "download failed: $u/kubectl"
    echo "$(curl -fsSL "$u/kubectl.sha256")  $tmp/kubectl" | sha256sum -c --quiet - || die "checksum mismatch for kubectl"
    echo "  sha256 ok  kubectl"
    install -m 0755 "$tmp/kubectl" "$BIN/kubectl"
  fi

  # the run-time copy of the pins, enforced by checks/01-pins.sh
  { echo "# written by scripts/platform.sh install from scripts/versions.env on $(date -u +%FT%TZ); do not edit"
    grep -E '^[A-Z0-9_]+=' "$ROOT/scripts/versions.env"; } > "$RUNTIME/pins.env"

  # k3s inside Docker needs enough inotify watches; only raised, never lowered
  log "inotify limits for k3s-in-docker"
  local conf="" key want cur kv
  for kv in fs.inotify.max_user_instances=1024 fs.inotify.max_user_watches=1048576; do
    key=${kv%=*}; want=${kv#*=}; cur=$(sysctl -n "$key")
    if [ "$cur" -lt "$want" ]; then conf+="$key=$want"$'\n'; echo "  $key $cur -> $want"; else echo "  $key $cur (kept)"; fi
  done
  if [ -n "$conf" ]; then printf '%s' "$conf" | sudo tee /etc/sysctl.d/99-tofu-plan-approval.conf >/dev/null; sudo sysctl --system >/dev/null; fi

  cmd_status_tools
  echo
  [ "$new_group" = 1 ] && echo "You were added to the docker group; the next commands pick it up by themselves (sg docker). Next:"
  echo "  scripts/platform.sh cluster-up"
  echo "  scripts/lab.sh all"
}

# ---------------------------------------------------------------- cluster
# right after 'install' the docker group is not active in this shell yet: run again under it
reexec_docker_group() {
  command -v docker >/dev/null 2>&1 || return 0
  docker info >/dev/null 2>&1 && return 0
  if [ -z "${LAB_SG:-}" ] && getent group docker | grep -qw "$ME" && command -v sg >/dev/null; then
    export LAB_SG=1; exec sg docker -c "$(printf '%q ' "$0" "$@")"
  fi
  command -v podman >/dev/null 2>&1 || die "docker not usable by $ME (log out and in again so the docker group applies)"
}

cmd_cluster_up() {
  [ -x "$BIN/k3d" ] && [ -f "$RUNTIME/pins.env" ] || die "tools missing: scripts/platform.sh install"
  # shellcheck source=/dev/null
  . "$ROOT/scripts/lib.sh"; pins_load
  if cluster_exists; then
    cluster_owned || die "a k3d cluster named $CLUSTER exists and was not created by this lab; delete or rename it first"
    log "k3d cluster $CLUSTER exists (scripts/platform.sh cluster-down to start over)"
  else
    log "k3d cluster $CLUSTER ($K3S_IMAGE), registry $REGISTRY (localhost:$REGISTRY_PORT), audit policy k3d/audit-policy.yaml"
    RUN_ROOT="$RUNTIME" cluster_create "$RUNTIME/audit" "$RUNTIME/kubeconfig" || die "cluster-up failed"
  fi
  k3d kubeconfig get "$CLUSTER" > "$RUNTIME/kubeconfig"; chmod 600 "$RUNTIME/kubeconfig"
  kubectl --kubeconfig "$RUNTIME/kubeconfig" wait --for=condition=Ready node --all --timeout=180s
  echo "kubeconfig: lab/.runtime/kubeconfig (context k3d-$CLUSTER)"
}

cmd_cluster_down() {
  [ -x "$BIN/k3d" ] || die "k3d not found in bin/: scripts/platform.sh install"
  # shellcheck source=/dev/null
  . "$ROOT/scripts/lib.sh"; pins_load
  cluster_remove || die "cluster-down refused"
  local left=""
  cluster_exists && left+=" cluster $CLUSTER"
  k3d registry list -o json 2>/dev/null | jq -e --arg n "$REGISTRY" 'map(select(.name==$n or .name=="k3d-"+$n))|length>0' >/dev/null && left+=" registry $REGISTRY"
  [ -z "$left" ] || die "still present after cluster-down:$left"
  rm -f "$RUNTIME/kubeconfig"
  echo "cluster $CLUSTER and registry $REGISTRY removed"
}

# ---------------------------------------------------------------- status
cmd_status_tools() {
  log "tools (lab/bin first on PATH)"
  printf '  %-8s %-10s pinned %s\n' tofu "$(tofu_version || true)" "$TOFU_VERSION"
  printf '  %-8s %-10s pinned %s\n' flux "$(flux_version || true)" "$FLUX_VERSION"
  printf '  %-8s %-10s pinned %s\n' k3d "$(k3d_version || true)" "$K3D_VERSION"
  printf '  %-8s %-10s pinned %s\n' kubectl "$(kubectl_version || true)" "$KUBECTL_VERSION"
  printf '  %-8s %s\n' engine "$(docker version --format 'docker {{.Server.Version}}' 2>/dev/null || podman --version 2>/dev/null || echo none)"
  printf '  %-8s %s\n' jq "$(jq --version 2>/dev/null || echo missing)"
  printf '  %-8s %s\n' python3 "$(python3 --version 2>/dev/null | cut -d' ' -f2 || echo missing)"
}

cmd_status() {
  cmd_status_tools
  log "cluster $CLUSTER"
  if [ -f "$RUNTIME/kubeconfig" ] && kubectl --kubeconfig "$RUNTIME/kubeconfig" get nodes 2>/dev/null; then :; else echo "  not running"; fi
}

case "${1:-}" in
  install) cmd_install ;;
  cluster-up) reexec_docker_group cluster-up; cmd_cluster_up ;;
  cluster-down) reexec_docker_group cluster-down; cmd_cluster_down ;;
  status) cmd_status ;;
  *) sed -n '2,19p' "$0"; exit 2 ;;
esac
