#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
confirm_real "${1:-}"
for key in AZURE_QUAL_ORGANIZATION_URL AZURE_QUAL_PROJECT AZURE_QUAL_PIPELINE_ID AZURE_QUAL_POOL AZURE_QUAL_QUEUE_TOKEN_FILE AZURE_QUAL_AGENT_TOKEN_FILE; do require_env "$key"; done
require_secret_file AZURE_QUAL_QUEUE_TOKEN_FILE; require_secret_file AZURE_QUAL_AGENT_TOKEN_FILE
begin_real azure-pipelines
count=${AZURE_QUAL_JOB_COUNT:-3}; timeout=${AZURE_QUAL_TIMEOUT_SECONDS:-1800}; [[ "$count" =~ ^[1-9][0-9]*$ ]] || die 'AZURE_QUAL_JOB_COUNT must be a positive integer'
token=$(secret "$AZURE_QUAL_QUEUE_TOKEN_FILE"); base="${AZURE_QUAL_ORGANIZATION_URL%/}/$AZURE_QUAL_PROJECT/_apis/pipelines/$AZURE_QUAL_PIPELINE_ID/runs"; queue_url="$base?api-version=7.1"
run_ids=()
for _ in $(seq 1 "$count"); do response=$(curl --fail --silent --show-error -u ":$token" -H 'content-type: application/json' -X POST "$queue_url" -d '{}'); printf '%s\n' "$response" | jq '{id,state,result,createdDate,finishedDate}' >> "$(real_result_dir azure-pipelines)/runs.ndjson"; run_ids+=("$(printf '%s' "$response" | jq -r .id)"); done
end=$((SECONDS + timeout))
for id in "${run_ids[@]}"; do
  file="$(real_result_dir azure-pipelines)/run-$id.json"
  while :; do curl --fail --silent --show-error -u ":$token" "$base/$id?api-version=7.1" | jq '{id,state,result,createdDate,finishedDate}' > "$file"; [[ $(jq -r .state "$file") == completed ]] && break; (( SECONDS < end )) || { write_real azure-pipelines FAIL "Timed out waiting for run $id."; exit 1; }; sleep 5; done
  [[ $(jq -r .result "$file") == succeeded ]] || { write_real azure-pipelines FAIL "Run $id did not succeed."; exit 1; }
done
unset token
write_real azure-pipelines PASS 'All queued pipeline runs completed successfully; retain agent and Swarm scale evidence with this result.'
printf 'Azure qualification passed provider-side pipeline result checks.\n'
