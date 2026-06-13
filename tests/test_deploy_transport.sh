#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
deploy="$repo_root/scripts/deploy.sh"
. "$repo_root/tests/lib.sh"

run_deploy() {
  local stdout_file="$1"
  local stderr_file="$2"
  (
    export WPCLOUD_SITE_GIT_DEPLOY_ACTION_DRY_RUN=1
    export INPUT_HOST="${INPUT_HOST-example.com}"
    export INPUT_PORT="${INPUT_PORT-22}"
    export INPUT_USERNAME="${INPUT_USERNAME-deploy}"
    export INPUT_PASSWORD="${INPUT_PASSWORD-secret-password}"
    export INPUT_PRIVATE_KEY="${INPUT_PRIVATE_KEY-}"
    export INPUT_PRIVATE_KEY_PASSPHRASE="${INPUT_PRIVATE_KEY_PASSPHRASE-}"
    export INPUT_KNOWN_HOSTS="${INPUT_KNOWN_HOSTS-}"
    export INPUT_DOCROOT="${INPUT_DOCROOT-/srv/htdocs}"
    export INPUT_DEPLOYMENT_NAME="${INPUT_DEPLOYMENT_NAME-site}"
    export INPUT_DEPLOYMENT_ID="${INPUT_DEPLOYMENT_ID-}"
    export INPUT_REPO="${INPUT_REPO-}"
    export INPUT_COMMIT="${INPUT_COMMIT-}"
    export INPUT_DEFAULT_REF="${INPUT_DEFAULT_REF-main}"
    export INPUT_KEEP_RELEASES="${INPUT_KEEP_RELEASES-3}"
    export INPUT_CLI_REF="${INPUT_CLI_REF-main}"
    export INPUT_POST_DEPLOY="${INPUT_POST_DEPLOY-}"
    export INPUT_GITHUB_REPOSITORY="${INPUT_GITHUB_REPOSITORY-aipokalyptik/example-site}"
    export INPUT_GITHUB_SHA="${INPUT_GITHUB_SHA-0123456789abcdef0123456789abcdef01234567}"
    "$deploy"
  ) >"$stdout_file" 2>"$stderr_file"
}

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
stdout="$tmpdir/stdout"
stderr="$tmpdir/stderr"

run_deploy "$stdout" "$stderr"
assert_contains "auth_mode=password" "$stderr"
assert_contains "repo=https://github.com/aipokalyptik/example-site.git" "$stderr"
assert_contains "commit=0123456789abcdef0123456789abcdef01234567" "$stderr"
assert_contains "cli_ref=main" "$stderr"
assert_contains "deployment_name=site" "$stderr"
assert_contains "deployment_id=aipokalyptik-example-site" "$stderr"
assert_contains "wpcloud-site-git-deploy init site --repo https://github.com/aipokalyptik/example-site.git --docroot /srv/htdocs --deployment-id aipokalyptik-example-site --default-ref main --keep-releases 3" "$stderr"
assert_contains "wpcloud-site-git-deploy deploy site --commit 0123456789abcdef0123456789abcdef01234567" "$stderr"
assert_not_contains "wpcloud-site-git-deploy update" "$stderr"
assert_contains "post_deploy=default" "$stderr"
assert_contains "wp cache flush" "$stderr"
assert_contains "echo \"y\" | wp edge-cache purge --domain" "$stderr"
assert_contains "ssh-keyscan -p 22 example.com" "$stderr"

script_tmp="$tmpdir/remote-script"
WPCLOUD_SITE_GIT_DEPLOY_ACTION_TMPDIR="$script_tmp" \
WPCLOUD_SITE_GIT_DEPLOY_ACTION_KEEP_TEMP=1 \
run_deploy "$stdout" "$stderr"
assert_contains "export PATH=\"\$HOME/.local/bin:\$HOME/.wpcloud-site-git-deploy/bin:\$PATH\"" "$script_tmp/remote-deploy.sh"

INPUT_POST_DEPLOY=none run_deploy "$stdout" "$stderr"
assert_contains "post_deploy=none" "$stderr"
assert_not_contains "wp cache flush" "$stderr"
unset INPUT_POST_DEPLOY

INPUT_POST_DEPLOY=$'printf custom\\n' run_deploy "$stdout" "$stderr"
assert_contains "post_deploy=provided" "$stderr"
assert_contains "printf custom" "$stderr"
unset INPUT_POST_DEPLOY

INPUT_PASSWORD="" INPUT_PRIVATE_KEY="PRIVATE KEY CONTENT" run_deploy "$stdout" "$stderr"
assert_contains "auth_mode=private-key" "$stderr"
assert_contains "-o IdentitiesOnly=yes" "$stderr"
assert_not_contains "sshpass" "$stderr"
assert_not_contains "PRIVATE KEY CONTENT" "$stderr"
unset INPUT_PASSWORD INPUT_PRIVATE_KEY

INPUT_PASSWORD="" INPUT_PRIVATE_KEY="" run_deploy "$stdout" "$stderr" && fail "missing auth should fail"
assert_contains "either password or private-key is required" "$stderr"

INPUT_PASSWORD="secret-password" INPUT_PRIVATE_KEY="PRIVATE KEY CONTENT" run_deploy "$stdout" "$stderr" && fail "conflicting auth should fail"
assert_contains "password and private-key are mutually exclusive" "$stderr"

INPUT_PASSWORD="" INPUT_PRIVATE_KEY="" INPUT_PRIVATE_KEY_PASSPHRASE="passphrase" run_deploy "$stdout" "$stderr" && fail "passphrase without key should fail"
assert_contains "private-key-passphrase requires private-key" "$stderr"

INPUT_PASSWORD="p@ss word!*" run_deploy "$stdout" "$stderr"
assert_contains "::add-mask::p@ss word!*" "$stdout"
assert_not_contains "p@ss word!*" "$stderr"
