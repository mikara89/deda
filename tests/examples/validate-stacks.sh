#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)

mapfile -t stacks < <(find "$REPO_ROOT/examples" -mindepth 2 -maxdepth 2 -name stack.yml -print | sort)
test "${#stacks[@]}" -gt 0

for stack in "${stacks[@]}"; do
  relative_path=${stack#"$REPO_ROOT/"}
  echo "Validating $relative_path"
  (
    cd "$(dirname "$stack")"
    docker stack config -c stack.yml >/dev/null
  )
done

echo "Validated ${#stacks[@]} example stacks."
