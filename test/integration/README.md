# buildkite-agent-swarm cleanup tests

Two tiers. Run the fast one always, the slow one before release.

## Fast unit tests (`make unit-test`, no cluster)

`unit/build-cleanup.bats` exercises the actual build-directory cleanup shell
snippet from `templates/cleanup-daemonset.yaml` — extracted by
`unit/extract-build-cleanup.sh`, with the kube API `wget` call stubbed and
the service-account secret paths redirected to a tmpdir. The 11 tests cover:

- the three happy-path scenarios (orphan deletion, mtime safety net, live
  pod suffix match)
- the PodList guard (regression coverage for `fb15a95` / `a3f0626`) against
  empty / garbage / non-PodList API responses
- the JSON parser against multi-pod single-line responses and against
  container/volume `name` fields that would confuse a greedy regex
- dry-run mode logging without deleting
- empty-SA-token short-circuit

The suite has been spot-validated by reverting the guard and the parser in
turn and confirming the matching tests fail — see the prove-it section
below.

Requires `bash`, `git`, and HTTPS access to `github.com` (for `bats-core`).
That's it.

## Slow integration tests (`make integration-test`, full k3s cluster)

End-to-end harness that boots a real k3s cluster, installs the chart, and
asserts cleanup behaviour against a live kube API and a real DIND docker
socket. Catches the regression class the unit tests can't — anything that
depends on RBAC propagation, container/image filesystem state, the actual
docker socket, or the cleanup pod's image+entrypoint behaving as built.

Two modes:

- `MODE=k3d` (default) — k3d-managed cluster. Best on dev machines and
  any environment where `/sys/fs/cgroup/init` is writable.
- `MODE=direct` — k3s as a single privileged docker container, bypassing
  k3d's cgroupv2 entrypoint. Use this when k3d's prep script fails with
  `mkdir: cannot create directory ‘/sys/fs/cgroup/init’: Permission denied`
  (typical of rootless-docker / nested-docker sandboxes).

Both modes pull the chart's runtime images on the host docker daemon and
mount them into the k3s node's auto-import directory so the cluster boots
even when its own DNS/network can't reach a registry.

### DIND DaemonSet on rootless / nested docker

In `MODE=direct`, the harness also builds and ships a patched DIND image
(`docker:28.0.1-dind-patched`) and points the chart at it via the
`BK_IT_DIND_IMAGE` env var that `03-cleanup-docker.bats` consumes. The
patch removes the `mkdir /sys/fs/cgroup/init` block from `/usr/local/bin/dind`
that fails when cgroups aren't writable. The docker daemon still boots and
serves every API call the cleanup pod makes — it just can't actually start
new containers. Scenario 03 sidesteps that by staging garbage with
`docker create` (containers in "created" state) and LABEL-only image
builds (no `RUN` step), both of which exercise the prune codepath without
needing a working runtime.

In `MODE=k3d`, the chart's stock DIND image is used. Both modes test the
same chart-side logic.

## Run it

```
make integration-test                # ~3-5 min on first run (image pulls)
make integration-test KEEP=1         # leave the cluster up for poking
make integration-test FILTER='02-*'  # run just one scenario
```

After a `KEEP=1` run:

```
export KUBECONFIG=test/integration/tmp/kubeconfig
kubectl get pods -A
test/integration/.bin/k3d cluster delete bk-cleanup-it   # tear down manually
```

## Requirements

- `docker` on PATH (DIND-capable; the chart's DIND DaemonSet needs privileged mode).
- Outbound HTTPS to:
  - `github.com` — bats-core / bats-support / bats-assert source
  - `dl.k8s.io` — kubectl binary
  - `get.helm.sh` — helm binary
  - `github.com/k3d-io/k3d` releases — k3d binary
  - Docker Hub (or any registry mirror configured locally) — chart images
    (`buildkite/agent`, `docker:28.0.1-dind`, `docker:28.0.1-cli`, `alpine:3.18`),
    plus `rancher/k3s` for the cluster itself.

The harness will not work in a sandbox that blocks any of those — most notably
the docker registry, since pulling agent + DIND + alpine images is required
for the scenarios to exercise anything real.

## What the suite asserts

- `01-render.bats` — chart installs, cleanup pod is Running, RBAC objects
  exist, and the `cleanup.builds + rbac=false` guard fails at render time.
- `02-cleanup-builds.bats` — stages three build dirs (old orphan / fresh
  orphan / old with live-pod-matching suffix), waits for a cleanup cycle,
  asserts the right one is deleted and that the kube API call succeeded.
- `03-cleanup-docker.bats` — stages a stopped container + dangling image in
  DIND, asserts wet-run deletes them and the tagged alpine remains, then
  re-runs with `dryRun=true` against fresh garbage and asserts nothing is
  deleted.

Each `.bats` file owns its own helm release + namespace, so they cannot
interfere with each other.

## Pinned versions

See `bootstrap.sh` — k3d, helm, kubectl, and the three bats repos are all
pinned, so reruns are reproducible. Bump the constants at the top of that
script to upgrade.

## Prove the tests actually catch regressions

Mutate the chart, run the unit suite, see the matching test(s) fail.
Examples that have been validated:

- **Remove the PodList guard** (the `if ! echo "$api_response" | grep -q '"kind":"PodList"'`
  line) → tests 5, 6, 7 fail with "WARNING substring not found" because the
  script now silently mtime-deletes old dirs on any API failure.
- **Replace the parser** (`grep -oE '"metadata":[{]"name":"[^"]+"' | sed ...`)
  with the old greedy `sed -n 's/.*"metadata":{"name":"\([^"]*\)".*/\1/p'`
  → test 8 fails because only one pod's name is captured per JSON line and
  the other two dirs get incorrectly deleted.
