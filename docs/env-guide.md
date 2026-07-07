# Environment Variables Guide

How to obtain and use every variable in `secrets/.env` and `.env.example`.

---

## Cloudflare

Two authentication methods exist:

### API Token (Bearer) — for Ansible/CI

```
CLOUDFLARE_API_TOKEN  →  Authorization: Bearer <token>
```

Where to get: https://dash.cloudflare.com/profile/api-tokens → Create Token

Required permissions: `DNS:Edit`, `Cache Settings Read/Write`, `Zone:Read`, `Account Rulesets Read`.

Used by: `deploy.sh`, Ansible role `ssl`, Terraform.

### Global API Key — for admin tasks

```
CLOUDFLARE_EMAIL      →  X-Auth-Email: <email>
CLOUDFLARE_GLOBAL_KEY →  X-Auth-Key: <key>
```

Where to get: same page, scroll to "Global API Key".

Full account access (like password). Use it to create/modify API Tokens via API when the dashboard is unavailable.

Example — create a scoped API Token:

```bash
curl -X POST "https://api.cloudflare.com/client/v4/user/tokens" \
  -H "X-Auth-Email: $CLOUDFLARE_EMAIL" \
  -H "X-Auth-Key: $CLOUDFLARE_GLOBAL_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "my-ci-token",
    "policies": [
      {
        "effect": "allow",
        "resources": {"com.cloudflare.api.account.zone.*": "*"},
        "permission_groups": [
          {"id": "c8fed203ed3043cba015a93ad1616f1f"},  # Zone Read
          {"id": "4755a26eedb94da69e1066d98aa820be"},  # DNS Write
          {"id": "3245da1cf36c45c3847bb9b483c62f97"},  # Cache Settings Read
          {"id": "9ff81cbbe65c400b97d92c3c1033cab6"}   # Cache Settings Write
        ]
      },
      {
        "effect": "allow",
        "resources": {"com.cloudflare.api.account.*": "*"},
        "permission_groups": [
          {"id": "fb39996ee9044d2a8725921e02744b39"}   # Account Rulesets Read
        ]
      }
    ]
  }'
```

List all permission group IDs:

```bash
curl -s -H "X-Auth-Email: $CLOUDFLARE_EMAIL" \
  -H "X-Auth-Key: $CLOUDFLARE_GLOBAL_KEY" \
  "https://api.cloudflare.com/client/v4/accounts/<ACCOUNT_ID>/tokens/permission_groups"
```

### Which one to use

| Situation | Use |
|-----------|-----|
| Ansible/CI deploy | `CLOUDFLARE_API_TOKEN` (Bearer) |
| One-off token management | `CLOUDFLARE_GLOBAL_KEY` (X-Auth-Key) |
| Regular admin scripts | Create a dedicated API Token instead |

---

## Grafana Cloud

Three separate stacks exist:

- **prod** — `dreamseed.grafana.net` (org id 1)
- **dev** — `vitalikuts.grafana.net` (org id 2, shared by dev-aws + dev-hetz)

### Push URL (vmagent)

```
PROD_GRAFANA_CLOUD_URL="https://prometheus-prod-56-prod-us-east-2.grafana.net"
DEV_GRAFANA_CLOUD_URL="https://prometheus-prod-39-prod-eu-north-0.grafana.net"
```

Where to get: Grafana Cloud Portal → Stack → Details → "Prometheus URL".

**This is the Prometheus remote_write endpoint (regional).** NOT the vanity URL like `dreamseed.grafana.net`. Do NOT append `/api/prom/push` — the Ansible template adds it.

### Username (instance ID)

```
PROD_GRAFANA_CLOUD_USERNAME="3270028"
DEV_GRAFANA_CLOUD_USERNAME="3270040"
```

7-digit numeric Prometheus instance ID, shown next to the URL in the Portal.

### Token types

Two different token types exist. Do not confuse them:

| Prefix | Type | Purpose | Where to get |
|--------|------|---------|-------------|
| `glc_` | Cloud Access Policy (CAP) | vmagent remote_write (metrics push) | Grafana Cloud Portal → "Password / API Key" → scope `metrics:write` |
| `glsa_` | Service Account (SA) | Terraform Grafana provider (dashboards, alerts) | Grafana UI → Administration → Service Accounts → role Admin |

The variables follow this naming:

```
PROD_GRAFANA_CLOUD_TOKEN      → glc_*  (vmagent push)
PROD_GRAFANA_CLOUD_SA_TOKEN   → glsa_* (Terraform)
DEV_GRAFANA_CLOUD_TOKEN       → glc_*  (vmagent push)
DEV_GRAFANA_CLOUD_SA_TOKEN    → glsa_* (Terraform)
```

### Synthetic Monitoring

Optional per-target:

```
PROD_SM_ACCESS_TOKEN
DEV_SM_ACCESS_TOKEN
```

Enable SM once in Grafana Cloud UI (Stack → SM → Enable), then generate an API token with SM scope in the same page.

---

## SSH Keys

```
SSH_PUBLIC_KEY_PATH="$HOME/.ssh/Vitali.pub"
SSH_PRIVATE_KEY_PATH="$HOME/.ssh/Vitali.pem"
```

These point to local files, not stored in secrets. The deploy key (`SSH_PRIVATE_KEY_PATH`) is always included in cloud-init.

Additional public keys go into `ADDITIONAL_SSH_KEYS` (one per line, as a single string) and are injected into all servers.

GitHub Actions receives the private key via `SSH_PRIVATE_KEY` secret.

---

## Better Uptime (heartbeats)

Each backup/upload/report script pings a unique heartbeat URL on success:

| Variable | Script |
|----------|--------|
| `BETTERUPTIME_BACKUP_KEY` | `smart_backup.sh` |
| `BETTERUPTIME_GDRIVE_KEY` | `upload_backups_to_gdrive.sh` |
| `BETTERUPTIME_REPORT_DAILY_KEY` | `send_report.sh daily` |
| `BETTERUPTIME_REPORT_WEEKLY_KEY` | `send_report.sh weekly` |
| `BETTERUPTIME_VERIFY_KEY` | `verify_backups.sh` |
| `BETTERUPTIME_CHECK_SERVICES_KEY` | `check_services.sh` |

Where to get: https://uptime.betterstack.com → Heartbeats → create → copy the UUID at the end of the URL.

---

## EIP (Elastic IP)

```
PROD_EIP="eipalloc-06635bbf8eda30850"
DEV_AWS_EIP="eipalloc-079557035c55028d6"
```

Set to the allocation ID to attach a specific Elastic IP. Set to any non-empty value to disable auto-public-IP allocation in Terraform (use when managing EIP outside TF).

---

## Legacy

The following variables are no longer used but kept for reference:

| Variable | Notes |
|----------|-------|
| `HEALTHCHECKS_API_KEY` | Migrated to Better Stack |
| `HEALTHCHECK_BACKUP_UUID` | Migrated |
| `HEALTHCHECK_GDRIVE_UUID` | Migrated |
| `HEALTHCHECK_REPORT_DAILY_UUID` | Migrated |
| `HEALTHCHECK_REPORT_WEEKLY_UUID` | Migrated |
| `HCLOUD_TOKEN` / `HETZNER_*` (unprefixed) | Fallback if `DEV_HETZ_*` / `PROD_HETZ_*` are empty |
