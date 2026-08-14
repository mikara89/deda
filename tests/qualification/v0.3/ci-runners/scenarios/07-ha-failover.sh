#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/common.sh"
begin_scenario 07 'Redis HA failover during active CI demand'
set_state '{"gitlab":{"jobs":[{"status":"running","tag_list":["linux","deda"]},{"status":"running","tag_list":["linux","deda"]}]}}'
wait_replicas gitlab-runner 2
before=$(redis_leader); [[ -n "$before" && "$before" != '(nil)' ]] || fail_scenario 'no Redis lease owner was recorded'
docker service update --force "$(service deda)" >/dev/null
wait_until 'a Redis leader after DEDA rolling restart' 60 bash -c "value=\$(docker run --rm --network '${DEDA_QUAL_STACK}_control' redis:7-alpine redis-cli -h '$(service redis)' --raw GET deda-v03-qualification:leader); [[ -n \"\$value\" && \"\$value\" != '(nil)' ]]" || fail_scenario 'standby did not acquire a lease after forced DEDA restart'
wait_replicas gitlab-runner 2
printf 'leader-before=%s\nleader-after=%s\n' "$before" "$(redis_leader)" > "$SCENARIO_DIR/redis-leadership.txt"
finish_scenario PASS 'active CI demand persisted through a forced two-replica DEDA failover; Redis recorded one lease owner'
