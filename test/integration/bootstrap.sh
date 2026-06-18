#!/usr/bin/env bash
# Download pinned versions of the tooling required by the integration tests
# into test/integration/.bin/ so the harness is reproducible regardless of
# whatever the host happens to have on PATH.
#
# Idempotent: re-running is a no-op when versions already match.
#
# Only `docker`, `curl`, `tar`, `git`, and a recent bash are assumed.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="${HERE}/.bin"
mkdir -p "${BIN}"

K3D_VERSION="v5.7.5"
HELM_VERSION="v3.16.4"
KUBECTL_VERSION="v1.31.3"
BATS_CORE_VERSION="v1.11.0"
BATS_SUPPORT_VERSION="v0.3.0"
BATS_ASSERT_VERSION="v2.1.0"

uname_m="$(uname -m)"
case "${uname_m}" in
  x86_64|amd64) ARCH="amd64" ;;
  aarch64|arm64) ARCH="arm64" ;;
  *) echo "unsupported arch: ${uname_m}" >&2; exit 1 ;;
esac

OS="$(uname -s | tr '[:upper:]' '[:lower:]')"

log() { printf '[bootstrap] %s\n' "$*" >&2; }

# Records the version we installed so the next run can skip the download. Each
# tool writes a sibling `.version` file; we treat mismatch as "needs re-install".
need_install() {
  local marker="$1" expected="$2"
  [ ! -f "${marker}" ] || [ "$(cat "${marker}")" != "${expected}" ]
}

install_k3d() {
  local target="${BIN}/k3d" marker="${BIN}/.k3d.version"
  if ! need_install "${marker}" "${K3D_VERSION}"; then
    return 0
  fi
  log "installing k3d ${K3D_VERSION}"
  local url="https://github.com/k3d-io/k3d/releases/download/${K3D_VERSION}/k3d-${OS}-${ARCH}"
  curl -fsSL "${url}" -o "${target}"
  chmod +x "${target}"
  printf '%s' "${K3D_VERSION}" > "${marker}"
}

install_helm() {
  local target="${BIN}/helm" marker="${BIN}/.helm.version"
  if ! need_install "${marker}" "${HELM_VERSION}"; then
    return 0
  fi
  log "installing helm ${HELM_VERSION}"
  local tarball
  tarball="$(mktemp -t helm.XXXXXX.tar.gz)"
  trap 'rm -f "${tarball}"' RETURN
  local url="https://get.helm.sh/helm-${HELM_VERSION}-${OS}-${ARCH}.tar.gz"
  curl -fsSL "${url}" -o "${tarball}"
  local tmp
  tmp="$(mktemp -d)"
  tar -xzf "${tarball}" -C "${tmp}"
  mv "${tmp}/${OS}-${ARCH}/helm" "${target}"
  rm -rf "${tmp}"
  chmod +x "${target}"
  printf '%s' "${HELM_VERSION}" > "${marker}"
}

install_kubectl() {
  local target="${BIN}/kubectl" marker="${BIN}/.kubectl.version"
  if ! need_install "${marker}" "${KUBECTL_VERSION}"; then
    return 0
  fi
  log "installing kubectl ${KUBECTL_VERSION}"
  local url="https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/${OS}/${ARCH}/kubectl"
  curl -fsSL "${url}" -o "${target}"
  chmod +x "${target}"
  printf '%s' "${KUBECTL_VERSION}" > "${marker}"
}

clone_at_tag() {
  # git clone a repo at a specific tag, idempotent.
  local repo="$1" tag="$2" dest="$3"
  local marker="${dest}/.version"
  if [ -d "${dest}" ] && [ -f "${marker}" ] && [ "$(cat "${marker}")" = "${tag}" ]; then
    return 0
  fi
  log "cloning ${repo} @ ${tag} -> ${dest}"
  rm -rf "${dest}"
  git clone --quiet --depth 1 --branch "${tag}" "${repo}" "${dest}"
  printf '%s' "${tag}" > "${marker}"
}

install_bats() {
  clone_at_tag "https://github.com/bats-core/bats-core.git" "${BATS_CORE_VERSION}" "${BIN}/bats/bats-core"
  clone_at_tag "https://github.com/bats-core/bats-support.git" "${BATS_SUPPORT_VERSION}" "${BIN}/bats/bats-support"
  clone_at_tag "https://github.com/bats-core/bats-assert.git" "${BATS_ASSERT_VERSION}" "${BIN}/bats/bats-assert"
}

install_k3d
install_helm
install_kubectl
install_bats

log "ready: $(${BIN}/k3d --version | head -1)"
log "ready: $(${BIN}/helm version --short)"
log "ready: $(${BIN}/kubectl version --client=true 2>/dev/null | head -1)"
log "ready: bats $(${BIN}/bats/bats-core/bin/bats --version)"
