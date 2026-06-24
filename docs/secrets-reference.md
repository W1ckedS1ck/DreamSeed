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
| `SSH_PRIVATE_KEY` | Deploy SSH key (Ansible) | `deploy.yml`, `test-restore.yml`, `health-check.yml`, `rollback.yml` |
| `VAULT_PASSWORD` | Ansible-vault password | `deploy.yml`, `test-restore.yml`, `rollback.yml` |
| `TF_API_TOKEN` | Terraform Cloud API token | All workflows except `ci.yml` |
| `RCLONE_CONF_BASE64` | Rclone config for Google Drive (backups) | `deploy.yml`, `test-restore.yml` |
| `BETTERUPTIME_API_TOKEN` | Better Stack API (heartbeats) | `deploy.yml` |

---

## SSH keys

| Secret | Purpose | Used in |
|--------|---------|---------|
| `SSH_PRIVATE_KEY` | Deploy key (Ansible) | See above |
| `USER_SSH_PUBLIC_KEY` | Developer's public key → `ADDITIONAL_SSH_KEYS` | `deploy.yml` |
| `VITALI_SSH_PUBLIC_KEY` | Vitali's public key → `ADDITIONAL_SSH_KEYS` + AWS prod Terraform | `deploy.yml`, `terraform-apply.yml` |
| `DEV_AWS_SSH_PUBLIC_KEY` | Public key for AWS dev Terraform | `terraform-apply.yml` |

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
| `HCLOUD_TOKEN` | dev-hetz | Hetzner Cloud API token | `deploy.yml`, `test-restore.yml`, `terraform-apply.yml` |
| `PROD_HETZ_HCLOUD_TOKEN` | prod-hetz | Hetzner Cloud API token | `deploy.yml`, `drift-detection.yml`, `terraform-apply.yml` |

---

## Grafana Cloud

| Secret | Env | Purpose | Used in |
|--------|-----|---------|---------|
| `DEV_GRAFANA_CLOUD_URL` | dev | Push URL for vmagent | `deploy.yml`, `test-restore.yml`, `grafana-cloud.yml` |
| `DEV_GRAFANA_CLOUD_USERNAME` | dev | vmagent username | `deploy.yml`, `test-restore.yml` |
| `DEV_GRAFANA_CLOUD_TOKEN` | dev | vmagent API token | `deploy.yml`, `test-restore.yml` |
| `DEV_GRAFANA_CLOUD_SA_TOKEN` | dev | Service Account token (Terraform) | `grafana-cloud.yml` |
| `DEV_SM_ACCESS_TOKEN` | dev | Synthetic Monitoring token | `grafana-cloud.yml` |
| `PROD_GRAFANA_CLOUD_URL` | prod | Push URL for vmagent | `deploy.yml`, `test-restore.yml`, `grafana-cloud.yml` |
| `PROD_GRAFANA_CLOUD_USERNAME` | prod | vmagent username | `deploy.yml`, `test-restore.yml` |
| `PROD_GRAFANA_CLOUD_TOKEN` | prod | vmagent API + SA token | `deploy.yml`, `test-restore.yml`, `grafana-cloud.yml` |
| `PROD_SM_ACCESS_TOKEN` | prod | Synthetic Monitoring token | `grafana-cloud.yml` |

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

---

## Legacy (unused — safe to delete)

| Secret | Notes |
|--------|-------|
| `INFRACOST_API_KEY` | Infracost API key, not referenced in any workflow |
| `TESTHETZ_HCLOUD_TOKEN` | Hetzner Cloud token for non-existent `test-bench.yml` |
| `TESTHETZ_SSH_KEY` | SSH key for non-existent `test-bench.yml` |
