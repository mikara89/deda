FROM alpine:3.22
COPY runner.sh /runner.sh
RUN chmod 0555 /runner.sh
USER 65532:65532
ENTRYPOINT ["/runner.sh"]
