# Prerequisites

Tools required to work with this project locally.

## Core (required to deploy)

These are checked by `deploy.sh` on every run:

| Tool | Required for | Install |
|------|-------------|---------|
| `terraform` or `tofu` (OpenTofu) | Provision cloud servers (AWS EC2 / Hetzner) | https://developer.hashicorp.com/terraform/install |
| `ansible-playbook` | Configure server (all 7 playbooks) | `pip install ansible` |
| `ssh` | Connect to server | system package |
| `ssh-keygen` | Clear known_hosts after server rebuild | system package |
| `ansible-vault` | Decrypt `secrets/.env` if vault-encrypted | comes with `ansible` |
| `python3` | Run Ansible and scripts | https://python.org |

### Ansible collections & Python deps

```bash
# Core
pip install -r ansible/requirements-deploy.txt

# Collections (for MariaDB and POSIX modules)
ansible-galaxy collection install ansible.mysql ansible.posix
```

## Cloud credentials (in secrets/.env)

| Target | Provider | Required env vars |
|--------|----------|-------------------|
| `prod` | AWS | `PROD_ACCESS_KEY`, `PROD_SECRET_KEY`, `PROD_REGION`, `PROD_EIP` |
| `dev-aws` | AWS | `DEV_AWS_ACCESS_KEY`, `DEV_AWS_SECRET_KEY`, `DEV_AWS_REGION` |
| `dev-hetz` | Hetzner | `HCLOUD_TOKEN` |

All targets require:
- `SSH_PRIVATE_KEY_PATH` — path to your SSH private key
- `SSH_PUBLIC_KEY_PATH` — path to your SSH public key
- `DB_PASS` — MariaDB password
- `GRAFANA_PASS` — Grafana admin password

## Site restore (secrets/rclone.conf)

The `restore` Ansible role downloads the MODX site from Google Drive during deploy.
It reads `secrets/rclone.conf` — a standard rclone config with a `gdrive:` remote.

Without it, the deploy will finish (all services configured) but **the site will not be restored**.
The deploy will fail at the final health check with "HTTP 403 — site not serving".

To get this file, ask a team member who has rclone configured with GDrive access, or run:
```bash
rclone config
```
and set up a remote named `gdrive` pointing to the DreamSeed backups folder.

You can also deploy without restore support and restore later:
```bash
./deploy.sh <target> -n -i <server-ip>
```
after adding `rclone.conf`.

## Pre-commit hooks (recommended)

```bash
pip install pre-commit
pre-commit install
```

Runs on every commit: YAML lint, large file check, secret detection, private key guard.

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

```bash
cp secrets/.env.example secrets/.env
# edit secrets/.env with your values
```

See `secrets/.env.example` for the full list of variables.
