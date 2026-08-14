#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"
load_run

out=$(result_dir "$RUN_ID"); mkdir -p "$out/deda-logs" "$out/docker-info" "$out/metrics"
"$SCRIPT_DIR/soak/finish-soak.sh" >/dev/null 2>&1 || true
start_utc=$(date -u -r "$(state_file "$RUN_ID")" +%Y-%m-%dT%H:%M:%SZ)
end_utc=$(utc_now)
resolved_image=$(awk -F '\t' '$1 == "resolved" { print $2 }' "$out/image-digests.txt" 2>/dev/null || true)

printf 'RUN_ID=%s\nstart_utc=%s\nend_utc=%s\ncandidate=%s\nresolved_image=%s\nlocation=%s\nserver_type=%s\nprivate_node_ips=%s,%s,%s\ngit_commit=%s\n' \
  "$RUN_ID" "$start_utc" "$end_utc" "$DEDA_IMAGE" "$resolved_image" "$DEDA_QUAL_LOCATION" "$DEDA_QUAL_SERVER_TYPE" \
  "$MANAGER_1_PRIVATE" "$MANAGER_2_PRIVATE" "$MANAGER_3_PRIVATE" "$(git -C "$REPO_ROOT" rev-parse HEAD)" > "$out/environment.txt"
hcloud version > "$out/hcloud-version.txt" 2>&1
manager_exec 'docker node ls' > "$out/docker-node-ls.txt"
manager_exec 'docker service ls' > "$out/final-services.txt"
manager_exec "timeout 120s docker service logs --timestamps '${QUAL_STACK}_deda'" > "$out/deda-logs/deda.txt" 2>&1 || true
network_curl 'http://prometheus:9090/api/v1/query?query=up' > "$out/metrics/prometheus-up.json" || true
network_curl 'http://prometheus:9090/api/v1/query?query=deda_reconcile_failures_total' > "$out/metrics/reconcile-failures.json" || true
network_curl 'http://prometheus:9090/api/v1/query?query=deda_reconcile_duration_seconds' > "$out/metrics/reconcile-duration.json" || true
network_curl 'http://prometheus:9090/api/v1/query?query=deda_trigger_duration_seconds' > "$out/metrics/trigger-duration.json" || true

: > "$out/docker-versions.txt"
for n in 1 2 3; do
  public_var="MANAGER_${n}_PUBLIC"
  printf '\n===== manager-%s =====\n' "$n" >> "$out/docker-versions.txt"
  ssh_node "$public_var" 'docker version' >> "$out/docker-versions.txt" 2>&1 || true
  copy_from_node "$public_var" /var/log/cloud-init-output.log "$out/docker-info/cloud-init-manager-$n.log" 2>/dev/null || true
  ssh_node "$public_var" 'docker info' > "$out/docker-info/manager-$n.txt" 2>&1 || true
done

[[ -n "$resolved_image" ]] || die 'No resolved DEDA image was recorded during deployment.'
[[ $(awk -F '\t' '$1 ~ /^manager-/ { print $2 }' "$out/image-digests.txt" | sort -u | wc -l) == 1 ]] || die 'DEDA platform image IDs were missing or differed across nodes.'

while IFS= read -r -d '' file; do
  sed -Ei -e 's/(HCLOUD_TOKEN|RABBITMQ_PASS|qualification_rabbitmq_credentials)[^[:space:]]*/\1=[REDACTED]/g' \
    -e 's/(dedaqual:)[A-Za-z0-9]+/\1[REDACTED]/g' "$file"
done < <(find "$out" -type f \( -name '*.txt' -o -name '*.json' -o -name '*.log' -o -name '*.md' \) -print0)

declare -A names=([01]='Basic scaling' [02]='DEDA leader failover' [03]='Redis outage' [04]='Version conflict' [05]='Invalid configuration' [06]='Scale to zero' [07]='DEDA restart' [08]='Swarm manager failure' [09]='Direct socket smoke')
mandatory=PASS
{
  # Markdown backticks are literal here, not shell command substitutions.
  # shellcheck disable=SC2016
  printf '# DEDA v0.2 release qualification\n\nCandidate: `%s`  \nResolved image: `%s`  \nRUN_ID: `%s`  \nLocation/type: `%s / %s`  \nTopology: three private-network Swarm managers, two DEDA HA replicas  \nStarted: %s  \nEnded: %s\n\n| Scenario | Result |\n| --- | --- |\n' \
    "$DEDA_IMAGE" "$resolved_image" "$RUN_ID" "$DEDA_QUAL_LOCATION" "$DEDA_QUAL_SERVER_TYPE" "$start_utc" "$end_utc"
  for id in $(printf '%s\n' "${!names[@]}" | sort); do
    status=$(jq -r '.status // "NOT_RUN"' "$(scenario_dir "$id")/result.json" 2>/dev/null || printf NOT_RUN)
    [[ "$status" == PASS ]] || mandatory=FAIL
    printf '| %s | %s |\n' "${names[$id]}" "$status"
  done
  soak_status=$(jq -r '.status // "NOT_RUN"' "$out/soak/result.json" 2>/dev/null || printf NOT_RUN)
  [[ "$soak_status" != FAIL ]] || mandatory=FAIL
  printf '| 24h soak | %s |\n\n## RELEASE RECOMMENDATION\n\n%s\n' "$soak_status" "$mandatory"
} > "$out/RESULT.md"

jq -n --arg run_id "$RUN_ID" --arg candidate "$DEDA_IMAGE" --arg resolved_image "$resolved_image" --arg result "$mandatory" \
  --arg started "$start_utc" --arg ended "$end_utc" --arg soak "$soak_status" \
  '{run_id:$run_id,candidate:$candidate,resolved_image:$resolved_image,result:$result,started:$started,ended:$ended,soak:$soak}' > "$out/result.json"

while IFS= read -r -d '' file; do
  relative=${file#"$out/"}; sha=$(sha256sum "$file" | awk '{print $1}')
  jq -n --arg file "$relative" --arg sha256 "$sha" '{file:$file,sha256:$sha256}'
done < <(find "$out" -type f ! -name manifest.json -print0 | sort -z) | jq -s --arg generated "$(utc_now)" '{generated:$generated,files:.}' > "$out/manifest.json"

note "Evidence collected in $out. Release recommendation is $mandatory; real-cloud execution is required before calling it a qualification pass."
