#!/usr/bin/env bats
#
# Scenario 2 — build-directory cleanup correctness.
#
# Stage three directories under /var/buildkite/builds:
#
#   old-orphan       mtime 20 days ago, no pod matches its suffix      -> deleted
#   fresh-orphan     mtime now, no pod matches its suffix              -> kept
#   <live-suffix>    mtime 20 days ago, suffix matches a live agent pod -> kept
#
# A cleanup run that mishandles ANY of these is the kind of regression that
# only shows up against a real kube API — exactly what the recent fix-up
# commits (pod-list parser, mtime safety net) were patching.

load lib.bash

setup_file() {
  helm_install --set cleanup.intervalSeconds=5
  wait_for_pod "app=$(release_name)-cleanup" Running 240
  # Agent pods just need to *exist* (so they appear in the kube API pod list);
  # they may still be Pending or in CrashLoopBackOff and that's fine.
  wait_for_pod_exists "app=$(release_name)-default" 120

  # Capture the cleanup-loop iteration count BEFORE staging so we can wait
  # for an iteration that definitely ran after our writes hit disk.
  CLEANUP_BASELINE="$(cleanup_run_count)"
  export CLEANUP_BASELINE
  stage_dirs
  wait_for_cleanup_runs_since "${CLEANUP_BASELINE}" 1 120
}

teardown_file() {
  helm_uninstall
}

# Build a YYYYMMDDhhmm stamp ${1} days in the past, portable across GNU/BSD date.
stamp_days_ago() {
  local days="$1"
  local epoch=$(( $(date +%s) - days*86400 ))
  case "$(uname -s)" in
    Darwin) date -r "${epoch}" +%Y%m%d%H%M ;;
    *) date -d "@${epoch}" +%Y%m%d%H%M ;;
  esac
}

stage_dirs() {
  local ns
  ns="$(namespace)"

  # Grab the last-5-char suffix of a live agent pod. This is what the cleanup
  # script extracts from the dir name and matches against active pod names.
  local agent_pod
  agent_pod="$(kubectl -n "${ns}" get pod -l "app=$(release_name)-default" \
    -o jsonpath='{.items[0].metadata.name}')"
  [ -n "${agent_pod}" ] || { echo "no agent pod scheduled yet" >&2; return 1; }

  LIVE_SUFFIX="${agent_pod: -5}"
  export LIVE_SUFFIX

  # Clear any leftover state from a previous run (different release on the
  # same node would share /var/buildkite/builds via hostPath).
  cleanup_exec sh -c 'rm -rf /var/buildkite/builds/* 2>/dev/null || true'

  local old_stamp
  old_stamp="$(stamp_days_ago 20)"

  # Three siblings under /var/buildkite/builds. Names mimic the real format
  # (<node>-<queue>-<suffix>) so the cleanup script's regex extracts the
  # suffix the same way it would in prod.
  cleanup_exec sh -c "
    set -e
    cd /var/buildkite/builds
    mkdir -p node1-default-aaaaa node1-default-bbbbb node1-default-${LIVE_SUFFIX}
    touch -t '${old_stamp}' node1-default-aaaaa
    touch -t '${old_stamp}' node1-default-${LIVE_SUFFIX}
    # fresh-orphan keeps default mtime (now)
  "
}

@test "old orphaned build dir is deleted" {
  run cleanup_exec test -d /var/buildkite/builds/node1-default-aaaaa
  assert_failure
}

@test "fresh orphaned build dir is kept (age safety net)" {
  run cleanup_exec test -d /var/buildkite/builds/node1-default-bbbbb
  assert_success
}

@test "old build dir with matching live pod suffix is kept" {
  run cleanup_exec test -d "/var/buildkite/builds/node1-default-${LIVE_SUFFIX}"
  assert_success
}

@test "cleanup pod successfully fetched pod list from kube API" {
  # Presence of the WARNING line means the kube API call returned something
  # that didn't look like a PodList — which is the regression that
  # fb15a95 / a3f0626 patched. If this triggers, the build-dir branch falls
  # through to mtime-only deletion and any old dir would be wiped regardless
  # of whether its pod is still alive.
  run cleanup_logs
  assert_success
  refute_output --partial "WARNING: failed to fetch pod list"
}

@test "cleanup script logged at least one successful build-dir scan" {
  run cleanup_logs
  assert_success
  assert_output --partial "Checking for orphaned build dirs"
}
