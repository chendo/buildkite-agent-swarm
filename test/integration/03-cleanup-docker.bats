#!/usr/bin/env bats
#
# Scenario 3 — docker (DIND) cleanup correctness.
#
# Stage two kinds of garbage inside the DIND container:
#   - one exited container ("stopped-test")           -> deleted
#   - one dangling image (untagged layer)             -> deleted
# Plus one image that must NOT be touched:
#   - alpine:3.18 with tag still attached             -> kept
#
# After one cleanup cycle, the two stage-1 artefacts are gone and alpine:3.18
# remains. Then re-install in dry-run mode against fresh state and confirm
# nothing is deleted — covers the regression where unusedImages dry-run
# claimed to delete images that prune would actually keep (1149a31).

load lib.bash

setup_file() {
  # The default docker:28.0.1-dind image runs an init script that writes to
  # /sys/fs/cgroup/init, which fails on hosts that don't delegate cgroup
  # writes (rootless docker, nested docker, etc). $BK_IT_DIND_IMAGE lets the
  # harness override the DIND image with one that skips the cgroup setup;
  # if unset we use the chart default. See run.sh:create_direct() and
  # tmp/images/docker_28.0.1-dind-patched.tar.
  local extra=()
  if [ -n "${BK_IT_DIND_IMAGE:-}" ]; then
    extra+=(--set "dindDaemonSet.image=${BK_IT_DIND_IMAGE}")
  fi
  helm_install --set cleanup.intervalSeconds=5 "${extra[@]}"
  wait_for_daemonset_ready "$(release_name)-dind" 240
  wait_for_pod "app=$(release_name)-cleanup" Running 180

  # Side-load alpine:3.18 into the DIND pod's dockerd. The pod's own daemon
  # has its own image store (distinct from the node's containerd), so it
  # can't see images we pre-imported into k3s. Going via the registry would
  # require the DIND pod to have outbound DNS+TCP to docker.io, which is
  # often broken in nested-docker test envs. The tarball lives in tmp/images
  # next to the other staged images; we kubectl-cp it in and `docker load`.
  local ns
  ns="$(namespace)"
  local pod
  pod="$(dind_pod_name)"
  kubectl -n "${ns}" cp "${BK_IT_HERE}/tmp/images/alpine_3.18.tar" "${pod}:/tmp/alpine.tar" -c dind
  dind_exec docker load -i /tmp/alpine.tar
}

teardown_file() {
  helm_uninstall
}

stage_docker_garbage() {
  # `docker create` (not `docker run`) leaves a container in the "created"
  # state without ever starting it. `docker container prune` removes any
  # stopped container — including "created" — so this exercises the same
  # prune codepath, while side-stepping environments where the runtime
  # can't actually start a container (broken cgroup delegation).
  #
  # LABEL-only builds (no RUN) ditto: the layer diff is a metadata change,
  # so the build doesn't need to execute anything inside a container.
  # Rebuilding the same tag with a different LABEL leaves the previous
  # image dangling, which is what the prune-dangling test asserts on.
  dind_exec sh -c '
    set -e
    docker rm -f stopped-test >/dev/null 2>&1 || true
    docker create --name stopped-test alpine:3.18 true >/dev/null

    docker rmi -f throwaway:v1 >/dev/null 2>&1 || true
    printf "FROM alpine:3.18\nLABEL marker=first\n"  | docker build -t throwaway:v1 - >/dev/null 2>&1
    printf "FROM alpine:3.18\nLABEL marker=second\n" | docker build -t throwaway:v1 - >/dev/null 2>&1
  '
}

@test "wet-run cleanup removes the stopped container" {
  stage_docker_garbage

  # Sanity check: the stopped container exists before cleanup runs.
  run dind_exec sh -c 'docker ps -a --filter name=stopped-test -q'
  assert_success
  [ -n "$output" ]

  local baseline
  baseline="$(cleanup_run_count)"
  wait_for_cleanup_runs_since "${baseline}" 1 90

  run dind_exec sh -c 'docker ps -a --filter name=stopped-test -q'
  assert_success
  [ -z "$output" ]
}

@test "wet-run cleanup removes the dangling image but keeps the tagged image" {
  # By now setup_file + the previous test left the DIND in a known state:
  # the cleanup loop already ran, so the dangling image we created should be
  # gone but alpine:3.18 (still tagged) should remain.
  run dind_exec sh -c 'docker images --filter dangling=true -q | wc -l'
  assert_success
  assert_output "0"

  run dind_exec sh -c 'docker image inspect alpine:3.18 -f "{{.Id}}"'
  assert_success
}

@test "dry-run mode does not delete the stopped container" {
  # Flip DRY_RUN=true on the cleanup DS in place. Surgical — avoids a full
  # helm upgrade and the rollout coordination that goes with it. The DIND
  # DaemonSet is untouched, so its docker state from prior tests carries
  # over (which is fine; we restage what we need).
  local ns
  ns="$(namespace)"
  kubectl -n "${ns}" set env ds/"$(release_name)-cleanup" DRY_RUN=true >/dev/null
  wait_for_cleanup_rollout 120s
  wait_for_pod "app=$(release_name)-cleanup" Running 60

  # Stage AFTER the dry-run pod is up so no wet-run iteration ever sees this
  # state.
  stage_docker_garbage

  local baseline
  baseline="$(cleanup_run_count)"
  wait_for_cleanup_runs_since "${baseline}" 1 90

  run dind_exec sh -c 'docker ps -a --filter name=stopped-test -q'
  assert_success
  [ -n "$output" ]

  run cleanup_logs
  assert_success
  assert_output --partial "DRY RUN MODE"
}
