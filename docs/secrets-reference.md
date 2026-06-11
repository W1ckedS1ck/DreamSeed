# GitHub Secrets Reference

Complete inventory of all GitHub Secrets in the [`DreamSeed`](https://github.com/W1ckedS1ck/DreamSeed) repository, their purpose, and where they are consumed.

---

## Required (all targets)

| Secret | Purpose | Source | Used in |
|--------|---------|--------|---------|
| `TG_TOKEN` | Telegram bot token | BotFather | `deploy.yml`, `backup-test.yml`, `rollback.yml`, ansible (telegram-bot), scripts |
| `TG_CHAT_ID` | Telegram chat ID | BotFather | Same |
| `TG_THREAD_ID` | Telegram thread (forum topic) | BotFather | Same |
| `DB_PASS` | MySQL password for MODX | You | `deploy.sh`, ansible (mariadb), scripts |
| `GRAFANA_PASS` | Grafana admin password | You | `deploy.sh`, ansible (grafana) |
| `CLOUDFLARE_API_TOKEN` | Cloudflare API (DNS-01 certbot + auto DNS update) | Cloudflare Dashboard | `deploy.sh`, `backup-test.yml`, ansible (certbot) |
| `SSH_PRIVATE_KEY` | Deploy SSH key (Ansible + git push) | `~/.ssh/github` | `deploy.yml`, `backup-test.yml`, `rollback.yml`, `deploy.sh` |
| `VAULT_PASSWORD` | ansible-vault password | You | `deploy.yml`, `backup-test.yml`, `rollback.yml`, `deploy.sh` |
| `TF_API_TOKEN` | Terraform Cloud API token | Terraform Cloud → Tokens | `deploy.yml`, `rollback.yml`, `backup-test.yml` |
| `RCLONE_CONF_BASE64` | Rclone config for Google Drive (backups) | `rclone config file` → base64 | `deploy.yml`, `backup-test.yml`, `deploy.sh` |
| `BETTERUPTIME_API_TOKEN` | Better Stack API (heartbeats) | Better Stack → Settings → API | `deploy.yml`, server scripts |

---

## SSH keys

| Secret | Purpose | Source | Used in |
|--------|---------|--------|---------|
| `SSH_PRIVATE_KEY` | Deploy key (Ansible + git push via `~/.ssh/github`) | `~/.ssh/github` pair | All deploys |
| `USER_SSH_PUBLIC_KEY` | Developer's public key | GitHub → Settings → SSH Keys | `deploy.yml` → `ADDITIONAL_SSH_KEYS` |
| `VITALI_SSH_PUBLIC_KEY` | Vitali's public key | `~/.ssh/Vitali.pub` | `deploy.yml` → `ADDITIONAL_SSH_KEYS` |
| `TESTHETZ_SSH_KEY` | Private key for GeekBench test server | You | `test-bench.yml` |
| `DEV_AWS_SSH_PUBLIC_KEY` | Public key for AWS dev (drift detection) | You | `drift-detection.yml` |

---

## AWS (prod)

| Secret | Purpose | Used in |
|--------|---------|---------|
| `PROD_ACCESS_KEY` | AWS Access Key | `deploy.yml`, `lib/env.sh`, `rollback.yml` |
| `PROD_SECRET_KEY` | AWS Secret Key | Same |
| `PROD_REGION` | AWS region (`us-west-1`) | Same |
| `PROD_EIP` | Elastic IP allocation ID (`eipalloc-xxx`) | Same |

## AWS (dev-aws)

| Secret | Purpose | Used in |
|--------|---------|---------|
| `DEV_AWS_ACCESS_KEY` | AWS Access Key | `deploy.yml`, `lib/env.sh`, `rollback.yml` |
| `DEV_AWS_SECRET_KEY` | AWS Secret Key | Same |
| `DEV_AWS_REGION` | AWS region (`us-west-1`) | Same |
| `DEV_AWS_EIP` | Elastic IP allocation ID | Same |

---

## Hetzner (dev-hetz)

| Secret | Purpose | Used in |
|--------|---------|---------|
| `HCLOUD_TOKEN` | Hetzner Cloud API token | `deploy.sh`, `lib/env.sh`, `backup-test.yml` |

## Hetzner (prod-hetz)

| Secret | Purpose | Used in |
|--------|---------|---------|
| `PROD_HETZ_HCLOUD_TOKEN` | Hetzner Cloud API token (new account) | `deploy.yml`, `lib/env.sh` |

## Hetzner (testhetz — GeekBench)

| Secret | Purpose | Used in |
|--------|---------|---------|
| `TESTHETZ_HCLOUD_TOKEN` | Hetzner Cloud API token (test account) | `test-bench.yml` |

---

## Grafana Cloud

| Secret | Env | Purpose | Used in |
|--------|-----|---------|---------|
| `PROD_GRAFANA_CLOUD_URL` | prod | Push URL for vmagent | `deploy.yml`, `backup-test.yml`, `grafana-cloud.yml` |
| `PROD_GRAFANA_CLOUD_USERNAME` | prod | vmagent username | `deploy.yml`, `backup-test.yml` |
| `PROD_GRAFANA_CLOUD_TOKEN` | prod | vmagent API token | `deploy.yml`, `backup-test.yml` |
| `PROD_GRAFANA_CLOUD_SA_TOKEN` | prod | Service Account token (Terraform) | `grafana-cloud.yml` |
| `PROD_SM_ACCESS_TOKEN` | prod | Synthetic Monitoring token | `grafana-cloud.yml` |
| `DEV_GRAFANA_CLOUD_PUSH_URL` | dev | Push URL for vmagent | `deploy.yml`, `backup-test.yml` |
| `DEV_GRAFANA_CLOUD_URL` | dev | Alias for PUSH_URL | Same |
| `DEV_GRAFANA_CLOUD_USERNAME` | dev | vmagent username | `deploy.yml`, `backup-test.yml` |
| `DEV_GRAFANA_CLOUD_TOKEN` | dev | vmagent API token | `deploy.yml`, `backup-test.yml` |
| `DEV_GRAFANA_CLOUD_SA_TOKEN` | dev | Service Account token (Terraform) | `grafana-cloud.yml` |
| `DEV_SM_ACCESS_TOKEN` | dev | Synthetic Monitoring token | `grafana-cloud.yml` |

---

## Legacy (unused — safe to delete)

| Secret | Created | Notes |
|--------|---------|-------|
| `ENV_FILE_BASE` | 2026-05-18 | Not referenced anywhere |
| `ENV_FILE_BASE64` | 2026-05-30 | Not referenced anywhere |
| `TEST_PASS` | 2026-06-03 | Not referenced anywhere |
| `TEST_USER` | 2026-06-03 | Not referenced anywhere |
| `INFRACOST_API_KEY` | 2026-05-20 | Not referenced anywhere |
| `INFRACOST_CLI_AUTHENTICATION_TOKEN` | 2026-05-15 | Not referenced anywhere |
| `PROD_SSH_PUBLIC_KEY` | 2026-05-08 | Not referenced anywhere |
