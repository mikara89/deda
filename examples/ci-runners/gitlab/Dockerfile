FROM gitlab/gitlab-runner:alpine-v17.11.0

USER root
RUN addgroup -S ci-job && adduser -S -D -h /home/ci-job -G ci-job ci-job \
 && mkdir -p /etc/deda-gitlab-runner \
 && chmod 700 /etc/deda-gitlab-runner
COPY --chmod=755 entrypoint.sh /usr/local/bin/deda-gitlab-entrypoint
ENTRYPOINT ["/usr/local/bin/deda-gitlab-entrypoint"]
