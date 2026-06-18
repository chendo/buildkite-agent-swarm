#!/usr/bin/env bash
# Orchestrate the integration suite end-to-end:
#   1. Download pinned tooling (bootstrap.sh).
#   2. Create a single-node k3s cluster (k3d by default; a direct `docker run`
#      fallback when --mode=direct is used).
#   3. Run every *.bats file in this directory; each bats file is responsible
#      for installing/uninstalling its own helm release.
#   4. Delete the cluster on exit unless --keep was passed.
#
# Pass --keep to leave the cluster running for debugging. The bats files then
# emit the KUBECONFIG path they used so you can run kubectl yourself:
#   make integration-test KEEP=1
#   KUBECONFIG=test/integration/tmp/kubeconfig kubectl get pods -A
#
# --mode=direct skips k3d entirely and starts k3s as a single privileged
# docker container. Use it when running inside a rootless-docker / nested-
# docker environment that won't let k3d's cgroup-v2 entrypoint write to
# /sys/fs/cgroup (e.g. some sandboxed CI). The direct path requires the
# same set of pre-staged image tarballs in tmp/images/, since the k3s
# container's own DNS / network typically can't reach a registry there.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="${HERE}/.bin"
TMP="${HERE}/tmp"
CLUSTER_NAME="bk-cleanup-it"
DIRECT_CONTAINER="${CLUSTER_NAME}-direct"

KEEP=0
FILTER=""
MODE=k3d
while [ $# -gt 0 ]; do
  case "$1" in
    --keep) KEEP=1 ;;
    --filter) shift; FILTER="$1" ;;
    --mode) shift; MODE="$1" ;;
    --mode=*) MODE="${1#--mode=}" ;;
    -h|--help)
      cat <<EOF
Usage: $0 [--keep] [--filter <bats-glob>] [--mode k3d|direct]

  --keep              Skip cluster teardown so you can poke at it after.
  --filter <glob>     Only run bats files matching this glob (e.g. "02-*").
  --mode k3d          (default) Use k3d to manage the cluster.
  --mode direct       Skip k3d; run k3s as a single privileged docker
                      container. Use when k3d's cgroupv2 entrypoint fails
                      because /sys/fs/cgroup isn't writable (nested-docker
                      sandboxes, rootless docker without cgroup delegation).
EOF
      exit 0
      ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
  shift
done

case "${MODE}" in
  k3d|direct) ;;
  *) echo "unknown mode: ${MODE} (expected k3d or direct)" >&2; exit 2 ;;
esac

log() { printf '\n=== %s ===\n' "$*" >&2; }

mkdir -p "${TMP}"
export KUBECONFIG="${TMP}/kubeconfig"
export BK_IT_BIN="${BIN}"
export BK_IT_HERE="${HERE}"
export BK_IT_CLUSTER="${CLUSTER_NAME}"
export BK_IT_CHART="$(cd "${HERE}/../../stable/buildkite-agent-swarm" && pwd)"
export BK_IT_KEEP="${KEEP}"

PATH="${BIN}:${BIN}/bats/bats-core/bin:${PATH}"
export PATH

log "bootstrap"
"${HERE}/bootstrap.sh"

cleanup_cluster() {
  if [ "${KEEP}" = "1" ]; then
    log "leaving cluster running (--keep). KUBECONFIG=${KUBECONFIG}"
    return 0
  fi
  log "tearing down cluster (mode=${MODE})"
  case "${MODE}" in
    k3d)    k3d cluster delete "${CLUSTER_NAME}" >/dev/null 2>&1 || true ;;
    direct) docker rm -f "${DIRECT_CONTAINER}" >/dev/null 2>&1 || true ;;
  esac
  rm -f "${KUBECONFIG}"
}
trap cleanup_cluster EXIT

# Tarballs that lib code expects to find. The k3s image must be a registry
# the k3s container can reach (it pulls itself); we leave that for run-time.
stage_images() {
  # Compose a list of image refs that must be importable into the cluster
  # before bats tests run. We pull them on the host docker daemon (which can
  # reach registries) and save tarballs into tmp/images/. k3s/k3d both
  # auto-import any *.tar under /var/lib/rancher/k3s/agent/images.
  local images=(
    rancher/mirrored-pause:3.6
    rancher/mirrored-coredns-coredns:1.11.3
    buildkite/agent:3.49.0
    buildkite/agent:3.49-alpine-k8s
    docker:28.0.1-dind
    docker:28.0.1-cli
    alpine
    alpine:3.18
  )
  mkdir -p "${TMP}/images"
  for img in "${images[@]}"; do
    local fname
    fname="$(echo "${img}" | tr '/:' '__').tar"
    if [ -s "${TMP}/images/${fname}" ]; then continue; fi
    log "pulling + saving ${img}"
    docker pull --quiet "${img}" >/dev/null
    docker save "${img}" -o "${TMP}/images/${fname}"
  done
}

create_k3d() {
  if k3d cluster list "${CLUSTER_NAME}" >/dev/null 2>&1; then
    log "removing pre-existing k3d cluster ${CLUSTER_NAME}"
    k3d cluster delete "${CLUSTER_NAME}" >/dev/null 2>&1 || true
  fi

  log "creating k3d cluster ${CLUSTER_NAME}"
  # Bind-mount the pre-staged image tarballs into the agent images dir so
  # k3s auto-imports on startup. Needed when the k3s container itself can't
  # reach a registry — typical of nested-docker sandboxes.
  local k3d_extra=()
  if compgen -G "${TMP}/images/*.tar" > /dev/null; then
    log "found $(ls ${TMP}/images/*.tar | wc -l) pre-staged image tarball(s); will mount for auto-import"
    k3d_extra+=(--volume "${TMP}/images:/var/lib/rancher/k3s/agent/images@server:0")
  fi
  # 5 min covers a cold k3s image pull (~300MB) on slow registries.
  k3d cluster create --config "${HERE}/k3d-config.yaml" --wait --timeout 300s "${k3d_extra[@]}"
  k3d kubeconfig get "${CLUSTER_NAME}" > "${KUBECONFIG}"
  chmod 600 "${KUBECONFIG}"
}

create_direct() {
  # Sandbox-friendly fallback: run k3s as one privileged docker container,
  # bypassing k3d's cgroupv2 entrypoint and load-balancer node. The kubelet
  # flags here are the same ones we hand to k3d in k3d-config.yaml — they
  # let k3s come up when the host can't delegate cgroup writes.
  docker rm -f "${DIRECT_CONTAINER}" >/dev/null 2>&1 || true
  log "creating direct k3s container ${DIRECT_CONTAINER}"
  docker run -d --name "${DIRECT_CONTAINER}" --privileged \
    --tmpfs /run --tmpfs /var/run \
    -v "${TMP}/images:/var/lib/rancher/k3s/agent/images" \
    -p 6550:6443 \
    docker.io/rancher/k3s:v1.31.3-k3s1 server \
    --tls-san=0.0.0.0 \
    --disable=traefik --disable=servicelb --disable=metrics-server --disable=local-storage \
    --kubelet-arg=feature-gates=KubeletInUserNamespace=true \
    --kubelet-arg=cgroups-per-qos=false \
    --kubelet-arg=enforce-node-allocatable= >/dev/null

  log "waiting for k3s up"
  local i
  for i in $(seq 1 90); do
    if docker logs "${DIRECT_CONTAINER}" 2>&1 | grep -q 'k3s is up and running'; then
      break
    fi
    sleep 1
  done

  docker cp "${DIRECT_CONTAINER}:/etc/rancher/k3s/k3s.yaml" "${KUBECONFIG}" 2>/dev/null
  # k3s's generated kubeconfig hard-codes server: https://127.0.0.1:6443.
  # From this script we need a URL the kubectl binary can actually reach.
  # Probe candidates in order: the docker daemon's own host (works when the
  # docker daemon is a sibling container reachable by name — typical of
  # rootless-dind sandboxes), then localhost on the port-mapped 6550 (works
  # when run.sh runs on the same docker host), then the container's bridge
  # IP (works in flat docker setups).
  local docker_host_addr
  docker_host_addr="$(awk '/^Host:/{print $2; exit}' < <(docker info 2>/dev/null) || true)"
  local bridge_ip
  bridge_ip="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' "${DIRECT_CONTAINER}" | awk '{print $1}')"

  local candidates=()
  # When DOCKER_HOST is unix:///dind/docker.sock, the host is named `dind`
  # via /etc/hosts; same trick works for any sibling-container daemon.
  if [ -S "/dind/docker.sock" ] && getent hosts dind >/dev/null 2>&1; then
    candidates+=("dind:6550")
  fi
  candidates+=("localhost:6550" "127.0.0.1:6550")
  [ -n "${bridge_ip}" ] && candidates+=("${bridge_ip}:6443")

  # SAN won't include any of these addresses; skip TLS verify rather than
  # re-issuing certs (we control the cluster, this is integration-test scope).
  kubectl --kubeconfig="${KUBECONFIG}" config set-cluster default --insecure-skip-tls-verify=true >/dev/null
  kubectl --kubeconfig="${KUBECONFIG}" config unset clusters.default.certificate-authority-data >/dev/null
  chmod 600 "${KUBECONFIG}"

  local server="" c
  for c in "${candidates[@]}"; do
    sed -i.bak "s|server: https://.*|server: https://${c}|" "${KUBECONFIG}"
    if kubectl --kubeconfig="${KUBECONFIG}" --request-timeout=4s get --raw=/version >/dev/null 2>&1; then
      server="$c"
      log "kube API reachable at https://${server}"
      break
    fi
  done
  [ -n "${server}" ] || { echo "kube API not reachable on any of: ${candidates[*]}" >&2; exit 1; }
  rm -f "${KUBECONFIG}.bak"
}

stage_images

# In environments where /sys/fs/cgroup is read-only (rootless docker, nested
# docker), the chart's default docker:28.0.1-dind image fails on the cgroup
# evacuation step that runs before dockerd. We build a patched variant whose
# init script skips that block and ship it in via the image-tarball mount,
# then point the chart at it. The patch only removes a setup step needed
# for full container isolation — the docker daemon still runs and answers
# the API calls the cleanup pod makes, which is what we're testing.
build_patched_dind() {
  local tag="docker:28.0.1-dind-patched"
  local tar="${TMP}/images/$(echo "${tag}" | tr '/:' '__').tar"
  if [ -s "${tar}" ]; then return 0; fi
  log "building ${tag}"
  local dir
  dir="$(mktemp -d)"
  cat > "${dir}/Dockerfile" <<'DF'
FROM docker:28.0.1-dind
# Replace /usr/local/bin/dind with a variant that skips the cgroup-v2
# evacuation block (the upstream script does `mkdir /sys/fs/cgroup/init`
# which fails when cgroups aren't writable). The cleanup test scenarios
# only need a functional docker daemon, not isolated container execution,
# so this is safe for tests on rootless / nested-docker hosts.
COPY dind /usr/local/bin/dind
RUN chmod +x /usr/local/bin/dind
DF
  cat > "${dir}/dind" <<'SH'
#!/bin/sh
set -e
export container=docker
if [ -d /sys/kernel/security ] && ! mountpoint -q /sys/kernel/security; then
	mount -t securityfs none /sys/kernel/security 2>/dev/null || true
fi
if ! mountpoint -q /tmp; then
	mount -t tmpfs none /tmp 2>/dev/null || true
fi
# Cgroup v2 evacuation block from the upstream `dind` script is omitted:
# it does `mkdir /sys/fs/cgroup/init` which fails on hosts that don't
# delegate cgroup writes.
mount --make-rshared / 2>/dev/null || true
if [ $# -gt 0 ]; then exec "$@"; fi
echo >&2 'ERROR: No command specified.'
exit 1
SH
  docker build -q -t "${tag}" "${dir}" >/dev/null
  docker save "${tag}" -o "${tar}"
  rm -rf "${dir}"
}

case "${MODE}" in
  k3d)
    create_k3d
    ;;
  direct)
    build_patched_dind
    export BK_IT_DIND_IMAGE="docker:28.0.1-dind-patched"
    create_direct
    ;;
esac

log "cluster ready (mode=${MODE}): $(kubectl get nodes --no-headers | wc -l) node(s)"
kubectl get nodes

# Run bats files in sorted order so 01- runs before 02-, etc.
shopt -s nullglob
files=()
for f in "${HERE}"/*.bats; do
  base="$(basename "$f")"
  if [ -n "${FILTER}" ] && [[ "${base}" != ${FILTER} ]]; then
    continue
  fi
  files+=("$f")
done

if [ ${#files[@]} -eq 0 ]; then
  echo "no bats files matched filter '${FILTER}'" >&2
  exit 1
fi

log "running ${#files[@]} bats file(s)"
bats --print-output-on-failure --formatter pretty "${files[@]}"
