#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/common.sh"
begin_scenario 03 'GitLab CI capacity, tag matching, and scale from zero'
set_state '{"gitlab":{"jobs":[]}}'; wait_replicas gitlab-runner 0
set_state '{"gitlab":{"jobs":[{"status":"pending","tag_list":["linux","deda"]},{"status":"pending","tag_list":["linux","deda"]},{"status":"pending","tag_list":["Linux","deda"]},{"status":"pending","tag_list":[]}]}}'; wait_replicas gitlab-runner 2
set_state '{"gitlab":{"jobs":[{"status":"running","tag_list":["linux","deda"]},{"status":"running","tag_list":["linux","deda"]}]}}'; wait_replicas gitlab-runner 2
set_state '{"gitlab":{"jobs":[]}}'; wait_replicas gitlab-runner 0
update_ephemeral_service --label-add com.deda.autoscale.trigger.runUntagged=true "$(service gitlab-runner)" >/dev/null
set_state '{"gitlab":{"jobs":[{"status":"pending","tag_list":[]}]}}'; wait_replicas gitlab-runner 1
set_state '{"gitlab":{"jobs":[]}}'; wait_replicas gitlab-runner 0
update_ephemeral_service --label-add com.deda.autoscale.trigger.runUntagged=false "$(service gitlab-runner)" >/dev/null
finish_scenario PASS 'case-sensitive tag subset matching plus runUntagged=false and true were enforced across scale-from-zero cycles'
