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

### Firewall Token (fail2ban edge bans)

```
CLOUDFLARE_FIREWALL_TOKEN  →  Authorization: Bearer <token> (CF API v4)
```

Scoped API token with **`Zone → Firewall Services → Edit`** (zone-scoped to the target's zone). Used by the `security` Ansible role: fail2ban web jails ban offending IPs **at the Cloudflare edge** via the `cloudflare-token` action. Empty value = web jails are log-only (no bans). Zone ID is resolved automatically from the target domain at deploy time.

### Master account (email + Global API Key) — admin/emergency only

**What it is:** `CLOUDFLARE_EMAIL` + `CLOUDFLARE_GLOBAL_KEY` — the account master credential, **equivalent to the account password** (full access to everything: zones, DNS, WAF, tokens, billing-adjacent APIs).

```
CLOUDFLARE_EMAIL      →  X-Auth-Email: <email>
CLOUDFLARE_GLOBAL_KEY →  X-Auth-Key: <key>
```

Where to get: Cloudflare Dashboard → My Profile → API Tokens → "Global API Key" (reveal with account password).

Stored in: `secrets/.env` (ansible-vault). **Never** in CI, workflows, or on servers.

**Security posture:**

- Used **only** to bootstrap/manage *scoped* API tokens (least privilege) — never directly by any code, workflow, or server.
- One leaked Global Key = full Cloudflare account takeover (DNS hijack, domain theft). Treat it like the account password; rotate immediately on any doubt.
- All automation must use scoped Bearer tokens (like `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_FIREWALL_TOKEN`).

**Shell usage (token stays out of argv/ps):**

```bash
# reads keys from the vault, auth via curl --config (never -H in argv)
EMAIL=$(ansible-vault view secrets/.env --vault-password-file ~/.vault_pass_dreamseed | grep '^CLOUDFLARE_EMAIL=' | cut -d= -f2- | tr -d '"')
KEY=$(ansible-vault view secrets/.env --vault-password-file ~/.vault_pass_dreamseed | grep '^CLOUDFLARE_GLOBAL_KEY=' | cut -d= -f2- | tr -d '"')
AUTH="header = \"X-Auth-Email: $EMAIL\"\nheader = \"X-Auth-Key: $KEY\"\nheader = \"Content-Type: application/json\"\n"
curl -s --config <(printf "$AUTH") "https://api.cloudflare.com/client/v4/accounts"
```

**Workflow — master creates a scoped token (the pattern used for the fail2ban firewall token):**

1. Find your **account ID**:

   ```bash
   curl -s --config <(printf "$AUTH") "https://api.cloudflare.com/client/v4/accounts" | jq -r '.result[0].id'
   ```

2. Find the **permission group ID** you need (zone scope = `com.cloudflare.api.account.zone`):

   ```bash
   curl -s --config <(printf "$AUTH") "https://api.cloudflare.com/client/v4/accounts/<ACCOUNT_ID>/tokens/permission_groups?per_page=200" \
     | jq -r '.result[] | select(.name | test("Firewall Services")) | "\(.id)  \(.name)"'
   ```

3. Create a scoped token (zone-level resources only):

   ```bash
   curl -s -X POST --config <(printf "$AUTH") "https://api.cloudflare.com/client/v4/user/tokens" \
     -d '{
       "name": "dreamseed-something (one purpose)",
       "status": "active",
       "policies": [{
         "effect": "allow",
         "resources": {"com.cloudflare.api.account.zone.<ZONE_ID>": "*"},
         "permission_groups": [{"id": "<PERMISSION_GROUP_ID>", "effect": "allow"}]
       }]
     }'
   ```

   The token value is returned **once** — capture it immediately (0600 file), add to `secrets/.env` via `ansible-vault edit`.

4. **To extend a token to more zones** (resources), `PUT /user/tokens/<id>` with the same policy + an extra zone resource. The token *value* does not change.

Known permission group IDs (vitalikuts.online account, zone scope):

| ID | Permission |
|----|-----------|
| `43137f8d07884d3198dc0ee77ca6e79b` | Firewall Services **Write** |
| `4ec32dfcb35641c5bb32d5ef1ab963b4` | Firewall Services Read |
| `c8fed203ed3043cba015a93ad1616f1f` | Zone Read |
| `4755a26eedb94da69e1066d98aa820be` | DNS Write |

**Rotating the Global API Key:** Dashboard → My Profile → API Tokens → Global API Key → Roll. Update `secrets/.env` afterwards.

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

> **Note:** These URLs are per-region and may change if the Grafana Cloud stack is migrated or recreated. Always verify the current URL in Grafana Cloud Portal → Stack → Details → "Prometheus URL".

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

## Better Stack (heartbeats)

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

## Frontend Observability (Faro RUM)

Set per-target as GitHub Variables (not secrets):

| Variable | Value (dev) | Value (prod) |
|----------|------------|-------------|
| `FARO_COLLECTOR_URL` | `https://faro-collector-prod-eu-north-0.grafana.net/collect/<app_id>` | `https://faro-collector-prod-us-east-2.grafana.net/collect/<app_id>` |
| `FARO_APP_NAME` | *(auto = domain)* | *(auto = domain)* |

---

## Rclone Crypt (backup encryption)

Password for the rclone crypt remote, used for AES-256 encryption of backups at rest.

```
RCLONE_CRYPT_PASSWORD
```

Stored in `secrets/.env` and GitHub Secrets. Without it, encrypted backups on Google Drive cannot be decrypted.

---

## Redis

Redis is used by MODX for session storage and caching. Configured in `ansible-roles/redis`.

```
REDIS_PASSWORD=<password>
```

Defaults to empty (no auth) if not set. Stored in `secrets/.env`.

## Grafana Cloud Logs (Loki)

Set per-target as GitHub Variables (not secrets):

| Variable | Value (dev) | Value (prod) |
|----------|------------|-------------|
| `LOKI_URL` | `https://logs-prod-025.grafana.net/loki/api/v1/push` | `https://logs-prod-036.grafana.net/loki/api/v1/push` |
| `LOKI_USERNAME` | `1630695` | `1630689` |

Password is the same Access Policy token as vmagent (`grafana_cloud_token`).

---

## EIP (Elastic IP)

Used for prod (AWS) and dev-aws to attach pre-allocated Elastic IP.

```
# PROD_EIP="eipalloc-xxx"     # Real allocation ID = attach this EIP
# DEV_AWS_EIP="eipalloc-xxx"
```

Set to an allocation ID to attach a specific Elastic IP. Set to any non-empty value (e.g. `"true"`) to disable auto-public-IP allocation in Terraform (use when managing EIP outside TF).

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
