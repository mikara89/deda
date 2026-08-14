#!/usr/bin/env bash
set -euo pipefail

secret=$(mktemp)
trap 'rm -f "$secret"' EXIT
printf 'not-a-real-token' > "$secret"
chmod 0400 "$secret"

assert_job_cannot_read_secret() {
  local image=$1 user=$2 target=$3
  if docker run --rm --user "$user" -v "$secret:$target:ro" --entrypoint /bin/sh "$image" -c "test ! -r '$target'"; then return 0; fi
  echo "CI job user $user can read $target in $image" >&2
  return 1
}

assert_job_cannot_read_secret deda-github-runner:ci runner /run/secrets/github-runner-admin
assert_job_cannot_read_secret deda-azure-runner:ci azp /run/secrets/ado-agent-registration
assert_job_cannot_read_secret deda-gitlab-runner:ci ci-job /run/secrets/gitlab-runner-auth
echo "Runner job users cannot read registration-secret mounts."
