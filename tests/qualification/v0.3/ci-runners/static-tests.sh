#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
for command in bash python3 jq; do command -v "$command" >/dev/null 2>&1 || { echo "missing $command" >&2; exit 1; }; done
find "$SCRIPT_DIR" -type f -name '*.sh' -print0 | xargs -0 -n1 bash -n
for script in github-curl github-jq gitlab-runner; do
  sh -n "$SCRIPT_DIR/simulator/real-runner/$script"
done
for script in run-deterministic.sh collect-evidence.sh real/run-all.sh real/github.sh real/azure-pipelines.sh real/gitlab.sh; do
  test -x "$SCRIPT_DIR/$script" || { echo "missing executable bit on $script" >&2; exit 1; }
done
grep -Fq 'bash "$SCRIPT_DIR/collect-evidence.sh"' "$SCRIPT_DIR/run-deterministic.sh"
grep -Fq 'bash "$SCRIPT_DIR/$provider.sh"' "$SCRIPT_DIR/real/run-all.sh"
python3 -m py_compile "$SCRIPT_DIR/simulator/server.py"
python3 "$SCRIPT_DIR/simulator/test_server.py"
grep -Fq 'completed-after-drain' "$SCRIPT_DIR/simulator/runner.sh"
jq empty "$SCRIPT_DIR/stack/credential-policy.json.tpl"
for name in 01-github-capacity 02-azure-capacity 03-gitlab-capacity 04-active-job-protection 05-provider-failure 06-observation-cache 07-ha-failover 08-credential-security 09-scale-to-zero 10-lifecycle-cleanup; do
  test -f "$SCRIPT_DIR/scenarios/$name.sh"
done
grep -Fq -- '--confirm-real-provider-tests' "$SCRIPT_DIR/real/run-all.sh"
grep -Fq 'RELEASE QUALIFICATION: **NOT_QUALIFIED**' "$SCRIPT_DIR/collect-evidence.sh"
if command -v docker >/dev/null 2>&1; then
  policy="$SCRIPT_DIR/stack/credential-policy.json"
  trap 'rm -f "$policy"' EXIT
  sed -e 's/__GITHUB_SERVICE__/deda-qual-static_github-runner/g' -e 's/__AZURE_SERVICE__/deda-qual-static_azure-runner/g' -e 's/__GITLAB_SERVICE__/deda-qual-static_gitlab-runner/g' "$SCRIPT_DIR/stack/credential-policy.json.tpl" > "$policy"
  (cd "$SCRIPT_DIR/stack" && DEDA_IMAGE=deda:qualification CI_SIMULATOR_IMAGE=deda-ci-provider-simulator:qualification CI_RUNNER_SIMULATOR_IMAGE=deda-ci-runner-lifecycle-simulator:qualification QUAL_SECRET_PREFIX=deda-qual-static docker stack config -c stack.yml >/dev/null)
fi
printf 'v0.3 CI runner qualification static tests passed.\n'
