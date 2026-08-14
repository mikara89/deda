FROM ubuntu:24.04

ARG AGENT_VERSION=4.264.0
ARG TARGETARCH=amd64
ARG AGENT_SHA256_AMD64
ARG AGENT_SHA256_ARM64
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ca-certificates curl jq tini libicu74 libssl3 \
 && rm -rf /var/lib/apt/lists/* \
 && case "$TARGETARCH" in amd64) agent_arch=x64; agent_sha256="$AGENT_SHA256_AMD64" ;; arm64) agent_arch=arm64; agent_sha256="$AGENT_SHA256_ARM64" ;; *) exit 1 ;; esac \
 && test -n "$agent_sha256" \
 && useradd --create-home --uid 10001 azp \
 && mkdir -p /azp/agent \
 && curl --fail --location --retry 3 --proto '=https' --tlsv1.2 -o /tmp/agent.tar.gz "https://download.agent.dev.azure.com/agent/${AGENT_VERSION}/vsts-agent-linux-${agent_arch}-${AGENT_VERSION}.tar.gz" \
 && echo "${agent_sha256}  /tmp/agent.tar.gz" | sha256sum -c - \
 && tar -xzf /tmp/agent.tar.gz -C /azp/agent \
 && rm /tmp/agent.tar.gz \
 && chown -R azp:azp /azp
COPY --chown=azp:azp --chmod=755 start.sh /usr/local/bin/azp-start
USER azp
WORKDIR /azp/agent
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/azp-start"]
