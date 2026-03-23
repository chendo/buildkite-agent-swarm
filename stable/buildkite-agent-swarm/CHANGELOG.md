# Changelog

## 0.3.0

### Added

- **Cleanup DaemonSet**: Periodic node-level cleanup of stale build directories and Docker resources (containers, images, build cache, volumes). Runs as a DaemonSet with configurable interval, age thresholds, and per-resource toggles. Enabled in dry-run mode by default.
- **Dry run mode** (`cleanup.dryRun`): Logs what would be deleted without performing any deletions. Useful for validating cleanup configuration before enabling destructive operations.
- **Disk usage logging**: Each cleanup cycle logs filesystem usage (`df -h`) and Docker disk usage (`docker system df`) for observability.
- **Per-queue pod priorities**: Each agent queue can now specify a Kubernetes `priority` value for scheduling. Higher-priority queues (e.g. build, deploy) are scheduled preferentially over lower-priority ones (e.g. test) during resource contention.

### Fixed

- **priorities.yaml**: The agent PriorityClass incorrectly used `priorities.dind` value instead of a separate agent default. Now uses `priorities.defaultAgent`.
- **priorities.yaml**: Replaced single shared `agent-default` PriorityClass with per-queue PriorityClasses (`agent-<queueName>`).

## 0.2.1

- Make /var/buildkite/builds accessible to DIND so volume mounts during tests can work as expected

## 0.2.0

- Use a pod-local buildtime config so we don't have collisions when booting agents on the same node
