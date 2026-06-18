#!/usr/bin/env bats
#
# Unit tests for the build-directory cleanup logic in
# stable/buildkite-agent-swarm/templates/cleanup-daemonset.yaml.
#
# These run the ACTUAL shell snippet that the chart ships — extracted by
# unit/extract-build-cleanup.sh and patched only enough to (a) stub the kube
# API wget call and (b) read the service-account token from a test-controlled
# directory instead of /var/run/secrets/.... Everything else (the PodList
# guard, the JSON parser, the suffix matcher, the mtime safety net, the dry-
# run branch) runs verbatim.
#
# Coverage targets the regressions in the recent cleanup fix commits:
#   - fb15a95 / a3f0626  pod-list parser broken & mtime-only branch masked it
#   - 701c00e            (RBAC/root concerns are out of scope for a unit test)
#   - 1149a31            dry-run claims didn't match real prune behaviour

setup_file() {
  HERE="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"
  export HERE
  # bats-support/assert live under .bin/bats — same layout the integration
  # tests use, so no extra plumbing.
  BATS_LIB="${HERE}/../.bin/bats"
  load "${BATS_LIB}/bats-support/load.bash"
  load "${BATS_LIB}/bats-assert/load.bash"

  # Render the cleanup script once per file run.
  RENDERED="${BATS_FILE_TMPDIR}/build-cleanup.sh"
  "${HERE}/extract-build-cleanup.sh" > "${RENDERED}"
  export RENDERED
}

# Re-load assert/support for every test since bats spawns a fresh shell.
setup() {
  BATS_LIB="${HERE}/../.bin/bats"
  load "${BATS_LIB}/bats-support/load.bash"
  load "${BATS_LIB}/bats-assert/load.bash"

  TMP="${BATS_TEST_TMPDIR}"
  SA_DIR="${TMP}/sa"
  BUILDS_PATH="${TMP}/builds"
  mkdir -p "${SA_DIR}" "${BUILDS_PATH}"
  printf 'fake-token' > "${SA_DIR}/token"
  printf 'default' > "${SA_DIR}/namespace"
  printf 'fake-cacert' > "${SA_DIR}/ca.crt"

  export SA_DIR BUILDS_PATH
  export NODE_NAME="node1"
  export BUILDS_MAX_AGE_DAYS="14"
  export DRY_RUN="false"
}

# Build a JSON PodList from a list of pod names — each arg is one name.
podlist() {
  local items=""
  local first=1
  for name in "$@"; do
    if [ $first -eq 1 ]; then first=0; else items+=','; fi
    items+="{\"metadata\":{\"name\":\"${name}\",\"namespace\":\"default\"}}"
  done
  printf '{"kind":"PodList","apiVersion":"v1","items":[%s]}' "${items}"
}

stage_old_dir() {
  mkdir -p "${BUILDS_PATH}/$1"
  touch -d "20 days ago" "${BUILDS_PATH}/$1"
}

stage_fresh_dir() {
  mkdir -p "${BUILDS_PATH}/$1"
  # Default mtime is now — leave it.
}

# ---------------------------------------------------------------------------
# Happy path: each of the three scenarios from the integration plan.
# ---------------------------------------------------------------------------

@test "deletes an old orphaned build dir" {
  stage_old_dir "node1-default-aaaaa"
  export MOCK_API_RESPONSE="$(podlist "unrelated-pod-99999")"

  run bash "${RENDERED}"
  assert_success
  assert_output --partial "Deleting orphaned dir"
  [ ! -d "${BUILDS_PATH}/node1-default-aaaaa" ]
}

@test "keeps a fresh orphaned build dir (mtime safety net)" {
  stage_fresh_dir "node1-default-bbbbb"
  export MOCK_API_RESPONSE="$(podlist "unrelated-pod-99999")"

  run bash "${RENDERED}"
  assert_success
  refute_output --partial "Deleting orphaned dir"
  [ -d "${BUILDS_PATH}/node1-default-bbbbb" ]
}

@test "keeps an old build dir whose suffix matches a live pod" {
  stage_old_dir "node1-default-abcde"
  export MOCK_API_RESPONSE="$(podlist "bk-default-7d8b6f5d9-abcde")"

  run bash "${RENDERED}"
  assert_success
  refute_output --partial "Deleting orphaned dir"
  [ -d "${BUILDS_PATH}/node1-default-abcde" ]
}

# ---------------------------------------------------------------------------
# Mixed: all three together. This is the closest mirror of what the
# integration test 02 does against a real cluster.
# ---------------------------------------------------------------------------

@test "mixed: deletes only the old orphan, keeps fresh + matching" {
  stage_old_dir "node1-default-aaaaa"     # delete
  stage_fresh_dir "node1-default-bbbbb"   # keep (fresh)
  stage_old_dir "node1-default-abcde"     # keep (matching pod)
  export MOCK_API_RESPONSE="$(podlist "bk-default-7d8b6f5d9-abcde")"

  run bash "${RENDERED}"
  assert_success
  [ ! -d "${BUILDS_PATH}/node1-default-aaaaa" ]
  [ -d "${BUILDS_PATH}/node1-default-bbbbb" ]
  [ -d "${BUILDS_PATH}/node1-default-abcde" ]
}

# ---------------------------------------------------------------------------
# The PodList guard — regression coverage for fb15a95 / a3f0626.
# Without the guard, a transient API failure left active_pods empty and the
# script would mtime-delete every dir older than maxAgeDays. We assert that
# (a) the WARNING fires and (b) NO old dirs are deleted, even though they'd
# be eligible if the guard were absent.
# ---------------------------------------------------------------------------

@test "logs WARNING and deletes nothing when API returns a non-PodList body" {
  stage_old_dir "node1-default-aaaaa"
  stage_old_dir "node1-default-ccccc"
  export MOCK_API_RESPONSE='{"kind":"Status","status":"Failure","code":403}'

  run bash "${RENDERED}"
  assert_success
  assert_output --partial "WARNING: failed to fetch pod list"
  [ -d "${BUILDS_PATH}/node1-default-aaaaa" ]
  [ -d "${BUILDS_PATH}/node1-default-ccccc" ]
}

@test "logs WARNING when API returns empty body" {
  stage_old_dir "node1-default-aaaaa"
  export MOCK_API_RESPONSE=""

  run bash "${RENDERED}"
  assert_success
  assert_output --partial "WARNING: failed to fetch pod list"
  [ -d "${BUILDS_PATH}/node1-default-aaaaa" ]
}

@test "logs WARNING when API returns garbage" {
  stage_old_dir "node1-default-aaaaa"
  export MOCK_API_RESPONSE='<html><body>502 Bad Gateway</body></html>'

  run bash "${RENDERED}"
  assert_success
  assert_output --partial "WARNING: failed to fetch pod list"
  [ -d "${BUILDS_PATH}/node1-default-aaaaa" ]
}

# ---------------------------------------------------------------------------
# JSON parser — k8s emits everything on one line in compact JSON, so a greedy
# sed regex would have captured at most one "name" field per line. grep -oE
# must find every pod's "metadata":{"name":"X" tuple. Test with 3 pods on one
# line.
# ---------------------------------------------------------------------------

@test "parser finds every pod when multiple pods share one line of JSON" {
  stage_old_dir "node1-default-pod01"
  stage_old_dir "node1-default-pod02"
  stage_old_dir "node1-default-pod03"
  export MOCK_API_RESPONSE="$(podlist \
    "agent-aaaaaaaa-pod01" \
    "agent-bbbbbbbb-pod02" \
    "agent-cccccccc-pod03")"

  run bash "${RENDERED}"
  assert_success
  # All three dirs match an active pod's suffix → none should be deleted.
  refute_output --partial "Deleting orphaned dir"
  [ -d "${BUILDS_PATH}/node1-default-pod01" ]
  [ -d "${BUILDS_PATH}/node1-default-pod02" ]
  [ -d "${BUILDS_PATH}/node1-default-pod03" ]
}

@test "parser is not fooled by container/volume \"name\" fields in the JSON" {
  # The PodList serialises container, volume, and ownerReference "name"
  # fields too. The regex `"metadata":[{]"name":"X"` should match only the
  # pod's own metadata.name, not these. Confirm by including a pod whose
  # containers happen to be named like another pod's suffix.
  stage_old_dir "node1-default-zzzzz"   # would be DELETED — no live pod
  local body
  body='{"kind":"PodList","apiVersion":"v1","items":['
  body+='{"metadata":{"name":"bk-default-aaaaaaa-other"},'
  body+='"spec":{"containers":[{"name":"zzzzz"}],'
  body+='"volumes":[{"name":"zzzzz-vol"}]}}'
  body+=']}'
  export MOCK_API_RESPONSE="${body}"

  run bash "${RENDERED}"
  assert_success
  # The "zzzzz" container/volume names must NOT match — the dir gets deleted.
  assert_output --partial "Deleting orphaned dir"
  [ ! -d "${BUILDS_PATH}/node1-default-zzzzz" ]
}

# ---------------------------------------------------------------------------
# Dry-run mode — must NOT delete; must log the would-delete line. Regression
# coverage for 1149a31 (and the broader "dry-run should match reality" rule).
# ---------------------------------------------------------------------------

@test "dry-run logs would-delete but keeps the dir on disk" {
  stage_old_dir "node1-default-aaaaa"
  export MOCK_API_RESPONSE="$(podlist "unrelated-99999")"
  export DRY_RUN="true"

  run bash "${RENDERED}"
  assert_success
  assert_output --partial "[dry-run] Would delete orphaned dir"
  refute_output --partial "Deleting orphaned dir:"
  [ -d "${BUILDS_PATH}/node1-default-aaaaa" ]
}

# ---------------------------------------------------------------------------
# Missing SA token — short-circuits before the API call. No deletion, no
# WARNING (just an informational log).
# ---------------------------------------------------------------------------

@test "skips cleanup entirely when SA token file is empty" {
  stage_old_dir "node1-default-aaaaa"
  : > "${SA_DIR}/token"  # empty file
  export MOCK_API_RESPONSE="$(podlist "x")"

  run bash "${RENDERED}"
  assert_success
  assert_output --partial "No service account token found"
  refute_output --partial "Deleting orphaned dir"
  refute_output --partial "WARNING"
  [ -d "${BUILDS_PATH}/node1-default-aaaaa" ]
}
