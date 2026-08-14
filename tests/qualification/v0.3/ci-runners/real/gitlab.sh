#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
confirm_real "${1:-}"
for key in GITLAB_QUAL_URL GITLAB_QUAL_PROJECT GITLAB_QUAL_REF GITLAB_QUAL_TAGS GITLAB_QUAL_QUEUE_TOKEN_FILE GITLAB_QUAL_RUNNER_TOKEN_FILE; do require_env "$key"; done
require_secret_file GITLAB_QUAL_QUEUE_TOKEN_FILE; require_secret_file GITLAB_QUAL_RUNNER_TOKEN_FILE
begin_real gitlab
count=${GITLAB_QUAL_JOB_COUNT:-3}; timeout=${GITLAB_QUAL_TIMEOUT_SECONDS:-1800}; [[ "$count" =~ ^[1-9][0-9]*$ ]] || die 'GITLAB_QUAL_JOB_COUNT must be a positive integer'
token=$(secret "$GITLAB_QUAL_QUEUE_TOKEN_FILE"); project=$(printf '%s' "$GITLAB_QUAL_PROJECT" | sed 's|/|%2F|g')
base="${GITLAB_QUAL_URL%/}/api/v4/projects/$project"; pipeline_ids=()
for _ in $(seq 1 "$count"); do response=$(curl --fail --silent --show-error -H "PRIVATE-TOKEN: $token" -X POST --data-urlencode "ref=$GITLAB_QUAL_REF" "$base/pipeline"); printf '%s\n' "$response" | jq '{id,status,web_url,created_at,updated_at}' >> "$(real_result_dir gitlab)/pipelines.ndjson"; pipeline_ids+=("$(printf '%s' "$response" | jq -r .id)"); done
end=$((SECONDS + timeout))
for id in "${pipeline_ids[@]}"; do
  file="$(real_result_dir gitlab)/pipeline-$id.json"
  while :; do
    pipeline=$(curl --fail --silent --show-error -H "PRIVATE-TOKEN: $token" "$base/pipelines/$id")
    jobs=$(curl --fail --silent --show-error -H "PRIVATE-TOKEN: $token" "$base/pipelines/$id/jobs?per_page=100")
    jq -n --argjson pipeline "$pipeline" --argjson jobs "$jobs" '{pipeline:{id:$pipeline.id,status:$pipeline.status,created_at:$pipeline.created_at,updated_at:$pipeline.updated_at},jobs:[$jobs[]?|{id,status,started_at,finished_at,runner} ]}' > "$file"
    [[ $(jq -r .pipeline.status "$file") =~ ^(success|failed|canceled|skipped)$ ]] && break
    (( SECONDS < end )) || { write_real gitlab FAIL "Timed out waiting for pipeline $id."; exit 1; }; sleep 5
  done
  jq -e '.pipeline.status == "success" and ([.jobs[] | select(.status != "success")] | length == 0)' "$file" >/dev/null || { write_real gitlab FAIL "Pipeline $id did not succeed."; exit 1; }
done
unset token
write_real gitlab PASS 'All queued pipelines and jobs completed successfully; retain runner-manager and SIGQUIT drain evidence with this result.'
printf 'GitLab qualification passed provider-side pipeline result checks.\n'
