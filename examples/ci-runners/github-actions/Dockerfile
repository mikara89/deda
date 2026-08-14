FROM ubuntu:24.04

ARG RUNNER_VERSION=2.329.0
ARG TARGETARCH=amd64
ARG RUNNER_SHA256_AMD64
ARG RUNNER_SHA256_ARM64

RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ca-certificates curl jq tini libicu74 libssl3 \
 && rm -rf /var/lib/apt/lists/* \
 && case "$TARGETARCH" in amd64) runner_arch=x64; runner_sha256="$RUNNER_SHA256_AMD64" ;; arm64) runner_arch=arm64; runner_sha256="$RUNNER_SHA256_ARM64" ;; *) exit 1 ;; esac \
 && test -n "$runner_sha256" \
 && mkdir -p /opt/actions-runner \
 && curl --fail --location --retry 3 --proto '=https' --tlsv1.2 -o /tmp/runner.tar.gz "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-${runner_arch}-${RUNNER_VERSION}.tar.gz" \
 && echo "${runner_sha256}  /tmp/runner.tar.gz" | sha256sum -c - \
 && tar -xzf /tmp/runner.tar.gz -C /opt/actions-runner \
 && rm /tmp/runner.tar.gz \
 && useradd --create-home --uid 10001 runner \
 && chown -R runner:runner /opt/actions-runner

COPY --chown=runner:runner --chmod=755 entrypoint.sh /usr/local/bin/ci-runner-entrypoint
USER runner
WORKDIR /opt/actions-runner
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/ci-runner-entrypoint"]
