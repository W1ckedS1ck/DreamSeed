# 🌱 DreamSeed

![CI](https://github.com/W1ckedS1ck/DreamSeed/actions/workflows/ci.yml/badge.svg)
![Deploy](https://github.com/W1ckedS1ck/DreamSeed/actions/workflows/deploy.yml/badge.svg)
![Restore Test](https://github.com/W1ckedS1ck/DreamSeed/actions/workflows/test-restore.yml/badge.svg)
![Rollback](https://github.com/W1ckedS1ck/DreamSeed/actions/workflows/rollback.yml/badge.svg)
[![Better Stack](https://uptime.betterstack.com/status-badges/v1/monitor/2e2g1.svg)](https://status.dreamseed.online)
![Last Commit](https://img.shields.io/github/last-commit/W1ckedS1ck/DreamSeed/main)

![Terraform](https://img.shields.io/badge/Terraform-1.15-7B42BC?logo=terraform)
![Ansible](https://img.shields.io/badge/Ansible-14.2.0-EE0000?logo=ansible)
![AWS](https://img.shields.io/badge/AWS-EC2-FF9900?logo=amazonwebservices)
![Hetzner](https://img.shields.io/badge/Hetzner-Cloud-D50C2D?logo=hetzner)
![Grafana](https://img.shields.io/badge/Grafana-13.1.1-F46800?logo=grafana)
![Cloudflare](https://img.shields.io/badge/Cloudflare-WAF%2BCache-F38020?logo=cloudflare)
![Renovate](https://img.shields.io/badge/Renovate-enabled-1A1F6C?logo=renovate)

> **Production infrastructure powering a global social experiment — `dreamseed.online`**
> Built by the Co-founder & CTO. From empty cloud accounts to a monitored, hardened, multi-cloud platform with tested disaster recovery. Single command, ~8–10 min.
>
> 📖 **Documentation**: [Wiki](https://github.com/W1ckedS1ck/DreamSeed/wiki) — architecture, runbook, operations guide, and more

---

## 🌍 About the Product

**DreamSeed** ([dreamseed.online](https://dreamseed.online)) is a live global social experiment — *"The Dreamers"*. Participants take a **Wheel of Life** self-assessment, choose a virtual bonsai tree symbolising their dream, and pay $1.99 as a personal pledge to pursue it. Trees are placed on a live world map, building a global dataset.

**This repo contains ALL infrastructure** behind a production website serving real users with real payments, real accounts, and real data. Not a demo. Not a side project. Live at `dreamseed.online`.

---

## 📊 By the Numbers

| Metric | Value |
|--------|-------|
| Deploy time | ~8-10 min (zero to live, either cloud) |
| Recovery time (RTO) | <5 min (tested `RESTORE_ALL.sh --auto-latest`) |
| Backup frequency (RPO) | hourly local (5/15 versions) → hourly Google Drive (10/100) |
| Uptime coverage | 23 Grafana alert rules + 3 Better Stack monitors + 6 cron heartbeats → Telegram |
| CI checks per push | 9 parallel jobs (lint → security → validate) |
| Security score | Lynis 70+/100 (hardened Ubuntu 24.04) |

---

## 🔧 My Role — Co-founder & CTO

I own **everything below the application layer** — provisioning, configuration, SSL, monitoring, backups, security, CI/CD, disaster recovery. The developer builds features; I make sure they reach the world.

### What I Built

- **Multi-cloud provisioning** — Terraform modules for AWS EC2 and Hetzner Cloud from a single `deploy.sh` command
- **Server automation** — 17 idempotent Ansible roles across 8 playbooks (01-base → 02-web → 03-db → 04-security → 05-monitor → 06-backup → 07-grafana → 08-promtail)
- **Observability** — VictoriaMetrics + Promtail + Grafana stack with 23 alert rules covering system, database, web server, site health, backup, security, and monitoring pipeline → Telegram. Grafana Cloud remote write via vmagent for hosted metrics + Faro RUM for real user monitoring + Loki for centralized logs. External watchdog via Better Stack: 3 HTTP monitors + 6 cron heartbeats → Telegram. All provisioned automatically, no manual setup
- **Backup & DR** — hourly MariaDB + file backups to Google Drive via rclone, AES-256 encrypted with rclone crypt (`gdrive-crypt:` remote), 5/15 version rotation, one-command `RESTORE_ALL.sh` for disaster recovery. RTO <5 min, RPO ≤1 hour
- **CI/CD** — 9 parallel GitHub Actions jobs: ShellCheck, ansible-lint, j2lint, Terraform checks (lint+validate+fmt), Checkov, Trivy, gitleaks, actionlint, pre-commit. Plus deploy, backup-test, drift-detection, rollback, grafana-cloud, health-check workflows
- **Security** — SSH hardening, fail2ban with custom MODX admin login filter, Ansible Vault for secrets, Gitleaks on every push, cloud-native firewalls, Lynis hardening
- **Production safety** — 3-step destroy confirmation on prod (two prompts + typing `destroy prod`), rollback requires `rollback prod` confirmation

---

## 🧰 Tech Stack

| Layer | Tools |
|---|---|
| **Infrastructure** | Terraform · Terraform Cloud (remote state) · AWS EC2 · Hetzner Cloud · Cloudflare (CDN / DDoS / SSL) |
| **Configuration** | Ansible (17 custom roles) |
| **Platform** | MODX CMS · Nginx / Apache · PHP 8.3 · MariaDB · Redis |
| **SSL** | Cloudflare proxy (Full SSL) · self-signed origin cert · optional Let's Encrypt |
| **Monitoring** | VictoriaMetrics · Grafana · vmagent → Grafana Cloud · Promtail → Loki · Faro RUM (real user monitoring) · Node/Nginx/MySQL/Redis exporters · 23 alert rules → Telegram · Better Stack (3 HTTP monitors + 6 cron heartbeats + status page) |
| **Backups** | Custom Bash scripts · rclone → Google Drive · versioned retention |
| **Security** | Fail2ban + custom MODX filter · SSH hardening · Ansible Vault · Gitleaks · Trivy · Lynis |
| **CI/CD** | GitHub Actions (8 workflows) · ShellCheck · ansible-lint · j2lint · Terraform checks · Checkov · Trivy · gitleaks · actionlint · pre-commit |

---

## 🏛️ Architecture at a Glance

```
           ┌──────────────────┐
           │    deploy.sh     │   ← one entry point, two clouds
           └────────┬─────────┘
                    │
        ┌───────────┴───────────┐
        ▼                       ▼
 ┌─────────────┐         ┌──────────────┐
 │  Terraform  │         │   Ansible    │
 │             │         │              │
 │ • AWS       │ ──────► │ 01 Base      │
 │ • Hetzner   │  SSH    │ 02 Web       │
 └─────────────┘         │ 03 Database  │
                         │ 04 Security  │
                         │ 05 Monitoring│
                         │ 06 Backup    │
                         │ 07 Grafana   │
                         └──────────────┘
                                │
                                ▼
                   🌐 https://dreamseed.online
```

Terraform provisions the cloud resources (EC2 or Hetzner server, firewall, IP). Ansible configures everything on the OS — packages, web server, database, SSL, monitoring stack, backup cron, Grafana dashboards, and security hardening. `deploy.sh` orchestrates both with SSH retry logic, cloud-init validation, parallel Ansible execution, and timestamped logs.

---

## 🚀 Deploy Commands

```bash
# Production on AWS with Nginx (requires confirmation)
./deploy.sh prod -n

# Production on Hetzner with Nginx (requires confirmation)
./deploy.sh prod-hetz -n

# Dev environment 1 (Nginx)
./deploy.sh dev-hetz -n

# Dev environment 2 (Apache)
./deploy.sh dev-aws -a

# Parallel mode (4-phase Ansible) — ~30% faster on sequential deploys
./deploy.sh prod -n -p

# Reconfigure an existing server (skip provisioning)
./deploy.sh prod -n -i 1.2.3.4

# Tail the latest deploy log (or terraform log with --logs tf)
./deploy.sh --logs
```

### Destroy

```bash
./deploy.sh dev-hetz -x      # one confirmation
./deploy.sh prod -x          # three-step confirmation (safety!)
```

Any `prod` command — deploy or destroy — requires manual confirmation. Production destroy additionally requires typing the literal phrase **`destroy prod`**.

---

## 📂 Project Layout

```
DreamSeed/
├── deploy.sh                 # Main orchestrator (500 lines + 6 modular lib files)
├── .github/actions/          # Composite actions: setup-terraform, setup-ansible
├── terraform/
│   ├── aws/                  # EC2 + Elastic IP + Security Group
│   ├── hetzner/              # Cloud server + firewall + primary IP
│   ├── cloudflare/            # WAF Managed Ruleset + Cache rules (Cloudflare provider)
│   └── grafana/              # Grafana Cloud dashboard provisioning via Terraform
├── ansible/
│   ├── playbook-01-base.yml      # OS packages
│   ├── playbook-02-web.yml          # Nginx/Apache + PHP + SSL
│   ├── playbook-03-db.yml        # MariaDB + restore logic
│   ├── playbook-04-security.yml  # Hardening (fail2ban, SSH)
│   ├── playbook-05-monitor.yml   # VictoriaMetrics + exporters
│   ├── playbook-06-backup.yml   # Backup cron + Telegram bot
│   ├── playbook-07-grafana.yml   # Grafana dashboards + alerts
│   └── playbook-08-promtail.yml  # Promtail log shipping (Loki)
├── ansible-roles/            # 17 reusable roles (nginx, mariadb, ssl, redis, …)
├── scripts/                  # Backup, restore, Telegram bot, health checks
├── docs/                     # Architecture, runbook, operations guide, linters, secrets ref
├── secrets/                  # Secrets: .env (ansible-vault encrypted), tfstate-backup/, ssl/ (all gitignored)
├── .tflint.hcl               # Terraform linter config (root, drives all providers)
├── renovate.json              # Automated dependency update config
└── .github/workflows/
    ├── ci.yml                # Full lint + security + validation pipeline
    ├── deploy.yml            # One-button deploy via GitHub Actions
    ├── drift-detection.yml   # Daily terraform plan against prod
    ├── test-restore.yml      # Full backup/restore verification with app health checks
    ├── rollback.yml          # Emergency rollback with prod confirmation
    ├── grafana-cloud.yml     # Grafana Cloud dashboard provisioning
    ├── health-check.yml      # Weekly server update (apt upgrade + reboot check)
    └── TF: Infra + Cloudflare # Apply Terraform (infra, cloudflare WAF/cache)
```

---

## ✨ Infrastructure Highlights

### 🎛️ Multi-Cloud, Single Command

Same deployment command provisions fresh infrastructure on **AWS** or **Hetzner** — each with its own Terraform module, unified Ansible layer. Zero playbook changes between clouds. The deployer doesn't care which cloud runs underneath.

### 🔐 Secure by Default

- SSH: no passwords, no root, no agent forwarding, MaxAuthTries 3, LogLevel VERBOSE
- Fail2ban with **custom MODX admin login filter** — bans brute-force on `/connectors/index.php`
- Fail2ban with **custom vulnerability scanner filter** (dreamseed-botsearch) — 2 hits → 12h ban
- Fail2ban with **custom bad-request filter** (dreamseed-bad-request) — HTTP 400 → 6 hits → 1h ban
- Secrets encrypted with Ansible Vault at rest; `gitleaks` scans every push
- Cloud-native firewalls (AWS SG / Hetzner Firewall) — only ports 22, 80, 443 open
- Full sysctl hardening (ICMP redirects, martian logging, core dumps disabled)

### 📊 Full Observability — Auto-Provisioned

Grafana dashboards, datasources, **and 23 alert rules** deployed automatically — no manual clicking. When a new server spins up, monitoring comes with it:

**Internal (Grafana + VictoriaMetrics on-server):**

- **Node Exporter** (`:9100`) — CPU, RAM, Disk, network
- **Nginx Prometheus Exporter** (`:9113`) / **Apache Exporter** (`:9117`) — web server health
- **MySQLd Exporter** (`:9104`) — queries, connections, replication
- **VictoriaMetrics** (`:8428`) — 3-month retention, 15s scrape interval
- **Grafana** (`:3000`) — 5–6 provisioned dashboards depending on web server (Node Exporter, MySQL, VictoriaMetrics, Redis, Nginx/Apache), 23 alert rules → Telegram
- **check_site.sh** (cron, every 1m) — pushes `site_up`, `php_fpm_up`, `modx_core_ok`, `victoria_up`

**Grafana Cloud (hosted telemetry):**

- **vmagent** (`:8429`) — VictoriaMetrics agent, scrapes on-server exporters and remote-writes to Grafana Cloud
- **Promtail** (`:9080`) — log agent, ships nginx + php-fpm + syslog to Loki (Grafana Cloud)
- **Faro RUM** — real user monitoring: Core Web Vitals (LCP/CLS/INP), JS errors, sessions by browser/country. Injected via nginx `sub_filter`, proxied through same domain to avoid adblockers
- **Grafana Cloud dashboards** — 5 community dashboards provisioned via Terraform (Node Exporter 1860, MySQL 7362, Redis 763, Nginx 17452, VictoriaMetrics 10229)
- **Synthetic Monitoring** — Terraform-provisioned HTTP checks from 3 America probes + SSL checks from 1 probe

**External (Better Stack cloud-hosted):**

- **3 HTTP monitors** — `dreamseed.online` (HTTP 200 + keyword check + Grafana endpoint), 3min interval, 4 global regions
- **6 cron heartbeats** — backup (1h/5m), gdrive-upload (1h/5m), report-daily (24h/30m), report-weekly (7d/1h), verify-backups (24h/10m), check-services (5min/60s)
- **Public status page** — `status.dreamseed.online` with live uptime history
- **Telegram alerts** via separate webhooks for incident start and resolve

### 💾 Real Backups, Tested Restores

- **Local:** hourly project (hash-checked, skip if unchanged) + DB dump (always), rotated 5/15 versions
- **Cloud:** hourly upload to Google Drive via rclone, rotated 10 project + 100 DB versions
- **Restore:** `RESTORE_ALL.sh --auto-latest` — downloads latest backup from GDrive, extracts, restores DB, clears cache, restarts services. **Full CI verification every week** (`test-restore.yml`)
- **Telegram bot** (`telegram-bot.service`) — check `/status` or `/backups` anytime
- **Alerts:** hourly backup failure → Telegram. No cron for 2h → Grafana alert → Telegram

### 🧪 CI/CD Pipeline — 8 Workflows + Renovate

| Workflow | Trigger |
|----------|---------|
| **CI** — 9 parallel checks | Every PR + push to main |
| **Deploy** — single-click deploy | Manual dispatch (all targets) |
| **Restore Test** — full backup/restore drill | Weekly Monday + manual |
| **Drift Detection** — terraform plan on prod | Daily 07:05 UTC + push |
| **Rollback** — emergency restore | Manual with prod confirmation |
| **Grafana Cloud** — dashboard provisioning | Manual dispatch |
| **Health Check** — weekly server update | Weekly Monday + manual |
| **TF: Infra + Cloudflare** — terraform apply (infra + WAF/cache) | Manual dispatch |
| **Cloudflare Cache** — legacy (WAF/cache in TF now) | Manual dispatch |

CI checks (9 parallel): ShellCheck · ansible-lint · j2lint · **Terraform** (tflint+validate+fmt) · **Trivy** · **Checkov** · **gitleaks** · **actionlint** · **pre-commit**. Dependencies: **Renovate** (auto-PRs).

### 🛑 Production Safeguards

- **Deploy:** manual `[y/N]` confirmation before touching production
- **Destroy:** three-step — two `[y/N]` prompts + typing `destroy prod`
- **Rollback:** requires typing `rollback prod` in the workflow input
- **Terraform Cloud** isolates state files per environment
- **CI enforces** lint, security scan, secret scan, and terraform validation before any merge

---

## 🔍 Key Engineering Decisions

- **Idempotent Ansible roles** — every playbook re-runs safely; updates config without breaking live services
- **Cloudflare-first SSL** — all environments behind Cloudflare proxy (Full SSL mode); origin uses self-signed cert. This eliminates Let's Encrypt rate limits and certbot failures during provisioning
- **VictoriaMetrics over Prometheus** — single binary, no dependencies, lower memory footprint on t3.small/cx23. Same PromQL, simpler ops
- **Ansible Vault for secrets** — not GitHub Secrets or AWS Secrets Manager. Secrets are versioned with code, encrypted at rest, decrypted at deploy time. CI has the vault password, prod doesn't need it
- **No Docker** — MODX is a traditional PHP CMS, containerization adds complexity without benefit here. Ansible handles idempotent provisioning natively
- **RESTORE_ALL.sh with rollback detection** — compares `modx_site_content.editedon` timestamps before and after restore, warns if restored data is older than current. Critical for real-world DR where a restore might overwrite recent data

---

## 📸 Live Environments

| Target | Provider | Domain | Stack |
|--------|----------|--------|-------|
| `prod` | `AWS` | [dreamseed.online](https://dreamseed.online) | Nginx/Apache + PHP 8.3 + MariaDB |
| `prod-hetz` | `Hetzner` | [dreamseed.online](https://dreamseed.online) | Nginx/Apache + PHP 8.3 + MariaDB |
| `dev-aws` | `AWS` | [aws.vitalikuts.online](https://aws.vitalikuts.online) | Nginx/Apache + PHP 8.3 + MariaDB |
| `dev-hetz` | `Hetzner` | [hetz.vitalikuts.online](https://hetz.vitalikuts.online) | Nginx/Apache + PHP 8.3 + MariaDB |
| `test` | `Hetzner` | [test.dreamseed.online](https://test.dreamseed.online) | `test-restore.yml` — weekly full backup/restore drill |

All environments are fully monitored, backed up, and behind Cloudflare proxy (except `test` — ephemeral, destroyed after each run).

---

<!-- markdownlint-disable MD033 -->
<p align="center">
Infrastructure engineered by <a href="https://github.com/W1ckedS1ck">Vitali Kuts</a> · DreamSeed — <em>A promise to follow your dream</em>
</p>
<!-- markdownlint-enable MD033 -->
