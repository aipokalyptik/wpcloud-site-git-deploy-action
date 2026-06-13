#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

"$repo_root/tests/test_action_metadata.sh"
"$repo_root/tests/test_deploy_transport.sh"

bash -n "$repo_root/scripts/deploy.sh" "$repo_root/tests/"*.sh

if command -v shellcheck >/dev/null 2>&1; then
  shellcheck "$repo_root/scripts/deploy.sh" "$repo_root/tests/"*.sh
else
  echo "shellcheck not found; skipping shell lint" >&2
fi
