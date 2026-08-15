#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/common.sh"
begin_scenario 02 'Azure Pipelines capacity and demand matching'
set_state '{"azure":{"jobs":[]}}'; wait_replicas azure-runner 0
set_state '{"azure":{"jobs":[{"demands":["deda","Agent.OS -equals Linux"],"assignTime":null,"finishTime":null},{"demands":["deda","Agent.OS -equals Linux"],"assignTime":null,"finishTime":null},{"demands":["deda","Agent.OS -equals Linux"],"assignTime":null,"finishTime":null},{"demands":["deda","Agent.OS -equals Windows"],"assignTime":null,"finishTime":null}]}}'; wait_replicas azure-runner 3
set_state '{"azure":{"jobs":[{"demands":["deda","Agent.OS -equals Linux"],"assignTime":"2026-01-01T00:00:00Z","finishTime":null},{"demands":["deda","Agent.OS -equals Linux"],"assignTime":"2026-01-01T00:00:00Z","finishTime":null},{"demands":["deda","Agent.OS -equals Linux"],"assignTime":"2026-01-01T00:00:00Z","finishTime":null}]}}'; wait_replicas azure-runner 3
set_state '{"azure":{"jobs":[]}}'; wait_replicas azure-runner 0
finish_scenario PASS 'Exists deda and Agent.OS=Linux were counted; Windows demand was excluded'
