# Prerequisites

Tools required to work with this project locally.

## Core (required to deploy)

| Tool | Min version | Install |
|------|-------------|---------|
| Terraform or OpenTofu | 1.5+ | https://developer.hashicorp.com/terraform/install |
| Ansible | 2.15+ | `pip install ansible` |
| Python | 3.10+ | https://python.org |
| SSH client | any | system package |

### Ansible collections & Python deps

```bash
# Collections
ansible-galaxy collection install community.mysql ansible.posix

# Python (for community.mysql)
pip install -r ansible/requirements-deploy.txt
```

## Cloud providers (depending on target)

| Tool | Required for |
|------|--------------|
| AWS CLI | `prod`, `dev-aws` targets (credentials in `secrets/.env`) |
| Hetzner account + API token | `dev-hetz` target (set `HCLOUD_TOKEN` in `.env`) |

## Pre-commit hooks (recommended)

```bash
pip install pre-commit
pre-commit install
```

Runs on every commit: YAML lint, large file check, secret detection (gitleaks), private key guard.

## Linting / CI (optional, for local checks)

```bash
# Shell
brew install shellcheck

# Python
pip install ruff

# Ansible (pinned version matching CI)
pip install -r ansible/requirements.txt

# Terraform
brew install tflint
brew install trivy

# Secrets
brew install gitleaks
```

## Secrets setup

Copy the template and fill in your values:

```bash
cp secrets/.env.example secrets/.env
```

See `secrets/.env.example` for the full list of required variables.

### rclone.conf (required for site restore)

The `restore` Ansible role downloads the MODX site from Google Drive during deploy.
It reads `secrets/rclone.conf` — a standard rclone config file with a `gdrive:` remote.

Without it, the deploy will finish (all services like nginx, php, mariadb, monitoring, grafana
will be configured) but **the site itself will not be restored**. The deploy will fail at the
final health check with "HTTP 403 — site not serving".

To get this file, ask a team member who has already configured rclone with Google Drive access,
or run `rclone config` locally to set up a `gdrive:` remote pointing to the DreamSeed backups folder.

Alternatively, you can deploy without restore support and manually restore later via
`RESTORE_ALL.sh` or `deploy.sh ... -i <IP>` after adding the config file.
