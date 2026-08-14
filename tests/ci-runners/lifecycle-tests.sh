#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
scripts=(
  "$ROOT/examples/ci-runners/github-actions/entrypoint.sh"
  "$ROOT/examples/ci-runners/azure-pipelines/start.sh"
  "$ROOT/examples/ci-runners/gitlab/entrypoint.sh"
)
for script in "${scripts[@]}"; do
  bash -n "$script" 2>/dev/null || sh -n "$script"
done

assert_contains() { grep -Fq -- "$2" "$1" || { echo "missing required lifecycle behavior in $1: $2" >&2; exit 1; }; }
github=${scripts[0]}
azure=${scripts[1]}
gitlab=${scripts[2]}

# Deterministic contract checks: no provider access or secrets are needed.
assert_contains "$github" 'registration secret is missing or empty'
assert_contains "$github" 'trap drain TERM INT'
assert_contains "$github" '--ephemeral --disableupdate'
assert_contains "$github" 'could not obtain removal token'
assert_contains "$azure" 'registration secret is missing or empty'
assert_contains "$azure" 'run.sh" --once'
assert_contains "$azure" 'agent is busy or cleanup API is unavailable; retrying'
assert_contains "$azure" 'trap drain TERM INT'
assert_contains "$gitlab" 'runner authentication secret is missing or empty'
assert_contains "$gitlab" 'trap drain QUIT'
assert_contains "$gitlab" 'kill -QUIT'
assert_contains "$gitlab" 'runner-manager cleanup was unavailable'

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"; mkdir -p "$BIN"
cat > "$BIN/curl" <<'EOF'
#!/bin/sh
printf '%s\n' '{"token":"temporary"}'
EOF
cat > "$BIN/jq" <<'EOF'
#!/bin/sh
cat >/dev/null
printf '%s\n' temporary
EOF
cat > "$BIN/gitlab-runner" <<'EOF'
#!/bin/sh
case "$1" in
  register) test "${FAKE_REGISTER_FAIL:-0}" = 0 || exit 42; echo register >> "$FAKE_LOG"; exit 0 ;;
  unregister) echo cleanup >> "$FAKE_LOG"; exit 0 ;;
  run) trap 'while test -e "$FAKE_BUSY"; do sleep .05; done; exit 0' QUIT; while test -e "$FAKE_BUSY"; do sleep .05; done ;;
esac
EOF
chmod +x "$BIN/curl" "$BIN/jq" "$BIN/gitlab-runner"

make_actions_home() {
  local home=$1
  mkdir -p "$home"
  cat > "$home/config.sh" <<'EOF'
#!/bin/sh
test "${FAKE_CONFIG_FAIL:-0}" = 0 || exit 42
case "$1" in remove) echo cleanup >> "$FAKE_LOG" ;; *) echo register >> "$FAKE_LOG" ;; esac
EOF
  cat > "$home/run.sh" <<'EOF'
#!/bin/sh
trap 'while test -e "$FAKE_BUSY"; do sleep .05; done; exit 0' TERM
while test -e "$FAKE_BUSY"; do sleep .05; done
EOF
  chmod +x "$home/config.sh" "$home/run.sh"
}
make_azure_home() {
  local home=$1
  mkdir -p "$home"
  cat > "$home/config.sh" <<'EOF'
#!/bin/sh
test "${FAKE_CONFIG_FAIL:-0}" = 0 || exit 42
if test "$1" = remove; then test ! -e "$FAKE_BUSY" || exit 1; echo cleanup >> "$FAKE_LOG"; else echo register >> "$FAKE_LOG"; fi
EOF
  cat > "$home/run.sh" <<'EOF'
#!/bin/sh
while test -e "$FAKE_BUSY"; do sleep .05; done
EOF
  chmod +x "$home/config.sh" "$home/run.sh"
}
wait_for_file() { for _ in $(seq 1 100); do test -s "$1" && return 0; sleep .05; done; return 1; }
assert_failure() { if "$@" >/dev/null 2>&1; then echo "expected failure: $*" >&2; exit 1; fi; }

# Missing registration secrets fail before any fake provider registration call.
assert_failure env PATH="$BIN:$PATH" GITHUB_OWNER=example RUNNER_HOME="$TMP/missing-gh" GITHUB_RUNNER_ADMIN_TOKEN_FILE="$TMP/no-secret" bash "$github"
assert_failure env PATH="$BIN:$PATH" AZP_URL=https://dev.azure.com/example AZP_POOL=pool AZP_AGENT_HOME="$TMP/missing-az" AZP_TOKEN_FILE="$TMP/no-secret" bash "$azure"
assert_failure env PATH="$BIN:$PATH" CI_SERVER_URL=https://gitlab.com GITLAB_RUNNER_TOKEN_FILE="$TMP/no-secret" sh "$gitlab"

# Busy fake jobs keep each wrapper alive after the service shutdown signal; once the
# job completes, registration cleanup is performed and the wrapper exits cleanly.
secret="$TMP/secret"; printf token > "$secret"
for provider in github azure gitlab; do
  busy="$TMP/$provider.busy"; log="$TMP/$provider.log"; : > "$busy"; : > "$log"
  case "$provider" in
    github)
      home="$TMP/actions"; make_actions_home "$home"
      env PATH="$BIN:$PATH" FAKE_BUSY="$busy" FAKE_LOG="$log" GITHUB_OWNER=example RUNNER_HOME="$home" GITHUB_RUNNER_ADMIN_TOKEN_FILE="$secret" bash "$github" & pid=$!
      signal=TERM ;;
    azure)
      home="$TMP/azure"; make_azure_home "$home"
      env PATH="$BIN:$PATH" FAKE_BUSY="$busy" FAKE_LOG="$log" AZP_URL=https://dev.azure.com/example AZP_POOL=pool AZP_AGENT_HOME="$home" AZP_TOKEN_FILE="$secret" AZP_CLEANUP_RETRIES=100 AZP_CLEANUP_DELAY_SECONDS=.05 bash "$azure" & pid=$!
      signal=TERM ;;
    gitlab)
      env PATH="$BIN:$PATH" FAKE_BUSY="$busy" FAKE_LOG="$log" CI_SERVER_URL=https://gitlab.com GITLAB_RUNNER_CONFIG="$TMP/gitlab/config.toml" GITLAB_RUNNER_TOKEN_FILE="$secret" sh "$gitlab" & pid=$!
      signal=QUIT ;;
  esac
  wait_for_file "$log"
  kill -"$signal" "$pid"
  sleep .2
  kill -0 "$pid" 2>/dev/null || { echo "$provider killed active simulated job" >&2; exit 1; }
  rm -f "$busy"
  wait "$pid"
  grep -Fq cleanup "$log" || { echo "$provider did not clean up after drain" >&2; exit 1; }
done

# A failed registration is non-zero and never proceeds to the run phase.
make_actions_home "$TMP/failing-actions"
assert_failure env PATH="$BIN:$PATH" FAKE_CONFIG_FAIL=1 FAKE_LOG="$TMP/fail.log" GITHUB_OWNER=example RUNNER_HOME="$TMP/failing-actions" GITHUB_RUNNER_ADMIN_TOKEN_FILE="$secret" bash "$github"
echo "CI runner lifecycle wrapper contracts passed."
