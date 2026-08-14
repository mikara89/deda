#!/bin/sh
set -eu

case "$1" in
  remove)
    printf '%s\n' cleanup >> "${FAKE_LOG:-/tmp/deda-github-runner.log}"
    exit 0
    ;;
  *)
    printf '%s\n' register >> "${FAKE_LOG:-/tmp/deda-github-runner.log}"
    exit 0
    ;;
esac
