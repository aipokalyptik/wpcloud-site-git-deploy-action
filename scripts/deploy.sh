#!/usr/bin/env bash
set -euo pipefail

readonly VERSION="0.1.0"
readonly DEFAULT_POST_DEPLOY=$'wp cache flush\necho "y" | wp edge-cache purge --domain\n'
readonly CLI_REPO_URL="https://github.com/aipokalyptik/wpcloud-site-git-deploy.git"

password=""
private_key=""
private_key_passphrase=""
auth_mode=""
DEPLOY_TMPDIR=""
SSH_OPTIONS=()
SSH_AGENT_PID_TO_CLEAN=""

usage() {
  cat <<'USAGE'
Usage: deploy.sh [--help|--version]

Install/update the wpcloud-site-git-deploy CLI on a remote site and deploy an
exact Git commit through that remote CLI.
USAGE
}

die() {
  echo "deploy.sh: $*" >&2
  exit 64
}

info() {
  echo "deploy.sh: $*" >&2
}

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

mask_secret() {
  local secret="$1"
  [[ -n "$secret" ]] || return 0
  [[ "${GITHUB_ACTIONS:-}" == "true" || "${WPCLOUD_SITE_GIT_DEPLOY_ACTION_DRY_RUN:-}" == "1" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "$line" ]] || continue
    printf '::add-mask::%s\n' "$line"
  done <<<"$secret"
}

require_input() {
  local name="$1"
  local value="$2"
  [[ -n "$(trim "$value")" ]] || die "missing required input: $name"
}

normalize_id() {
  local value
  value="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/-+/-/g')"
  [[ -n "$value" ]] || die "deployment-id must contain at least one letter or number after normalization"
  printf '%s' "$value"
}

require_name() {
  [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]] || die "deployment-name must contain only letters, numbers, dot, underscore, or dash"
}

shell_join() {
  local out=""
  local arg
  for arg in "$@"; do
    printf -v arg '%q' "$arg"
    out+=" $arg"
  done
  printf '%s' "${out# }"
}

validate_auth_inputs() {
  local has_password=0
  local has_key=0
  [[ -n "$(trim "$password")" ]] && has_password=1
  [[ -n "$(trim "$private_key")" ]] && has_key=1

  if ((has_password && has_key)); then
    die "password and private-key are mutually exclusive"
  fi
  if [[ -n "$(trim "$private_key_passphrase")" && "$has_key" -eq 0 ]]; then
    die "private-key-passphrase requires private-key"
  fi
  if ((! has_password && ! has_key)); then
    die "either password or private-key is required"
  fi

  if ((has_password)); then
    auth_mode="password"
  else
    auth_mode="private-key"
  fi
}

validate_inputs() {
  local port="$1"
  local keep_releases="$2"
  local docroot="$3"
  local commit="$4"
  local cli_ref="$5"

  [[ "$port" =~ ^[0-9]+$ && "$port" -ge 1 && "$port" -le 65535 ]] || die "port must be 1 through 65535"
  [[ "$keep_releases" =~ ^[0-9]+$ && "$keep_releases" -ge 1 ]] || die "keep-releases must be a positive integer"
  [[ "$docroot" != *[[:space:]]* ]] || die "docroot must not contain whitespace"
  [[ -n "$commit" ]] || die "commit is required"
  [[ -n "$cli_ref" ]] || die "cli-ref is required"
}

write_known_hosts() {
  local known_hosts_input="$1"
  local host="$2"
  local port="$3"
  local output="$4"

  if [[ -n "$(trim "$known_hosts_input")" ]]; then
    printf '%s\n' "$known_hosts_input" >"$output"
    info "known_hosts_source=input"
    return 0
  fi

  info "known_hosts_source=ssh-keyscan"
  if [[ "${WPCLOUD_SITE_GIT_DEPLOY_ACTION_DRY_RUN:-}" == "1" ]]; then
    info "dry-run: ssh-keyscan -p $port $host"
    printf '%s ssh-ed25519 DRYRUN\n' "$host" >"$output"
    return 0
  fi

  ssh-keyscan -p "$port" "$host" >"$output" 2>/dev/null || die "ssh-keyscan failed for $host:$port"
  [[ -s "$output" ]] || die "ssh-keyscan returned no host keys for $host:$port"
}

write_private_key() {
  local path="$1"
  umask 077
  printf '%s\n' "$private_key" >"$path"
  chmod 600 "$path"
}

start_key_agent() {
  local key_file="$1"
  local askpass="$2"
  local add_stderr="$3"

  cat >"$askpass" <<'SH'
#!/bin/sh
printf '%s\n' "${WPCLOUD_SITE_GIT_DEPLOY_KEY_PASSPHRASE:?}"
SH
  chmod 700 "$askpass"
  eval "$(ssh-agent -s)" >/dev/null
  SSH_AGENT_PID_TO_CLEAN="$SSH_AGENT_PID"
  if ! DISPLAY=none SSH_ASKPASS="$askpass" SSH_ASKPASS_REQUIRE=force WPCLOUD_SITE_GIT_DEPLOY_KEY_PASSPHRASE="$private_key_passphrase" ssh-add "$key_file" </dev/null >/dev/null 2>"$add_stderr"; then
    cat "$add_stderr" >&2
    die "ssh-add failed for private-key"
  fi
}

cleanup() {
  if [[ -n "$SSH_AGENT_PID_TO_CLEAN" ]]; then
    SSH_AGENT_PID="$SSH_AGENT_PID_TO_CLEAN" ssh-agent -k >/dev/null 2>&1 || true
  fi
  if [[ -n "$DEPLOY_TMPDIR" && "${WPCLOUD_SITE_GIT_DEPLOY_ACTION_KEEP_TEMP:-}" != "1" ]]; then
    rm -rf "$DEPLOY_TMPDIR"
  fi
}

ssh_prefix() {
  if [[ "$auth_mode" == "password" ]]; then
    printf '%s\n' "env SSHPASS=REDACTED sshpass -e"
  else
    printf '%s\n' ""
  fi
}

run_or_print() {
  local label="$1"
  shift
  if [[ "${WPCLOUD_SITE_GIT_DEPLOY_ACTION_DRY_RUN:-}" == "1" ]]; then
    local rendered
    rendered="$(shell_join "$@")"
    if [[ -n "$password" ]]; then
      rendered="${rendered//"$password"/REDACTED}"
    fi
    if [[ -n "$private_key_passphrase" ]]; then
      rendered="${rendered//"$private_key_passphrase"/REDACTED}"
    fi
    info "dry-run: $label: $rendered"
    return 0
  fi
  "$@"
}

remote_ssh() {
  local label="$1"
  local remote_command="$2"
  if [[ "$auth_mode" == "password" ]]; then
    run_or_print "$label" env "SSHPASS=$password" sshpass -e ssh "${SSH_OPTIONS[@]}" "$REMOTE_LOGIN" "$remote_command"
  else
    run_or_print "$label" ssh "${SSH_OPTIONS[@]}" "$REMOTE_LOGIN" "$remote_command"
  fi
}

main() {
  case "${1:-}" in
    --help|-h)
      usage
      exit 0
      ;;
    --version)
      echo "$VERSION"
      exit 0
      ;;
    "")
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac

  local host="${INPUT_HOST:-}"
  local port="${INPUT_PORT:-22}"
  local username="${INPUT_USERNAME:-}"
  password="${INPUT_PASSWORD:-}"
  private_key="${INPUT_PRIVATE_KEY:-}"
  private_key_passphrase="${INPUT_PRIVATE_KEY_PASSPHRASE:-}"
  local known_hosts_input="${INPUT_KNOWN_HOSTS:-}"
  local docroot="${INPUT_DOCROOT:-/srv/htdocs}"
  local deployment_name="${INPUT_DEPLOYMENT_NAME:-site}"
  local deployment_id_input="${INPUT_DEPLOYMENT_ID:-}"
  local repo="${INPUT_REPO:-}"
  local commit="${INPUT_COMMIT:-}"
  local default_ref="${INPUT_DEFAULT_REF:-main}"
  local keep_releases="${INPUT_KEEP_RELEASES:-3}"
  local cli_ref="${INPUT_CLI_REF:-v1}"
  local post_deploy="${INPUT_POST_DEPLOY:-}"
  local github_repository="${INPUT_GITHUB_REPOSITORY:-}"
  local github_sha="${INPUT_GITHUB_SHA:-}"

  require_input "host" "$host"
  require_input "username" "$username"
  validate_auth_inputs

  host="$(trim "$host")"
  port="$(trim "$port")"
  username="$(trim "$username")"
  docroot="$(trim "$docroot")"
  deployment_name="$(trim "$deployment_name")"
  default_ref="$(trim "$default_ref")"
  keep_releases="$(trim "$keep_releases")"
  cli_ref="$(trim "$cli_ref")"
  repo="$(trim "$repo")"
  commit="$(trim "$commit")"

  [[ -n "$repo" ]] || repo="https://github.com/$github_repository.git"
  [[ -n "$commit" ]] || commit="$github_sha"
  local deployment_id
  if [[ -n "$(trim "$deployment_id_input")" ]]; then
    deployment_id="$(normalize_id "$deployment_id_input")"
  else
    deployment_id="$(normalize_id "$github_repository")"
  fi

  require_name "$deployment_name"
  validate_inputs "$port" "$keep_releases" "$docroot" "$commit" "$cli_ref"
  mask_secret "$password"
  mask_secret "$private_key"
  mask_secret "$private_key_passphrase"

  local tmpdir
  if [[ -n "${WPCLOUD_SITE_GIT_DEPLOY_ACTION_TMPDIR:-}" ]]; then
    tmpdir="$WPCLOUD_SITE_GIT_DEPLOY_ACTION_TMPDIR"
    mkdir -p "$tmpdir"
  else
    tmpdir="$(mktemp -d)"
  fi
  DEPLOY_TMPDIR="$tmpdir"
  trap cleanup EXIT

  local known_hosts_file="$tmpdir/known_hosts"
  write_known_hosts "$known_hosts_input" "$host" "$port" "$known_hosts_file"

  local private_key_file=""
  SSH_OPTIONS=(-o "UserKnownHostsFile=$known_hosts_file" -o "StrictHostKeyChecking=yes" -p "$port")
  if [[ "$auth_mode" == "password" ]]; then
    command -v sshpass >/dev/null 2>&1 || [[ "${WPCLOUD_SITE_GIT_DEPLOY_ACTION_DRY_RUN:-}" == "1" ]] || die "sshpass is required for password auth"
    SSH_OPTIONS=(-o "BatchMode=no" -o "PubkeyAuthentication=no" -o "PreferredAuthentications=password,keyboard-interactive" "${SSH_OPTIONS[@]}")
  else
    private_key_file="$tmpdir/private-key"
    write_private_key "$private_key_file"
    SSH_OPTIONS=(-o "BatchMode=yes" -o "IdentitiesOnly=yes" -i "$private_key_file" "${SSH_OPTIONS[@]}")
    if [[ -n "$(trim "$private_key_passphrase")" && "${WPCLOUD_SITE_GIT_DEPLOY_ACTION_DRY_RUN:-}" != "1" ]]; then
      start_key_agent "$private_key_file" "$tmpdir/ssh-askpass" "$tmpdir/ssh-add.stderr"
    fi
  fi

  REMOTE_LOGIN="$username@$host"

  local post_deploy_mode="default"
  case "$(trim "$post_deploy")" in
    "")
      post_deploy="$DEFAULT_POST_DEPLOY"
      post_deploy_mode="default"
      ;;
    none)
      post_deploy=""
      post_deploy_mode="none"
      ;;
    *)
      post_deploy_mode="provided"
      ;;
  esac

  info "auth_mode=$auth_mode"
  info "port=$port"
  info "docroot=$docroot"
  info "deployment_name=$deployment_name"
  info "deployment_id=$deployment_id"
  info "repo=$repo"
  info "commit=$commit"
  info "default_ref=$default_ref"
  info "keep_releases=$keep_releases"
  info "cli_ref=$cli_ref"
  info "post_deploy=$post_deploy_mode"
  info "remote_init_command=wpcloud-site-git-deploy init $deployment_name --repo $repo --docroot $docroot --deployment-id $deployment_id --default-ref $default_ref --keep-releases $keep_releases"
  info "remote_deploy_command=wpcloud-site-git-deploy deploy $deployment_name --commit $commit"

  local remote_script="$tmpdir/remote-deploy.sh"
  cat >"$remote_script" <<'REMOTE'
#!/usr/bin/env bash
set -euo pipefail

cli_repo="$1"
cli_ref="$2"
deployment_name="$3"
repo="$4"
docroot="$5"
deployment_id="$6"
default_ref="$7"
keep_releases="$8"
commit="$9"
post_deploy_file="${10}"

install_dir="$HOME/.wpcloud-site-git-deploy/src"
rm -rf "$install_dir"
git clone --depth 1 --branch "$cli_ref" "$cli_repo" "$install_dir"
"$install_dir/scripts/install.sh" >/tmp/wpcloud-site-git-deploy-install.log
export PATH="$HOME/.local/bin:$HOME/.wpcloud-site-git-deploy/bin:$PATH"
wpcloud-site-git-deploy init "$deployment_name" --repo "$repo" --docroot "$docroot" --deployment-id "$deployment_id" --default-ref "$default_ref" --keep-releases "$keep_releases"
wpcloud-site-git-deploy deploy "$deployment_name" --commit "$commit"
if [[ -n "$post_deploy_file" ]]; then
  (cd "$docroot" && bash -e "$post_deploy_file")
fi
REMOTE
  chmod 700 "$remote_script"

  local remote_tmp="/tmp/wpcloud-site-git-deploy-action.$$"
  local remote_script_path="$remote_tmp/deploy.sh"
  local remote_post_deploy_path=""
  remote_ssh "remote-tmp" "rm -rf $(printf '%q' "$remote_tmp") && mkdir -p $(printf '%q' "$remote_tmp")"

  if [[ "$auth_mode" == "password" ]]; then
    run_or_print "upload-remote-script" env "SSHPASS=$password" sshpass -e scp -P "$port" -o "UserKnownHostsFile=$known_hosts_file" -o "StrictHostKeyChecking=yes" "$remote_script" "$REMOTE_LOGIN:$remote_script_path"
  else
    run_or_print "upload-remote-script" scp -P "$port" -o "UserKnownHostsFile=$known_hosts_file" -o "StrictHostKeyChecking=yes" -i "$private_key_file" "$remote_script" "$REMOTE_LOGIN:$remote_script_path"
  fi

  if [[ -n "$(trim "$post_deploy")" ]]; then
    local post_deploy_file="$tmpdir/post-deploy.sh"
    printf '%s' "$post_deploy" >"$post_deploy_file"
    remote_post_deploy_path="$remote_tmp/post-deploy.sh"
    if [[ "$auth_mode" == "password" ]]; then
      run_or_print "upload-post-deploy" env "SSHPASS=$password" sshpass -e scp -P "$port" -o "UserKnownHostsFile=$known_hosts_file" -o "StrictHostKeyChecking=yes" "$post_deploy_file" "$REMOTE_LOGIN:$remote_post_deploy_path"
    else
      run_or_print "upload-post-deploy" scp -P "$port" -o "UserKnownHostsFile=$known_hosts_file" -o "StrictHostKeyChecking=yes" -i "$private_key_file" "$post_deploy_file" "$REMOTE_LOGIN:$remote_post_deploy_path"
    fi
    if [[ "${WPCLOUD_SITE_GIT_DEPLOY_ACTION_DRY_RUN:-}" == "1" ]]; then
      info "$post_deploy"
    fi
  fi

  local command
  command="$(shell_join bash "$remote_script_path" "$CLI_REPO_URL" "$cli_ref" "$deployment_name" "$repo" "$docroot" "$deployment_id" "$default_ref" "$keep_releases" "$commit" "$remote_post_deploy_path")"
  remote_ssh "deploy" "$command"
  remote_ssh "cleanup" "rm -rf $(printf '%q' "$remote_tmp")"
}

main "$@"
