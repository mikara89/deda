#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/common.sh"
begin_scenario 09 'Scale to zero and wake from zero for all providers'
for provider in github azure gitlab; do
  case "$provider" in
    github) set_state '{"github":{"runs":[{"id":1,"status":"queued"}],"jobs":[{"status":"queued","labels":["self-hosted","linux","deda"]},{"status":"queued","labels":["self-hosted","linux","deda"]}]}}'; service_name=github-runner ;;
    azure) set_state '{"azure":{"jobs":[{"demands":["deda","Agent.OS -equals Linux"],"assignTime":null,"finishTime":null},{"demands":["deda","Agent.OS -equals Linux"],"assignTime":null,"finishTime":null}]}}'; service_name=azure-runner ;;
    gitlab) set_state '{"gitlab":{"jobs":[{"status":"pending","tag_list":["linux","deda"]},{"status":"pending","tag_list":["linux","deda"]}]}}'; service_name=gitlab-runner ;;
  esac
  wait_replicas "$service_name" 2
  case "$provider" in github) set_state '{"github":{"runs":[],"jobs":[]}}' ;; azure) set_state '{"azure":{"jobs":[]}}' ;; gitlab) set_state '{"gitlab":{"jobs":[]}}' ;; esac
  wait_replicas "$service_name" 0
done
finish_scenario PASS 'all providers woke 0→2 and returned to zero without manual service intervention'
