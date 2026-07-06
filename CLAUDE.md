# CLAUDE.md — DreamSeed Internal Reference

> Gitignored. Persists project context across AI sessions.
> Always verify against live files before acting on any fact here.

---

## 1. Quick reference

## ⚠️ CRITICAL RULE: Deploy & destroy ONLY via GitHub Actions

**Never run `./deploy.sh dev-aws -x` or any destroy/deploy locally.** Use the GitHub Actions UI:

- [Deploy workflow](https://github.com/W1ckedS1ck/DreamSeed/actions/workflows/deploy.yml) — "Run workflow" → choose target + web server
- Local `deploy.sh` is for: lint, dry-run, log tailing, single playbook debug ONLY.

| Goal | How |
|------|------|
| Deploy any target | GitHub Actions → Deploy workflow |
| Destroy any target | GitHub Actions → Deploy workflow (check "Destroy") + confirm `destroy dev` (dev) or `destroy prod` (prod) |
| Destroy via CLI | `gh workflow run deploy.yml --ref dev -f environment=dev-hetz -f action=destroy -f confirm="destroy dev"` (или `dev-aws`, confirm одинаковый) |
| Redeploy config only | GitHub Actions → Deploy workflow (check "Skip Terraform" + enter existing IP) |
| Dry run | `./deploy.sh prod -n --dry-run` |
| Tail latest deploy log | `./deploy.sh --logs` |
| Tail terraform log | `./deploy.sh --logs tf` |
| Run single playbook (debug) | `cd ansible && ansible-playbook -i inventory/hosts-prod.yml playbook-03-db.yml -e @<(echo "db_pass: xxx")` |
| Lint all locally | `./deploy.sh --lint` or `bash scripts/lint.sh --fast` |
| Secrets audit | `bash scripts/lint.sh --secrets` |
| View local secrets | `ansible-vault view secrets/.env` |
| Edit local secrets | `ansible-vault edit secrets/.env` |
| Recent commits | `git log --oneline -10` |
| Current changes | `git status --short` |
| Last commit diff | `git diff HEAD~1..HEAD --stat` |
| SSH to prod | `ssh -i ~/.ssh/deploy_key ubuntu@dreamseed.online` (alias: `ssh dream`) |
| SSH to dev (IP changes) | `ssh -i ~/.ssh/deploy_key ubuntu@<ip>` — same key as prod |
| Always add `-o LogLevel=ERROR` to SSH | Suppresses auth banner noise; real errors still visible |

Remote: `git@github.com:W1ckedS1ck/DreamSeed.git` (public repo)

> **View local secrets:** `ansible-vault view secrets/.env`
> **Edit local secrets:** `ansible-vault edit secrets/.env`
> Plain-text backup (read-only, outside project): `~/Documents/DreamSeed/env.clear`

---

## 2. What this project IS

**DreamSeed** is an Infrastructure-as-Code project — **Terraform + Ansible** — that deploys a production MODX CMS stack (web + DB + monitoring + backup + security) to either AWS EC2 or Hetzner Cloud, from one command, in ~15 minutes.

Backs the real product at **dreamseed.online** — a social experiment (Wheel of Life questionnaire, virtual bonsai, $1.99 dream pledges). **Vitali Kuts (Co-founder & CTO) owns infrastructure**: provisioning, config, SSL, backups, monitoring, security, DR.

Repo is public for LinkedIn/portfolio — **all in-repo documentation must stay in English**.

### Target environments

| Target     | Cloud    | Region    | Domain                  | TF workspace |
|------------|----------|-----------|-------------------------|--------------|
| `prod`     | AWS EC2  | `us-west-1` | `dreamseed.online`    | `prod`       |
| `prod-hetz`| Hetzner  | `nbg1`    | `dreamseed.online`      | `prod-hetz`  |
| `dev-aws`  | AWS EC2  | `us-west-1` | `aws.vitalikuts.online`| `dev-aws`    |
| `dev-hetz` | Hetzner  | `nbg1`    | `hetz.vitalikuts.online`| `dev-hetz`   |

**Hetzner project IDs:** dev → `13198073`, prod → `14920160`

---

## 3. Repo layout

```
DreamSeed/
├── deploy.sh                   # Orchestrator (~500 lines, lib/ for modules)
├── lib/                        # Deploy modules: env.sh, helpers.sh, preflight.sh, terraform.sh, ansible.sh
│
├── terraform/
│   ├── aws/main.tf             # EC2 + SG + key_pair + optional Elastic IP
│   ├── hetzner/main.tf         # hcloud_server cx23 + firewall + Primary IP
│   ├── cloudflare/             # WAF Managed Ruleset + Cache rules (Cloudflare provider)
│   └── grafana/                # Synthetic Monitoring (Grafana Cloud provider)
│
├── ansible/                    # 7 playbooks (01-base → 07-security)
│   ├── ansible.cfg             # forks=20, pipelining, inject_facts_as_vars=False
│   ├── group_vars/all.yml      # Domain, DB, PHP 8.3, backup, Grafana, paths
│   ├── inventory/hosts.yml     # TEMPLATE only — deploy.sh generates hosts-<ws>.yml
│   ├── requirements.yml        # ansible.mysql >=5.0.0, ansible.posix >=2.0.0
│   ├── requirements-deploy.txt # ansible + PyMySQL (CI)
│   └── playbook-*.yml
│
├── ansible-roles/              # 16 custom roles (NO collections besides ansible.mysql + posix)
│   ├── packages_common/        # apt, PHP detection, FPM+ext+MariaDB+certbot+fail2ban+rclone+swap
│   ├── packages_{apache,nginx}/
│   ├── {nginx,nginx-ssl}/      # nginx.conf, default vhost, MODX vhost, SSL vhost
│   ├── {apache_http,apache_ssl}/ # a2enmod, hardening, HTTP/SSL vhosts
│   ├── ssl/                    # Orchestrator: restore → certbot DNS → webroot → self-signed
│   ├── php/                    # php_limits.ini, opcache.ini
│   ├── mariadb/                # optimizations.cnf, create db+user+monitoring user
│   ├── redis/                  # Install + configure redis-server
│   ├── monitoring/             # Exporters (node/redis/apache|nginx/mysql), VictoriaMetrics, vmagent
│   ├── grafana/                # Install + provisioning (datasource, dashboards, alerts)
│   ├── backup/                 # Upload scripts, systemd telegram-bot, crons
│   ├── restore/                # rclone-based download + extract + DB restore
│   └── security/               # sshd hardening, fail2ban, sysctl, MODX perms
│
├── scripts/                    # Pushed to server by backup role
│   ├── smart_backup.sh         # Hourly: hash-skip project, always DB dump, VictoriaMetrics push
│   ├── upload_backups_to_gdrive.sh
│   ├── RESTORE_ALL.sh          # Interactive restore (English UI)
│   ├── send_report.sh          # `send_report.sh daily|weekly`
│   ├── telegram_bot.py         # systemd service — /status and /backups
│   ├── check_services.sh       # Comprehensive health checks (systemd timer + deploy)
│   ├── audit_deep.sh           # Deep audit: security perimeter, PHP, DB, monitoring, MODX cache
│   ├── verify_backups.sh       # Archive integrity check
│   ├── lint.sh                 # Single source of truth for CI + local linting
│   └── common_functions.sh     # Shared Bash: load_env, send_tg, escape_md2
│
├── configs/fail2ban/jail.local
├── .env.example                # Template with all required vars
├── .github/
│   ├── workflows/              # 8 workflows (see CI/CD section)
│   └── actions/                # setup-ansible, setup-terraform composite actions
└── secrets/                    # ALL GITIGNORED
    ├── .env                    # Live secrets (ansible-vault encrypted)
    ├── tfstate-backup/         # TF state snapshots (rotate 5)
    └── ssl/                    # Optional: letsencrypt certs for one-click restore
```

---

## 4. Deploy flow (`deploy.sh`)

`./deploy.sh TARGET -n|-a [OPTIONS]`

**Step sequence** (full prod deploy, Nginx):

1. `parse_args` + `resolve_target` → sets `TF_PROVIDER`, `TF_WORKSPACE`, `DEPLOY_DOMAIN`, `TARGET_PREFIX`
2. `preflight_checks` → SSH key, `.env` parseable, required vars, TF dir
3. Prod prompt: `Continue? [y/N]`
4. `rotate_logs` → keep MAX_LOG_FILES (default 10)
5. **Terraform:** init → workspace select/new → apply → get `server_ipv4` → backup tfstate (rotate 5) → `ssh-keygen -R` → Cloudflare DNS update
6. **Wait for SSH** (AWS: 40×10s, Hetzner: 90×2s)
7. **Wait for cloud-init** (timeout 300s + 15×2s poll)
8. Generate inventory + `DEPLOY_VARS_TMP` (JSON, `0600`, cleaned on trap)
9. **Ansible playbooks** (sequential or 4-phase parallel): 01 → (02 + 03 parallel) → 07 → (04 + 05 parallel) → 06
10. `check_services.sh` via SSH (also runs via systemd timer every 5 min)
11. Summary: URL, Grafana URL, SSH command, per-step durations, total time

**Destroy path:** dev → 1 confirm, prod → 3 confirm ("type `destroy prod`"), terraform destroy, delete workspace (non-prod), wipe tfstate-backup.

**Key design notes:**

- Provider-agnostic past `resolve_target`; only `export_tf_env` and `main.tf` differ
- AWS and Hetzner share `TARGET_PREFIX`-based env var mapping (`PROD_*`, `DEV_AWS_*`, `DEV_HETZ_*`, `PROD_HETZ_*`)
- Inventory files are per-workspace and **auto-regenerated every deploy**
- `DEPLOY_VARS_TMP` is plain JSON (not ansible-vault), cleaned on `EXIT INT TERM`

---

## 5. Ansible

### Config (`ansible.cfg`)

- `roles_path = ../ansible-roles` — don't relocate playbooks
- **`inject_facts_as_vars = False`** — use `{{ ansible_facts['memtotal_mb'] }}`, not bare `{{ ansible_memtotal_mb }}`. Intentional: prevents namespace pollution, reduces memory.
- `become = False` at playbook level; individual tasks opt in. Playbooks 04/05/06 opt-in globally.
- `gathering = smart`, fact caching via JSON file (1h TTL), `forks = 20`, pipelining enabled.

### Role specifics

- **`packages_common`** auto-detects the highest installed PHP version (via `apt-cache search`) and sets `php_version` as cacheable fact. `group_vars/all.yml` PHP 8.3 is only a fallback. Installs `php{{ version }}-zip` and `php{{ version }}-gd` by default.
- **`ssl`** — priority chain: local restore from `secrets/ssl/` → certbot DNS-Cloudflare (if CF token set) → certbot webroot (DNS-to-server check via 8.8.8.8) → self-signed fallback. Self-signed works for **both** Nginx and Apache — role runs unconditionally, both web server templates consume same cert paths.
- **`restore`** skips if `/var/www/html/index.php` exists OR `rclone.conf` is missing.
- **`packages_nginx`** — installs nginx + systemd `Restart=always` drop-in (auto-recovery after crash).
- **`php`** — configures PHP-FPM + systemd `Restart=always` drop-in. Mounts tmpfs at `{{ web_root }}/core/cache` (128M, mode 0755, uid/gid 33). Restore role unmounts it before project extraction and re-mounts via `mount -a`. Cache is cleared with `find -exec` (never `state: absent` on mount point).
- **`monitoring`** conditionally includes exporters based on `web_server` and `db_pass`. `check_site` cron runs every 1 min.
- **`grafana`** resets admin password via `grafana-cli` on every deploy. Health check with 15×7s retry runs first; `failed_when: false` only catches edge cases. `no_log: true`, `changed_when: false`.
- **`security`** strips `AuthorizedKeysCommand` from `/etc/ssh/sshd_config.d/50-cloud-init.conf` (disables EC2 Instance Connect).
- **Fail2ban** has three custom filters — `modx-admin`, `dreamseed-botsearch`, `dreamseed-bad-request` — all **enabled**. Web jails see real visitor IPs via Cloudflare CF-Connecting-IP + `ngx_http_realip_module`. The Jinja-generated `jail.d/custom.conf` branches on nginx vs apache.

---

## 6. Backup / restore / monitoring

### Backup pipeline

| Step | When | What | Retention |
|------|------|------|-----------|
| Local project | Hourly | `smart_backup.sh` — hash-skip if unchanged, `tar.gz` | 5 copies |
| Local DB | Hourly | `smart_backup.sh` — always dump via `~/.my.cnf`, `.sql.gz` | 15 copies |
| Local Redis | Hourly | `smart_backup.sh` — copy `dump.rdb` | 5 copies |
| Cloud upload | Hourly at :05 | `upload_backups_to_gdrive.sh` — rclone to `gdrive:DreamSeed/backups/{project,db,redis}${ENV}/` | 10 project, 100 DB, 10 Redis |
| Integrity check | Daily | `verify_backups.sh` — archive validation | — |
| Reporting | Daily 15:30, Sun 18:30 | `send_report.sh` → Telegram | — |

On success: pushes `backup_last_success_timestamp` + `upload_last_success_timestamp` to VictoriaMetrics.
On failure: alerts Telegram. Better Stack heartbeats ping on each step.

### Restore path

`RESTORE_ALL.sh` (interactive, English UI): choose scope (project/db/both) → select archive → confirm → stop web+FPM → restore → `TRUNCATE modx_session` → restart → HTTP 200 health check → Telegram summary.

### Monitoring stack (on-server)

| Component | Port | Notes |
|-----------|------|-------|
| node_exporter | `:9100` | System metrics |
| apache_exporter / nginx-prometheus-exporter | `:9117` / `:9113` | Conditional on web server |
| mysqld_exporter | `:9104` | MySQL metrics |
| VictoriaMetrics | `:8428` | Retention 3 months, scrape 15s |
| vmagent | `:8429` | Remote write to Grafana Cloud |
| Grafana | `:3000` | Memory-capped 480 MB |
| redis_exporter | `:9121` | Redis metrics |
| check_site.sh | cron 1min | HTTP health check |
| check_services.sh | timer 5min | Comprehensive service health |

### Alert matrix (24 rules)

- **critical (8):** MySQL Down, PHP-FPM Down, Nginx/Apache Down, Site Down, MODX Core Missing, VictoriaMetrics Down, Redis Down, VMAgent Remote Write Failing
- **warning (14):** High CPU, High RAM, Low Disk, Swap Thrashing, Site Response Time > 5s, MODX Cache Not Writable, Backup Cron Not Running, Cloud Upload Failed, Site Health Check Not Running, Admin Login, MiniShop2 Write, Backup Verify, Service Check Not Running
- **info (2):** SSL Cert Expiring, DB Tables Below Threshold

**Alert design:**

- `noDataState: Alerting` for critical always-scraped services (MySQL, Nginx/ Apache, PHP-FPM, Site, VM, Redis) + Backup Cron + Cloud Upload + Service Check
- `noDataState: OK` for probe/push metrics (admin-login, ms2, db-tables, modx-core, ssl-expiry, backup-verify)
- `for:` scraped 15s → 2m, pushed 1m → 5m, probes 15m → 6m; cron-based (backup/upload/etc): 70-75m to avoid false positives on fresh deploy
- All alerts show env first: `🔴 [dev-aws] Alert Name` using `{{ deploy_env }}` label
- critical → `repeat_interval: 1h`; warning/info → 4h
- Some rules are conditional: Nginx Down vs Apache Down depends on `web_server`; VMAgent Remote Write Firing only if `grafana_cloud_url` is set.

### External monitoring

| Layer | Type | Count | Delivery |
|-------|------|-------|----------|
| Grafana Cloud | Hosted metrics (vmagent) | always on | Cloud dashboard |
| Grafana Cloud | Synthetic Monitoring | 10k checks/mo | SM dashboard |
| Better Stack | HTTP monitors | 3 monitors | Better Stack → Telegram |
| Better Stack | Cron heartbeats | 4 heartbeats | Better Stack → Telegram |

### Grafana 13 → 12 downgrade (memory regression)

- **Issue:** [#123017](https://github.com/grafana/grafana/issues/123017) — v13 increased memory consumption (180→330MB idle) due to ngalert stale state maps + unbounded HTTP cache
- **Fix:** [#123098](https://github.com/grafana/grafana/pull/123098) — `fix(ngalert): release stale transition value maps after full eval pipeline`
- **Status:** Downgraded to v12.4.5 (Jul 2026). Revisit when 13.1.x ships with the fix.
- **GOMEMLIMIT=800MiB** retained in `/etc/systemd/system/grafana-server.service.d/memory.conf` (now in Ansible).

---

## 7. CI/CD (`.github/workflows/`)

| Workflow | Trigger | What it does |
|----------|---------|-------------|
| `ci.yml` | Push/PR | 9 parallel jobs: ShellCheck, Ansible Lint, Jinja2 Lint, tflint, terraform validate, checkov, trivy, gitleaks, actionlint, pre-commit |
| `deploy.yml` | Manual dispatch | Deploy or destroy any target from GitHub UI |
| `test-restore.yml` | Weekly (Mon) + manual | Full backup/restore integration test on ephemeral server (AWS or Hetzner) |
| `TF: Infra + Cloudflare` | Manual dispatch | Terraform apply (infra-only) or Cloudflare WAF/cache rules |
| ~~`cloudflare-cache.yml`~~ | Removed | Replaced by `TF: Infra + Cloudflare` |
| `health-check.yml` | Weekly (Sun) | SSH in, `apt upgrade`, check reboot required |
| `drift-detection.yml` | Daily | Terraform plan on both AWS and Hetzner, alerts on drift |
| `rollback.yml` | Manual dispatch | Restore tfstate from backup and re-apply |
| `grafana-cloud.yml` | Push to terraform/grafana/ | Apply Grafana Cloud resources (SM, dashboards) |

`FORCE_JAVASCRIPT_ACTIONS_TO_NODE24=true` set workflow-wide.
Trivy ignores public ingress/egress on SG (port 80/443/22) via `#tfsec:ignore:`.

---

## 8. Secrets & env vars

All secrets in `secrets/.env` (ansible-vault encrypted, password in `~/.vault_pass_dreamseed`). Template: `.env.example`.

### Per-target mapping

| Target     | Prefix       | Keys |
|------------|-------------|------|
| `prod`     | `PROD_`     | `PROD_ACCESS_KEY`, `PROD_SECRET_KEY`, `PROD_REGION`, `PROD_EIP` |
| `dev-aws`  | `DEV_AWS_`  | `DEV_AWS_ACCESS_KEY`, … |
| `dev-hetz` | `DEV_HETZ_` | `DEV_HETZ_HCLOUD_TOKEN`, `DEV_HETZ_SERVER_TYPE`, … |
| `prod-hetz`| `PROD_HETZ_`| `PROD_HETZ_HCLOUD_TOKEN`, `PROD_HETZ_SERVER_TYPE`, … |

Unprefixed fallback for Hetzner: `HCLOUD_TOKEN`, `HETZNER_SERVER_TYPE`, etc.

### Shared vars

`DB_NAME` `DB_PASS` `GRAFANA_PASS` `CLOUDFLARE_API_TOKEN` `CLOUDFLARE_ZONE_ID` `TG_TOKEN` `TG_CHAT_ID` `TG_THREAD_ID` `OWNER` `EMAIL_USER` `EMAIL_PASS` `SMTP_SERVER` `SMTP_PORT` `BETTERUPTIME_API_TOKEN`

### Grafana Cloud (per-target)

- `PROD_GRAFANA_CLOUD_*` — org 1
- `DEV_GRAFANA_CLOUD_*` — org 2 (shared by dev-hetz + dev-aws)

### SSL

Cloudflare token is **optional**. If set → certbot DNS-01 (Cloudflare). If absent → certbot webroot HTTP-01. If all fail → self-signed fallback.

---

## 9. Design notes & edge cases

- **TFC destroy exit code:** Terraform Cloud may return exit code 1 even on success (empty state after destroy). `lib/terraform.sh` only checks `grep "Destroy complete"` when exit code is non-zero.
- **Better Stack** replaced healthchecks.io: cron scripts ping `https://uptime.betterstack.com/api/v1/heartbeat/<KEY>` on success.
- **`deploy.sh --lint`** delegates to `scripts/lint.sh` — single source of truth.
- **`check_services.sh`** runs via systemd timer every 5 min, plus once at end of deploy.
- **Dev = Prod rule:** Dev must mirror prod in EVERYTHING — monitoring, backups, alerting, scripts. No "skip for dev" logic. Dev backups upload to cloud same as prod (separate paths). Even though restore always pulls from prod, dev runs the identical pipeline.
- **Promote feature abandoned:** no DB sync between prod and dev environments (intentional — dev is ephemeral, always pulls latest prod data on restore).
- **`*.service` files are gitignored** — only `.j2` templates ship to git.
- **Ansible roles are stateless** — not all fully idempotent (cron uses `state: present|absent` from `backup_cron_enabled`).
- **PHP version auto-detection** runs in playbook-01 and caches the fact for subsequent playbooks.
- **`tfstate-backup/`** kept locally, auto-rotated to 5 per workspace.
- **`deploy.yml`** uses `tee /tmp/deploy.log` instead of redirect — real-time streaming in GH Actions logs (no more "hanging" step).
- **`grafana-alerts.yaml.j2`** uses `{{ deploy_env }}` as env label (shows `dev-aws`, `prod`, etc.) instead of `{{ domain }}`. Env always appears first in Telegram message: `🔴 [dev-aws] Alert Name`.
- **`common_functions.sh`** `prune_cloud_backups` uses `grep -c ... || true` — prevents `set -euo pipefail` from aborting when rclone listing is empty.
- **`rclone_retry()`** — wrapper in `common_functions.sh` that retries rclone commands 3× with exponential backoff + `--retries-sleep 1s`. Uses `RCLONE_CMD_TIMEOUT` env var (NOT `RCLONE_TIMEOUT` — that clashes with rclone's own `--timeout` flag).
- **`session_handler_class`** must be **empty** in MODX system settings. When empty, MODX falls through to PHP's native session handler → Redis. `backup/tasks/main.yml` clears it on every deploy. `restore/tasks/main.yml` also clears it.
- **`setup-secrets`** composite action (`.github/actions/setup-secrets/`) writes SSH key, vault password, and rclone config. Used by `deploy.yml`, `health-check.yml`, `test-restore.yml`.
- **`_cf_zone_id()`** in `lib/helpers.sh` — shared function that resolves Cloudflare zone ID from domain. Both `update_cloudflare_dns()` and `delete_cloudflare_dns()` use it.
- **Cloudflare rate limit** on `/manager/` — 20 req/10s, block 10s (Free plan limitation — period only 10, mitigation_timeout only 10). Combined with fail2ban `modx-admin` jail (25 failures → 1h ban).
- **Grafana Cloud URLs** are different for vmagent (Prometheus remote_write endpoint) vs Terraform (Grafana instance URL). Instance URLs are hardcoded in `grafana-cloud.yml` (`vitalikuts.grafana.net` / `dreamseed.grafana.net`). Prometheus endpoints are per-region secrets (`DEV/PROD_GRAFANA_CLOUD_URL`).
- **Playbook order** after renumbering: 01-base → 02-web → 03-db → 04-security → 05-monitor → 06-backup → 07-grafana.
- **`deploy.yml`** uses `tee /tmp/deploy.log` instead of redirect — real-time streaming in GH Actions logs (no more "hanging" step).
- **`grafana-alerts.yaml.j2`** uses `{{ deploy_env }}` as env label (shows `dev-aws`, `prod`, etc.) instead of `{{ domain }}`. Env always appears first in Telegram message: `🔴 [dev-aws] Alert Name`.
- **nginx + PHP-FPM** have systemd `Restart=always` via drop-in overrides — auto-recover after OOM/crash.

## 10. File access policy

| Pattern | Action |
|---------|--------|
| `ansible-roles/*/templates/*.j2` | **Auto-read** — Jinja2 templates, no secrets |
| `scripts/*.sh` | **Auto-read** — infrastructure scripts |
| `secrets/.env` | **Ask first** — ansible-vault encrypted, contains all secrets |
| `<any>/*.tf`, `<any>/*.yml`, `<any>/*.yaml`, `<any>/*.md`, `<any>/*.cfg`, `<any>/*.example` | **Auto-read** — code/config |
| User-owned files (`~/Documents/`, `~/Desktop/`) | **Auto-read** — user's local files |
| Decrypted secrets output | **Never log/shown** — treat as sensitive |
