# GitHub Secrets Reference

Complete inventory of all GitHub Secrets in the [`DreamSeed`](https://github.com/W1ckedS1ck/DreamSeed) repository.

---

## Required (all targets)

| Secret / Var | Purpose | Used in |
|-------------|---------|---------|
| `TG_TOKEN` | Telegram bot token | `deploy.yml`, `test-restore.yml`, `health-check.yml`, `rollback.yml`, `drift-detection.yml` |
| `TG_CHAT_ID` (var) | Telegram chat ID | `deploy.yml`, `test-restore.yml`, `health-check.yml`, `rollback.yml`, `drift-detection.yml` |
| `TG_THREAD_ID` (var) | Telegram thread/topic ID | Same |
| `DB_PASS` | MySQL password for MODX | `deploy.yml`, `test-restore.yml` |
| `GRAFANA_PASS` | Grafana admin password | `deploy.yml`, `test-restore.yml` |
| `CLOUDFLARE_API_TOKEN` | Cloudflare API (DNS certbot + auto DNS update) | `deploy.yml`, `test-restore.yml` |
| `CLOUDFLARE_FIREWALL_TOKEN` | Cloudflare API (fail2ban edge bans, `Zone → Firewall Services → Edit`) | `deploy.yml`, `test-restore.yml` → `security` role |
| `SSH_PRIVATE_KEY` | Deploy SSH key (Ansible) | `deploy.yml`, `test-restore.yml`, `health-check.yml`, `rollback.yml`, `ci.yml` |
| `VAULT_PASSWORD` | Ansible-vault password | `deploy.yml`, `test-restore.yml`, `rollback.yml`, `ci.yml` |
| `TF_API_TOKEN` | Terraform Cloud API token | All workflows except `ci.yml`, `chatops-deploy.yml`, `docs.yml` |
| `RCLONE_CONF_BASE64` | Rclone config for Google Drive (backups) | `deploy.yml`, `test-restore.yml` |
| `RCLONE_CRYPT_PASSWORD` | Password for `gdrive-crypt` encrypted remote (AES-256) | `deploy.yml` → `rclone_config.yml` |
| `BETTERUPTIME_API_TOKEN` | Better Stack API (heartbeats) | `deploy.yml` |
| `UBUNTU_PRO_TOKEN` | Ubuntu Pro subscription token | `deploy.yml`, `setup-env` → Ansible (playbook-01) — not in Terraform/cloud-init |
| `EMAIL_USER` | SMTP username for mail.privateemail.com | `deploy.yml` → server .env |
| `EMAIL_PASS` | SMTP password | `deploy.yml` → server .env |
| `SMTP_SERVER` | SMTP host | `deploy.yml` → server .env |
| `SMTP_PORT` | SMTP port (587) | `deploy.yml` → server .env |

---

## GitHub Variables (not Secrets)

These are set as GitHub Actions **Variables**, not Secrets. They are not sensitive and visible in plain text.

| Variable | Purpose | Used in |
|----------|---------|---------|
| `FARO_COLLECTOR_URL` | Grafana Faro collector URL for frontend telemetry | `deploy.yml` |
| `FARO_APP_NAME` | Grafana Faro application name | `deploy.yml` |
| `LOKI_URL` | Loki push endpoint for log shipping | `deploy.yml` |
| `LOKI_USERNAME` | Loki username (numeric instance ID) | `deploy.yml` |

---

## SSH keys

| Secret | Purpose | Used in |
|--------|---------|---------|
| `SSH_PRIVATE_KEY` | Deploy key (Ansible) | See above |
| `USER_SSH_PUBLIC_KEY` | Developer's public key → `ADDITIONAL_SSH_KEYS` | `deploy.yml` |
| `VITALI_SSH_PUBLIC_KEY` | Vitali's public key → `ADDITIONAL_SSH_KEYS` + AWS prod Terraform | `deploy.yml`, `terraform-apply.yml` |

---

## AWS

### prod

| Secret | Purpose | Used in |
|--------|---------|---------|
| `PROD_ACCESS_KEY` | AWS Access Key | `deploy.yml`, `health-check.yml`, `rollback.yml`, `terraform-apply.yml` |
| `PROD_SECRET_KEY` | AWS Secret Key | Same |
| `PROD_REGION` | AWS region (`us-west-1`) | Same |
| `PROD_EIP` | Elastic IP allocation ID (`eipalloc-xxx`) | Same |

### dev-aws

| Secret | Purpose | Used in |
|--------|---------|---------|
| `DEV_AWS_ACCESS_KEY` | AWS Access Key | `deploy.yml`, `health-check.yml`, `rollback.yml`, `terraform-apply.yml` |
| `DEV_AWS_SECRET_KEY` | AWS Secret Key | Same |
| `DEV_AWS_REGION` | AWS region (`us-west-1`) | Same |
| `DEV_AWS_EIP` | Elastic IP allocation ID | Same |

---

## Hetzner

| Secret | Target | Purpose | Used in |
|--------|--------|---------|---------|
| `HCLOUD_TOKEN` | dev-hetz | Hetzner Cloud API token | `deploy.yml`, `test-restore.yml`, `terraform-apply.yml`, `ci.yml` |
| `PROD_HETZ_HCLOUD_TOKEN` | prod-hetz | Hetzner Cloud API token | `deploy.yml`, `drift-detection.yml`, `terraform-apply.yml` |

---

## Grafana Cloud

### Prometheus remote_write (vmagent → hosted metrics)

The URL points to the Prometheus endpoint, **not** the Grafana instance.

| Secret | Env | Purpose | Used in |
|--------|-----|---------|---------|
| `DEV_GRAFANA_CLOUD_URL` | dev | Prometheus remote_write endpoint (e.g. `prometheus-prod-39-prod-eu-north-0.grafana.net`) | `deploy.yml`, `test-restore.yml` |
| `DEV_GRAFANA_CLOUD_USERNAME` | dev | vmagent username (numeric instance ID) | `deploy.yml`, `test-restore.yml` |
| `DEV_GRAFANA_CLOUD_TOKEN` | dev | Cloud Access Policy token for vmagent (`glc_*`, scope=metrics:write) | `deploy.yml`, `test-restore.yml` |
| `PROD_GRAFANA_CLOUD_URL` | prod | Prometheus remote_write endpoint | `deploy.yml`, `test-restore.yml` |
| `PROD_GRAFANA_CLOUD_USERNAME` | prod | vmagent username (numeric instance ID) | `deploy.yml`, `test-restore.yml` |
| `PROD_GRAFANA_CLOUD_TOKEN` | prod | Cloud Access Policy token for vmagent (`glc_*`, scope=metrics:write) | `deploy.yml`, `test-restore.yml` |

### Terraform (Grafana API — dashboards, folders, SM)

Uses the Grafana **instance** URL (`*.grafana.net`), NOT the Prometheus endpoint.
Instance URL is hardcoded in `grafana-cloud.yml`, not stored in secrets.

| Secret | Env | Purpose | Used in |
|--------|-----|---------|---------|
| `DEV_GRAFANA_CLOUD_SA_TOKEN` | dev | Service Account token for Terraform (`glsa_*`, role=Admin) | `grafana-cloud.yml` |
| `PROD_GRAFANA_CLOUD_SA_TOKEN` | prod | Service Account token for Terraform | `grafana-cloud.yml` |
| `PROD_GRAFANA_CLOUD_TOKEN` | prod | Fallback if SA_TOKEN is empty | `grafana-cloud.yml` |
| `DEV_SM_ACCESS_TOKEN` | dev | Synthetic Monitoring token | `grafana-cloud.yml` |
| `PROD_SM_ACCESS_TOKEN` | prod | Synthetic Monitoring token | `grafana-cloud.yml` |

> **Note:** Grafana instance URLs are `https://vitalikuts.grafana.net` (dev) and `https://dreamseed.grafana.net` (prod).
> These are public, not secrets — hardcoded in `grafana-cloud.yml`.
> Prometheus endpoints are per-region and found in Grafana Cloud → Stack → Prometheus → Remote Write Endpoint.

---

## Better Uptime (heartbeats)

All set in `deploy.yml` and consumed by the respective server scripts.

| Secret | Script |
|--------|--------|
| `BETTERUPTIME_BACKUP_KEY` | `smart_backup.sh` |
| `BETTERUPTIME_GDRIVE_KEY` | `upload_backups_to_gdrive.sh` |
| `BETTERUPTIME_REPORT_DAILY_KEY` | `send_report.sh` (daily) |
| `BETTERUPTIME_REPORT_WEEKLY_KEY` | `send_report.sh` (weekly) |
| `BETTERUPTIME_VERIFY_KEY` | `verify_backups.sh` |
| `BETTERUPTIME_CHECK_SERVICES_KEY` | `check_services.sh` |

---

## Backup

| Item | Notes |
|------|-------|
| Remote | `gdrive-crypt` (AES-256 encrypted) — used instead of plain `gdrive:` for new backups |
| Rclone config | `RCLONE_CONF_BASE64` — base64-encoded rclone config file |
| Crypt password | `RCLONE_CRYPT_PASSWORD` — password for the `gdrive-crypt` encrypted remote |

The `gdrive-crypt` remote wraps the base `gdrive:` remote with rclone crypt (AES-256). All new backups are pushed to the encrypted remote. The crypt password is consumed by Ansible `rclone_config.yml` during deploy.

---

## Legacy (unused — safe to delete)

| Secret | Notes |
|--------|-------|
| `INFRACOST_API_KEY` | Infracost API key, not referenced in any workflow |
| `TESTHETZ_HCLOUD_TOKEN` | Hetzner Cloud token for non-existent `test-bench.yml` |
| `TESTHETZ_SSH_KEY` | SSH key for non-existent `test-bench.yml` |
| `DEV_AWS_SSH_PUBLIC_KEY` | Not referenced in any workflow (AWS dev uses `VITALI_SSH_PUBLIC_KEY`) |
