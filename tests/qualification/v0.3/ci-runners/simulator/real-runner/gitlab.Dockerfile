ARG BASE_IMAGE=deda-gitlab-runner:ci
FROM alpine:3.22 AS fake-gitlab-runner
RUN apk add --no-cache gcc musl-dev
WORKDIR /src
COPY gitlab-runner.c .
RUN gcc -O2 -static -o /gitlab-runner gitlab-runner.c

FROM ${BASE_IMAGE}
USER root
COPY --from=fake-gitlab-runner /gitlab-runner /usr/local/bin/gitlab-runner
RUN chmod 0555 /usr/local/bin/gitlab-runner
