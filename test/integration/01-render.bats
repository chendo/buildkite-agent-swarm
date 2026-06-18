#!/usr/bin/env bats
#
# Scenario 1 — chart renders and installs without errors, RBAC objects exist,
# and the cleanup.builds + rbac=false guard fails fast at render time.

load lib.bash

setup_file() {
  helm_install
  wait_for_pod "app=$(release_name)-cleanup" Running 180
}

teardown_file() {
  helm_uninstall
}

@test "cleanup DaemonSet pod is Running" {
  local ns
  ns="$(namespace)"
  run kubectl -n "${ns}" get pod -l "app=$(release_name)-cleanup" \
    -o jsonpath='{.items[*].status.phase}'
  assert_success
  assert_output --partial "Running"
}

@test "ServiceAccount exists" {
  local ns
  ns="$(namespace)"
  run kubectl -n "${ns}" get serviceaccount "$(release_name)" -o name
  assert_success
}

@test "ClusterRole exists with pods get/list/watch" {
  run kubectl get clusterrole "$(release_name)" -o jsonpath='{.rules[0].verbs}'
  assert_success
  assert_output --partial "list"
  assert_output --partial "get"
  assert_output --partial "watch"
}

@test "ClusterRoleBinding references the cleanup ServiceAccount" {
  run kubectl get clusterrolebinding "$(release_name)" \
    -o jsonpath='{.subjects[0].kind}/{.subjects[0].name}'
  assert_success
  assert_output "ServiceAccount/$(release_name)"
}

@test "helm template fails with cleanup.builds.enabled and rbac.create=false" {
  # This is the guard at cleanup-daemonset.yaml:3 — without RBAC the kube API
  # call returns 403 and build-dir cleanup silently fell through to mtime-only
  # deletion. The guard must fire BEFORE install can happen.
  run helm template guard "${BK_IT_CHART}" \
    --values "${BK_IT_HERE}/values-test.yaml" \
    --set rbac.create=false \
    --set cleanup.builds.enabled=true
  assert_failure
  assert_output --partial "cleanup.builds.enabled requires rbac.create=true"
}
