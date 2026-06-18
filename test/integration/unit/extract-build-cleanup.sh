#!/usr/bin/env bash
#
# Render the build-directory cleanup block from the chart's
# cleanup-daemonset.yaml as a runnable shell script, suitable for unit tests
# that exercise the parser/decision logic without a real cluster.
#
# What this does, in order:
#
#   1. Extracts the lines between `# Build directory cleanup — remove dirs`
#      (unique anchor inside the helm template's script body) and the
#      matching `{{- end }}` that closes the .Values.cleanup.builds.enabled
#      conditional.
#   2. Strips helm template directives (lines that contain `{{` or `}}`) —
#      our extracted block has none in the middle, only the closing `end`.
#   3. Rewrites the hard-coded service-account secret paths to live under a
#      caller-supplied $SA_DIR so the test can pre-stage fake token/namespace
#      files.
#   4. Prepends a `wget` shell function that returns ${MOCK_API_RESPONSE},
#      replacing the real network call. This way the script's actual
#      `api_response="$(wget ...)"` invocation runs verbatim — same word
#      splitting, same quoting, same single-line invariant we're testing.
#   5. Wraps the block with a few env defaults so it can be invoked directly.
#
# Output goes to stdout. Errors go to stderr.
#
# Keeping this generator means we always test the SCRIPT THAT SHIPS — if the
# chart's cleanup logic changes, the unit tests automatically pick up the new
# behaviour next run.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART="${BK_IT_CHART:-${HERE}/../../../stable/buildkite-agent-swarm}"
TEMPLATE="${CHART}/templates/cleanup-daemonset.yaml"

[ -f "${TEMPLATE}" ] || { echo "cannot find ${TEMPLATE}" >&2; exit 1; }

# Anchored extraction: between the unique "Build directory cleanup" comment
# and the next `{{- end }}` (which closes builds.enabled). Inclusive of the
# `{{- end }}` so we can drop it cleanly in the next step.
block="$(
  awk '
    /^[[:space:]]*# Build directory cleanup/ { capture=1 }
    capture { print }
    capture && /^[[:space:]]*\{\{- end \}\}[[:space:]]*$/ { exit }
  ' "${TEMPLATE}"
)"

if [ -z "${block}" ]; then
  echo "failed to extract build-cleanup block from ${TEMPLATE}" >&2
  exit 1
fi

# Drop helm directive lines (just the closing `{{- end }}` in practice).
block="$(printf '%s\n' "${block}" | grep -vE '\{\{[-]?.*[-]?\}\}')"

# Rewire the hard-coded secret paths. The cleanup pod has them at fixed paths
# inside the container; here we point at a caller-controlled SA_DIR.
block="$(printf '%s\n' "${block}" \
  | sed 's|/var/run/secrets/kubernetes.io/serviceaccount|${SA_DIR}|g')"

cat <<'PROLOGUE'
#!/usr/bin/env bash
# AUTO-RENDERED from stable/buildkite-agent-swarm/templates/cleanup-daemonset.yaml
# by test/integration/unit/extract-build-cleanup.sh. Do not edit by hand.
#
# Runs ONE pass of the build-directory cleanup block with the kube API call
# stubbed out to whatever ${MOCK_API_RESPONSE} contains. All other env vars
# (NODE_NAME, BUILDS_PATH, BUILDS_MAX_AGE_DAYS, DRY_RUN) must be set by the
# caller.
set -u

# Stub wget. The real cleanup pod calls
#   wget -qO- --header=... --ca-certificate=... <url>
# so this needs to ignore all flags and just print the canned response.
wget() {
  printf '%s' "${MOCK_API_RESPONSE-}"
}

PROLOGUE

printf '%s\n' "${block}"
