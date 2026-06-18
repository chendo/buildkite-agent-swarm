#!/usr/bin/env bash
# Shared helpers for the bats integration tests.
#
# run.sh exports the bin path / kubeconfig / chart path before invoking bats,
# so these helpers just consume those env vars.
# shellcheck shell=bash

# Sourcing bats-support / bats-assert gives us assert_success, assert_failure,
# assert_output, refute_output, etc.
load "${BK_IT_BIN}/bats/bats-support/load.bash"
load "${BK_IT_BIN}/bats/bats-assert/load.bash"

# Each scenario uses its own helm release so installs don't collide if the
# bats runner ever parallelises across files.
release_name() {
  # Map filename -> short release name. Bats sets BATS_TEST_FILENAME for us.
  local base
  base="$(basename "${BATS_TEST_FILENAME}" .bats)"
  # e.g. 02-cleanup-builds -> bk-02
  printf 'bk-%s' "${base%%-*}"
}

namespace() {
  # One namespace per scenario keeps cleanup trivial and avoids cross-test bleed.
  printf 'bk-it-%s' "$(release_name)" | sed 's/[^a-z0-9-]/-/g'
}

helm() { command helm "$@"; }
kubectl() { command kubectl "$@"; }

# helm install with the shared base values + any per-test overrides.
helm_install() {
  local ns
  ns="$(namespace)"
  kubectl create namespace "${ns}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  helm upgrade --install "$(release_name)" "${BK_IT_CHART}" \
    --namespace "${ns}" \
    --values "${BK_IT_HERE}/values-test.yaml" \
    --wait=false \
    "$@"
}

helm_uninstall() {
  local ns
  ns="$(namespace)"
  helm uninstall "$(release_name)" --namespace "${ns}" --ignore-not-found >/dev/null 2>&1 || true
  # Namespace deletion implicitly waits for every resource inside it, which
  # gives us a clean barrier without needing --wait on uninstall itself
  # (which can hang on stuck finalizers).
  kubectl delete namespace "${ns}" --wait=true --ignore-not-found --timeout=120s >/dev/null 2>&1 || true
}

# Wait until at least one pod matching the label selector is in the given
# phase, or fail after the timeout. We poll rather than `kubectl wait` because
# we want to tolerate the pod being created mid-wait (wait fails fast if the
# selector matches zero pods).
wait_for_pod() {
  local selector="$1" phase="${2:-Running}" timeout="${3:-180}"
  local ns
  ns="$(namespace)"
  local end=$(( SECONDS + timeout ))
  while [ ${SECONDS} -lt ${end} ]; do
    local got
    got="$(kubectl -n "${ns}" get pod -l "${selector}" \
      -o jsonpath='{range .items[*]}{.status.phase}{"\n"}{end}' 2>/dev/null || true)"
    if [ -n "${got}" ] && echo "${got}" | grep -qx "${phase}"; then
      return 0
    fi
    sleep 2
  done
  echo "timed out waiting for pod ${selector} to reach ${phase}" >&2
  kubectl -n "${ns}" get pods -o wide >&2 || true
  return 1
}

# Wait until at least one pod matching the selector has a metadata.name set,
# regardless of phase. Useful for pods that will crash-loop (agent w/ fake
# token) — we just need them to be visible in the kube API.
wait_for_pod_exists() {
  local selector="$1" timeout="${2:-120}"
  local ns
  ns="$(namespace)"
  local end=$(( SECONDS + timeout ))
  while [ ${SECONDS} -lt ${end} ]; do
    local name
    name="$(kubectl -n "${ns}" get pod -l "${selector}" \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    if [ -n "${name}" ]; then
      return 0
    fi
    sleep 2
  done
  echo "timed out waiting for pod with selector ${selector} to be created" >&2
  kubectl -n "${ns}" get pods -o wide >&2 || true
  return 1
}

# Wait until the named DaemonSet reports numberReady >= 1.
wait_for_daemonset_ready() {
  local name="$1" timeout="${2:-180}"
  local ns
  ns="$(namespace)"
  local end=$(( SECONDS + timeout ))
  while [ ${SECONDS} -lt ${end} ]; do
    local ready
    ready="$(kubectl -n "${ns}" get ds "${name}" -o jsonpath='{.status.numberReady}' 2>/dev/null || echo 0)"
    if [ "${ready:-0}" -ge 1 ]; then
      return 0
    fi
    sleep 2
  done
  echo "timed out waiting for daemonset ${name} to have a ready pod" >&2
  kubectl -n "${ns}" get ds "${name}" -o yaml >&2 || true
  return 1
}

# Return the name of the cleanup pod that is currently Running. Filtering by
# field selector avoids picking up a Terminating pod mid-rollout.
cleanup_pod_name() {
  local ns
  ns="$(namespace)"
  kubectl -n "${ns}" get pod -l "app=$(release_name)-cleanup" \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}'
}

dind_pod_name() {
  local ns
  ns="$(namespace)"
  kubectl -n "${ns}" get pod -l "app=$(release_name)-dind" \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}'
}

# Wait for the cleanup DaemonSet rollout to settle. Important after any change
# that rolls the pod (helm upgrade, kubectl set env, etc.).
wait_for_cleanup_rollout() {
  local timeout="${1:-180s}"
  local ns
  ns="$(namespace)"
  kubectl -n "${ns}" rollout status ds/"$(release_name)-cleanup" --timeout="${timeout}" >/dev/null
}

cleanup_exec() {
  local ns
  ns="$(namespace)"
  kubectl -n "${ns}" exec "$(cleanup_pod_name)" -c cleanup -- "$@"
}

dind_exec() {
  local ns
  ns="$(namespace)"
  kubectl -n "${ns}" exec "$(dind_pod_name)" -c dind -- "$@"
}

cleanup_logs() {
  local ns
  ns="$(namespace)"
  kubectl -n "${ns}" logs "$(cleanup_pod_name)" -c cleanup --tail=-1
}

# Count how many iterations of the cleanup loop have COMPLETED.
#
# The script logs "--- Cleanup complete, sleeping ${interval}s ---" at the
# very end of each iteration, right before the sleep. That marker is what we
# count — it's unambiguous: line present means iteration finished. Counting
# the "Cleanup run at ..." header instead is racier because the header is
# logged BEFORE the work, so a count bump could include an iteration that's
# still scanning.
cleanup_run_count() {
  cleanup_logs 2>/dev/null | grep -c '^--- Cleanup complete' || true
}

# Block until the cleanup loop has completed at least N MORE iterations than
# `baseline`. Pattern: stage state, capture baseline, wait for baseline+N.
#
# An iteration in flight when the baseline is captured may or may not have
# observed the staged state, so we wait for baseline+N+1 actual completed
# iterations — the +1 absorbs the possibly-in-flight one at baseline-capture
# time. Caller passes the post-staging "wanted" count (usually 1).
wait_for_cleanup_runs_since() {
  local baseline="$1" wanted="${2:-1}" timeout="${3:-90}"
  local target=$(( baseline + wanted + 1 ))
  local end=$(( SECONDS + timeout ))
  while [ ${SECONDS} -lt ${end} ]; do
    local count
    count="$(cleanup_run_count)"
    if [ "${count:-0}" -ge "${target}" ]; then
      return 0
    fi
    sleep 2
  done
  echo "timed out waiting for ${wanted} cleanup run(s) since baseline=${baseline} (target=${target}); have $(cleanup_run_count)" >&2
  cleanup_logs >&2 || true
  return 1
}
