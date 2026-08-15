ARG BASE_IMAGE=deda-github-runner:ci
FROM ${BASE_IMAGE}
USER root
COPY github-curl /usr/local/bin/curl
COPY github-jq /usr/local/bin/jq
COPY github-config.sh /opt/actions-runner/config.sh
COPY github-run.sh /opt/actions-runner/run.sh
RUN chmod 0555 /usr/local/bin/curl /usr/local/bin/jq /opt/actions-runner/config.sh /opt/actions-runner/run.sh
