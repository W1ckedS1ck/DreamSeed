# Prerequisites

Tools required to work with this project locally.

> Continuously updated — see [Releases](https://github.com/W1ckedS1ck/DreamSeed/releases) for the changelog.

## Core (required to deploy)

These are checked by `deploy.sh` on every run:

| Tool | Required for | Install |
|------|-------------|---------|
| `terraform` (or `tofu`) | Provision cloud servers (AWS EC2 / Hetzner) — `deploy.sh` falls back to OpenTofu if `terraform` is absent | <https://developer.hashicorp.com/terraform/install> |
| `ansible-playbook` | Configure server (all 9 playbooks) | `uv pip install --require-hashes -r ansible/requirements-deploy.txt && ansible-galaxy collection install -r ansible/requirements.yml` |
| `ssh` | Connect to server | system package |
| `ssh-keygen` | Clear known_hosts after server rebuild | system package |
| `ansible-vault` | Decrypt `secrets/.env` if vault-encrypted | comes with `ansible-core` |

> `python3` is also required (Ansible and several scripts run on it) but is not explicitly checked by the preflight — most systems ship it by default.

### Ansible collections & Python deps

```bash
# Create/activate a venv first (uv installs into it, not into a managed Python):
uv venv .venv && source .venv/bin/activate

# Core
uv pip install --require-hashes -r ansible/requirements-deploy.txt

# Collections (for MariaDB and POSIX modules) — versions pinned in requirements.yml
ansible-galaxy collection install -r ansible/requirements.yml
```

## Cloud credentials (in secrets/.env)

| Target | Current backend | Required env vars |
|--------|-----------------|-------------------|
| `prod` | AWS EC2 | `PROD_ACCESS_KEY`, `PROD_SECRET_KEY`, `PROD_REGION` |
| `prod-hetz` | Hetzner Cloud | `PROD_HETZ_HCLOUD_TOKEN` (falls back to `HCLOUD_TOKEN`) |
| `dev-aws` | AWS EC2 | `DEV_AWS_ACCESS_KEY`, `DEV_AWS_SECRET_KEY`, `DEV_AWS_REGION` |
| `dev-hetz` | Hetzner Cloud | `HCLOUD_TOKEN` |

All targets require:

- `SSH_PRIVATE_KEY_PATH` — path to your SSH private key
- `SSH_PUBLIC_KEY_PATH` — path to your SSH public key
- `DB_PASS` — MariaDB password
- `GRAFANA_PASS` — Grafana admin password
- `TG_TOKEN` — Telegram bot token
- `TG_CHAT_ID` — Telegram chat ID for alerts
- `TG_THREAD_ID` — Telegram topic/thread ID for alerts
- `OWNER` — display name for Telegram reports
- `TF_API_TOKEN` — Terraform Cloud API token
- `CLOUDFLARE_API_TOKEN` — Cloudflare API token (for SSL DNS-01 + DNS update; zone ID auto-detected)
- `BETTERUPTIME_API_TOKEN` — Better Stack API token (heartbeats, monitors, status page)
- `BETTERUPTIME_BACKUP_KEY` … `BETTERUPTIME_CHECK_SERVICES_KEY` — per-script heartbeat keys (6 total)
- `RCLONE_CRYPT_PASSWORD` — password for rclone crypt remote (AES-256 backup encryption)

Hetzner (prefixed per-target, can also fall back to unprefixed vars):

- `DEV_HETZ_SSH_KEY_NAME` or `PROD_HETZ_SSH_KEY_NAME` — existing SSH key in Hetzner Cloud
- `DEV_HETZ_PRIMARY_IP_NAME` or `PROD_HETZ_PRIMARY_IP_NAME` — existing Primary IP (optional)

Grafana Cloud (per target):

- `DEV_GRAFANA_CLOUD_URL` or `PROD_GRAFANA_CLOUD_URL` — Prometheus push endpoint
- `DEV_GRAFANA_CLOUD_USERNAME` or `PROD_GRAFANA_CLOUD_USERNAME` — instance ID
- `DEV_GRAFANA_CLOUD_TOKEN` or `PROD_GRAFANA_CLOUD_TOKEN` — vmagent token
- `DEV_GRAFANA_CLOUD_SA_TOKEN` or `PROD_GRAFANA_CLOUD_SA_TOKEN` — Service Account token (Terraform)

## Site restore (rclone config)

The `restore` Ansible role downloads the MODX site from Google Drive during deploy.
It needs a `gdrive-crypt` (AES-256 encrypted) remote pointing to the DreamSeed backups folder.

The config is automatically created in CI from two GitHub Secrets:

- **`RCLONE_CONF_BASE64`** — base64-encoded rclone config with `gdrive:` remote
- **`RCLONE_CRYPT_PASSWORD`** — password for the `gdrive-crypt` crypt wrapper

Locally, you can run:

```bash
bash scripts/lint.sh --secrets  # secrets hygiene audit (gitignore, tracked files, hardcoded patterns)
```

Without the rclone config, the deploy will finish (all services configured) but **the site will not be restored**.
The deploy will fail at the final health check with "HTTP 403 — site not serving".

You can also deploy without restore support and restore later:

```bash
./deploy.sh <target> -n -i <server-ip>
```

after setting up the rclone config manually on the server.

## Pre-commit hooks (recommended)

```bash
uv tool install pre-commit
pre-commit install
```

Runs on every commit: YAML lint, large file check, secret detection, private key guard.

## Linting / CI (optional, for local checks)

```bash
# Shell
brew install shellcheck

# Bash unit tests (bats-core)
brew install bats-core   # or: npm install -g bats@1.13.0

# Python
uv tool install ruff

# Ansible (pinned version matching CI)
uv pip install --require-hashes -r ansible/requirements-deploy.txt

# Terraform
brew install tflint
brew install trivy

# Secrets
brew install gitleaks
```

Install the Python test/type dependencies (hash-pinned, the same file CI uses) and run the suites:

```bash
make deps        # creates .venv and installs ci/requirements.txt (pytest, mypy, pytest-cov)
make test        # unit tests + coverage floor (same command as CI)
make types       # mypy over scripts/, lib/, actions, codemap and tests
make test-bash   # shell helpers (bats)
make test-env    # .env parser contract + differential fuzz
```

`make test` without `make deps` falls back to `python3` — that only works if pytest, pyyaml and
jinja2 are already installed globally, which is why the fresh-clone path is `make deps` first.

## Secrets setup

```bash
cp .env.example secrets/.env
# edit secrets/.env with your values
```

See `.env.example` for the full list of variables.
