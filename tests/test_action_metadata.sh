#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_root/tests/lib.sh"

action="$repo_root/action.yml"
[[ -f "$action" ]] || fail "missing action.yml"

for input in host port username password private-key private-key-passphrase known-hosts docroot deployment-name deployment-id repo commit default-ref keep-releases cli-ref post-deploy; do
  assert_contains "  $input:" "$action"
  assert_contains "INPUT_$(printf '%s' "$input" | tr '[:lower:]-' '[:upper:]_')" "$action"
done

assert_contains "default: \"22\"" "$action"
assert_contains "default: /srv/htdocs" "$action"
assert_contains "default: site" "$action"
assert_contains "default: main" "$action"
assert_contains "default: \"3\"" "$action"
assert_contains "default: v1" "$action"
assert_contains 'INPUT_GITHUB_REPOSITORY: ${{ github.repository }}' "$action"
assert_contains 'INPUT_GITHUB_SHA: ${{ github.sha }}' "$action"
assert_contains "using: composite" "$action"
