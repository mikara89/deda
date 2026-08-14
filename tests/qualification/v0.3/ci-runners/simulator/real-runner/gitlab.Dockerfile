ARG BASE_IMAGE=deda-gitlab-runner:ci
FROM ${BASE_IMAGE}
USER root
COPY gitlab-runner /usr/local/bin/gitlab-runner
RUN chmod 0555 /usr/local/bin/gitlab-runner
