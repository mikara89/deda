#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd); source "$SCRIPT_DIR/common.sh"; load_run
id=03; start_scenario "$id" 'Redis outage fail-closed'; dir=$(scenario_dir "$id")
redis_stopped=0
cleanup() { if [[ "$redis_stopped" == 1 ]]; then manager_exec "docker service scale '${QUAL_STACK}_redis=1'" >/dev/null 2>&1 || true; fi; }
trap cleanup EXIT
service="${QUAL_STACK}_basic-worker"; manager_exec "docker service update --label-add 'com.deda.autoscale.trigger.query=vector(10)' '$service'" >/dev/null; wait_replicas "$service" 1
manager_exec "docker service scale '${QUAL_STACK}_redis=0'" > "$dir/redis-stop.txt"; redis_stopped=1; sleep 20
manager_exec "docker service update --label-add 'com.deda.autoscale.trigger.query=vector(100)' '$service'" >/dev/null; sleep 15
actual=$(service_replicas "$service"); printf 'replicas-during-redis-outage=%s\n' "$actual" > "$dir/observations.txt"
[[ "$actual" == 1 ]] || fail_scenario "$id" 'DEDA mutated a service while Redis leadership storage was unavailable.'
manager_exec "for task in \$(docker service ps '${QUAL_STACK}_deda' --filter desired-state=running --format '{{.ID}}'); do ip=\$(docker inspect \"\$task\" --format '{{range .NetworksAttachments}}{{range .Addresses}}{{.}}{{end}}{{end}}' | cut -d/ -f1); docker run --rm --network '$(network_name)' curlimages/curl:8.10.1 --silent --output /dev/null --write-out '%{http_code}\n' \"http://\$ip:8080/health/ready\" || true; done" > "$dir/readiness-status.txt"
[[ $(grep -c '^503$' "$dir/readiness-status.txt" || true) == 2 ]] || fail_scenario "$id" 'Both DEDA replicas did not report 503 while Redis leadership storage was unavailable.'
manager_exec "docker service scale '${QUAL_STACK}_redis=1'" > "$dir/redis-restore.txt"; redis_stopped=0; wait_replicas "$service" 10
wait_for 'DEDA readiness after Redis restore' 90 2 network_curl --output /dev/null 'http://deda:8080/health/ready'
[[ -n "$(deda_leader)" ]] || fail_scenario "$id" 'No DEDA leader lease was established after Redis restore.'
capture_cluster "$dir"; finish_scenario "$id" PASS 'Redis outage produced no mutation; leadership and reconciliation recovered after restore.'
