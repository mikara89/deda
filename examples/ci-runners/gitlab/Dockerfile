FROM gitlab/gitlab-runner:alpine-v17.11.0

USER root
RUN addgroup -S deda && adduser -S -D -h /home/deda -G deda deda \
 && mkdir -p /home/deda/.gitlab-runner \
 && chown -R deda:deda /home/deda
COPY --chown=deda:deda --chmod=755 entrypoint.sh /usr/local/bin/deda-gitlab-entrypoint
USER deda
ENTRYPOINT ["/usr/local/bin/deda-gitlab-entrypoint"]
