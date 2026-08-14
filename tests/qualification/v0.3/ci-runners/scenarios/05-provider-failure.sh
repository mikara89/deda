#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/common.sh"
begin_scenario 05 'Provider failures fail safe at current capacity'
set_state '{"github":{"runs":[{"id":1,"status":"in_progress"}],"jobs":[{"status":"in_progress","labels":["self-hosted","linux","deda"]},{"status":"in_progress","labels":["self-hosted","linux","deda"]},{"status":"in_progress","labels":["self-hosted","linux","deda"]}]},"azure":{"jobs":[{"demands":["deda","Agent.OS -equals Linux"],"assignTime":"2026-01-01T00:00:00Z","finishTime":null},{"demands":["deda","Agent.OS -equals Linux"],"assignTime":"2026-01-01T00:00:00Z","finishTime":null},{"demands":["deda","Agent.OS -equals Linux"],"assignTime":"2026-01-01T00:00:00Z","finishTime":null}]},"gitlab":{"jobs":[{"status":"running","tag_list":["linux","deda"]},{"status":"running","tag_list":["linux","deda"]},{"status":"running","tag_list":["linux","deda"]}]}}'
wait_replicas github-runner 3; wait_replicas azure-runner 3; wait_replicas gitlab-runner 3
for code in 401 403 429 500; do before=$(request_count); set_state "{\"mode\":{\"status\":$code}}"; wait_for_all_provider_observations_after "$before" "all provider observations for HTTP $code"; [[ $(replicas github-runner) == 3 && $(replicas azure-runner) == 3 && $(replicas gitlab-runner) == 3 ]] || fail_scenario "failsafe hold did not preserve capacity for HTTP $code"; done
before=$(request_count); set_state '{"mode":{"status":200,"body":"not-a-provider-document"}}'; wait_for_all_provider_observations_after "$before" 'all provider observations for semantically malformed records'
[[ $(replicas github-runner) == 3 && $(replicas azure-runner) == 3 && $(replicas gitlab-runner) == 3 ]] || fail_scenario 'failsafe hold did not preserve capacity for semantically malformed records'
before=$(request_count); set_state '{"mode":{"status":200,"body":null,"rawBody":"{"}}'; wait_for_all_provider_observations_after "$before" 'all provider observations for malformed JSON'
[[ $(replicas github-runner) == 3 && $(replicas azure-runner) == 3 && $(replicas gitlab-runner) == 3 ]] || fail_scenario 'failsafe hold did not preserve capacity for malformed JSON'
before=$(request_count); set_state '{"mode":{"status":200,"body":null,"rawBody":null,"delaySeconds":20}}'; wait_for_all_provider_observations_after "$before" 'all provider observations for timeout'
[[ $(replicas github-runner) == 3 && $(replicas azure-runner) == 3 && $(replicas gitlab-runner) == 3 ]] || fail_scenario 'failsafe hold did not preserve capacity for provider timeout'
set_state '{"mode":{"status":200,"body":null,"rawBody":null,"delaySeconds":0}}'
before=$(request_count); wait_for_all_provider_observations_after "$before" 'all provider recovery observations'
finish_scenario PASS '401, 403, 429, 500, malformed JSON, and timeout observations held non-zero desired capacity and recovered'
