#!/bin/sh
set -eu

if [ "$1" = remove ]; then
  if [ -e /tmp/deda-azure-agent.busy ]; then
    printf '%s\n' 'agent is busy or cleanup API is unavailable; retrying' >&2
    exit 1
  fi
  printf '%s\n' cleanup >&2
  exit 0
fi

printf '%s\n' register >&2
