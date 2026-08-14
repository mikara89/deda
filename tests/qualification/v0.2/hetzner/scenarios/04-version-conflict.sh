#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd); source "$SCRIPT_DIR/common.sh"; load_run
id=04; start_scenario "$id" 'Docker service version conflict'; dir=$(scenario_dir "$id"); service="${QUAL_STACK}_basic-worker"
metric=deda_qual_conflict_metric
manager_exec "printf '$metric 10\n' | docker run --rm -i --network '$(network_name)' curlimages/curl:8.10.1 --fail --silent --show-error --data-binary @- http://pushgateway:9091/metrics/job/deda-qualification" >/dev/null
manager_exec "docker service update --label-add 'com.deda.autoscale.trigger.query=$metric' '$service'" >/dev/null; wait_replicas "$service" 1
manager_exec "docker service inspect '$service'" > "$dir/service-before.json"
started=$(utc_now)
manager_exec "for i in \$(seq 1 100); do docker service update --label-add deda.qual.external=\$i '$service' >/dev/null 2>&1 || true; sleep 0.05; done" > "$dir/external-update.txt" &
churn_pid=$!
manager_exec "printf '$metric 100\n' | docker run --rm -i --network '$(network_name)' curlimages/curl:8.10.1 --fail --silent --show-error --data-binary @- http://pushgateway:9091/metrics/job/deda-qualification" > "$dir/scale-request.txt"
wait "$churn_pid" || true
wait_replicas "$service" 10
manager_exec "docker service inspect '$service'" > "$dir/service-after.json"
jq -e '.[0].Spec.Labels["deda.qual.external"] != null' "$dir/service-after.json" >/dev/null || fail_scenario "$id" 'The harmless concurrent external service-spec change was lost.'
jq -e --slurpfile before "$dir/service-before.json" '
  .[0].Spec.TaskTemplate.Networks == $before[0][0].Spec.TaskTemplate.Networks and
  .[0].Spec.TaskTemplate.ContainerSpec.Image == $before[0][0].Spec.TaskTemplate.ContainerSpec.Image and
  .[0].Spec.TaskTemplate.ContainerSpec.Command == $before[0][0].Spec.TaskTemplate.ContainerSpec.Command and
  .[0].Spec.TaskTemplate.ContainerSpec.Args == $before[0][0].Spec.TaskTemplate.ContainerSpec.Args and
  .[0].Spec.TaskTemplate.ContainerSpec.Env == $before[0][0].Spec.TaskTemplate.ContainerSpec.Env and
  .[0].Spec.TaskTemplate.ContainerSpec.Mounts == $before[0][0].Spec.TaskTemplate.ContainerSpec.Mounts
' "$dir/service-after.json" >/dev/null || fail_scenario "$id" 'DEDA or concurrent updates lost an unrelated workload service-spec field.'
before_version=$(jq -r '.[0].Version.Index' "$dir/service-before.json"); after_version=$(jq -r '.[0].Version.Index' "$dir/service-after.json")
(( after_version > before_version )) || fail_scenario "$id" 'The service version did not advance during the conflict exercise.'
printf 'version-before=%s\nversion-after=%s\n' "$before_version" "$after_version" > "$dir/version-churn.txt"
manager_exec "timeout 30s docker service logs --since '$started' '${QUAL_STACK}_deda'" > "$dir/deda-logs-during-churn.txt" 2>&1 || true
capture_cluster "$dir"; finish_scenario "$id" PASS 'DEDA reached the requested scale while repeated external version churn preserved an unrelated spec label.'
