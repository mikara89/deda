ARG BASE_IMAGE=deda-azure-runner:ci
FROM ${BASE_IMAGE}
USER root
COPY azure-config.sh /azp/agent/config.sh
COPY azure-run.sh /azp/agent/run.sh
RUN chmod 0555 /azp/agent/config.sh /azp/agent/run.sh
