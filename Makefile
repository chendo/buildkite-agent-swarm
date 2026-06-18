UPSTREAM_GIT_URL = git@github.com:chendo/buildkite-agent-swarm.git
CHARTS_URL = https://chendo.github.io/buildkite-agent-swarm
CT_IMAGE = quay.io/helmpack/chart-testing:v3.7.0
COMMIT = $(shell git rev-parse --short HEAD)

.PHONY: lint shellcheck clean build release integration-test unit-test

# Lints the chart changes against origin/master
lint:
	git fetch origin master && \
		docker run \
			--volume "${PWD}:/src" \
			--workdir /src \
			--rm \
			"${CT_IMAGE}" \
			ct lint --config test/ct.yaml

# Runs shellcheck over any shell files
shellcheck:
	docker run \
		--volume "${PWD}:/src" \
		--workdir /src \
		--rm \
		koalaman/shellcheck-alpine \
		sh -c "shellcheck -x **/*.sh"

clean:
	rm -rf dist-repo

dist-repo:
	git clone --quiet --single-branch -b gh-pages "${UPSTREAM_GIT_URL}" dist-repo

# Build all Helm packages into dist-repo and regenerate the chart index
build: dist-repo
	cd package && \
		docker-compose build && \
		docker-compose run --rm package package.sh "${CHARTS_URL}" dist-repo && \
		cd ../dist-repo && \
		echo "--- Diff" && \
		git diff --stat

# Commit and push the chart index
release:
	cd dist-repo && \
		git add *.tgz index.yaml && \
		git commit --message "Update to buildkite/charts@${COMMIT}" && \
		git push origin gh-pages

# Fast unit tests of the cleanup script's parser/decision logic. Runs the
# actual shell snippet that ships in the chart (extracted by
# test/integration/unit/extract-build-cleanup.sh) with the kube API call
# stubbed out. No cluster, no docker registry required — just `bash`, `git`,
# and outbound HTTPS to github.com so bats-core can be cloned on first run.
unit-test:
	@cd test/integration && \
		mkdir -p .bin/bats && \
		[ -d .bin/bats/bats-core ] || git clone --quiet --depth 1 --branch v1.11.0 \
			https://github.com/bats-core/bats-core.git .bin/bats/bats-core && \
		[ -d .bin/bats/bats-support ] || git clone --quiet --depth 1 --branch v0.3.0 \
			https://github.com/bats-core/bats-support.git .bin/bats/bats-support && \
		[ -d .bin/bats/bats-assert ] || git clone --quiet --depth 1 --branch v2.1.0 \
			https://github.com/bats-core/bats-assert.git .bin/bats/bats-assert && \
		.bin/bats/bats-core/bin/bats unit/

# End-to-end integration tests: boot a k3d cluster, install the chart, and
# assert cleanup behaviour. Requires `docker` on PATH and unrestricted access
# to github.com, dl.k8s.io, get.helm.sh and the docker registry. See
# test/integration/README.md for details.
#
#   make integration-test                # run all scenarios
#   make integration-test KEEP=1         # leave the cluster running on exit
#   make integration-test FILTER='02-*'  # run a subset
integration-test:
	@cd test/integration && ./run.sh \
		$(if $(KEEP),--keep,) \
		$(if $(FILTER),--filter '$(FILTER)',) \
		$(if $(MODE),--mode $(MODE),)
