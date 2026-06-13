# WP Cloud Site Git Deploy Action

Deploy an exact Git commit to a WP Cloud or Pressable site by running the
site-side [`wpcloud-site-git-deploy`](https://github.com/aipokalyptik/wpcloud-site-git-deploy)
CLI over SSH.

Unlike rsync-based deployment actions, this action does not upload the checked
out workflow directory. It tells the remote site to fetch the repository and
deploy the exact workflow commit. Git credentials for private repositories live
on the remote site user account.

## Quick Start

```yaml
name: Deploy

on:
  push:
    branches: [main]

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: aipokalyptik/wpcloud-site-git-deploy-action@v1
        with:
          host: ${{ secrets.WPCLOUD_SSH_HOST }}
          username: ${{ secrets.WPCLOUD_SSH_USERNAME }}
          password: ${{ secrets.WPCLOUD_SSH_PASSWORD }}
          docroot: /srv/htdocs
```

By default, the action deploys `${{ github.sha }}` from
`https://github.com/${{ github.repository }}.git` using the remote CLI release
`v1`.

## Inputs

| Input | Required | Default | Description |
| --- | --- | --- | --- |
| `host` | Yes | | SSH host name. |
| `username` | Yes | | SSH username. |
| `password` | No | | SSH password. Mutually exclusive with `private-key`. |
| `private-key` | No | | OpenSSH private key content. Mutually exclusive with `password`. |
| `private-key-passphrase` | No | | Optional passphrase for encrypted private-key authentication. |
| `known-hosts` | No | | Literal `known_hosts` content. If omitted, `ssh-keyscan` is used. |
| `port` | No | `22` | SSH port. |
| `docroot` | No | `/srv/htdocs` | Remote document root. |
| `deployment-name` | No | `site` | Remote CLI config name under `$HOME`. |
| `deployment-id` | No | normalized repository slug | Public deployment namespace under docroot. |
| `repo` | No | current GitHub repository HTTPS URL | Git URL the remote CLI fetches. |
| `commit` | No | `${{ github.sha }}` | Exact commit SHA to deploy. |
| `default-ref` | No | `main` | Default ref stored in the remote CLI config. |
| `keep-releases` | No | `3` | Number of remote release directories to keep. |
| `cli-ref` | No | `v1` | Ref of `aipokalyptik/wpcloud-site-git-deploy` to install remotely. |
| `post-deploy` | No | WP cache defaults | Commands run from `docroot` after deploy. Set `none` to disable. |

## Post-Deploy Commands

If omitted, the action runs:

```bash
wp cache flush
echo "y" | wp edge-cache purge --domain
```

Set `post-deploy: none` to run no post-deploy commands. Any other
`post-deploy` value replaces the defaults exactly. If a post-deploy command
fails, the workflow fails; the already-promoted CLI deployment is not rolled
back.

## Git Credentials

The remote CLI fetches the repository from the site over SSH/HTTPS. For private
repositories, configure Git credentials on the site user account before using
this action. Examples include a deploy key under `$HOME/.ssh`, Git credential
storage for HTTPS, or host-specific Git config.

This action does not write a GitHub token to the remote host in v1.

## Private Keys For SSH To The Site

Use `private-key` instead of `password`:

```yaml
with:
  host: ${{ secrets.WPCLOUD_SSH_HOST }}
  username: ${{ secrets.WPCLOUD_SSH_USERNAME }}
  private-key: ${{ secrets.WPCLOUD_SSH_PRIVATE_KEY }}
```

Encrypted keys require `private-key-passphrase`.

## Notes

- No `actions/checkout` step is required.
- The action always deploys by commit SHA by default, not by branch update.
- Rollback is intentionally not an action mode; use a revert commit or SSH into
  the site and run `wpcloud-site-git-deploy rollback`.
- `known-hosts` is recommended for stronger host key pinning. Without it, the
  action uses `ssh-keyscan` for trust-on-first-use.
