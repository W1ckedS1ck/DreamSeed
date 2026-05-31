# 🌱 DreamSeed

![CI](https://github.com/W1ckedS1ck/DreamSeed/actions/workflows/ci.yml/badge.svg)
![Deploy](https://github.com/W1ckedS1ck/DreamSeed/actions/workflows/deploy.yml/badge.svg)
![Rollback](https://github.com/W1ckedS1ck/DreamSeed/actions/workflows/rollback.yml/badge.svg)
![BackupRestorationTest](https://github.com/W1ckedS1ck/DreamSeed/actions/workflows/backup-test.yml/badge.svg)
![Gitleaks](https://img.shields.io/badge/Gitleaks-passed-00C853?logo=gitleaks)
![Last Commit](https://img.shields.io/github/last-commit/W1ckedS1ck/DreamSeed/main)

![Terraform](https://img.shields.io/badge/Terraform-1.1%2B-7B42BC?logo=terraform)
![OpenTofu](https://img.shields.io/badge/OpenTofu-1.6%2B-FDA726?logo=opentofu)
![Ansible](https://img.shields.io/badge/Ansible-2.15%2B-EE0000?logo=ansible)
![AWS](https://img.shields.io/badge/AWS-EC2-FF9900?logo=amazonwebservices)
![Hetzner](https://img.shields.io/badge/Hetzner-Cloud-D50C2D?logo=hetzner)
![Pre-commit](https://img.shields.io/badge/pre--commit-active-FAB040?logo=pre-commit)
![Renovate](https://img.shields.io/badge/Renovate-enabled-1A1F6C?logo=renovate)


> **Production infrastructure powering a global social experiment — `dreamseed.online`**
> Built by the Co-founder & CTO. From empty cloud accounts to a monitored, hardened, multi-cloud platform with tested disaster recovery. Single command, under 10 minutes.

---

## 🌍 About the Product

**DreamSeed** ([dreamseed.online](https://dreamseed.online)) is a live global social experiment — *"The Dreamers"*. Participants take a **Wheel of Life** self-assessment, choose a virtual bonsai tree symbolising their dream, and pay $1.99 as a personal pledge to pursue it. Trees are placed on a live world map, building a global dataset.

**This repo contains ALL infrastructure** behind a production website serving real users with real payments, real accounts, and real data. Not a demo. Not a side project. Live at `dreamseed.online`.

---

## 📊 By the Numbers

| Metric | Value |
|--------|-------|
| Deploy time | <10 min (zero to live, either cloud) |
| Recovery time (RTO) | <5 min (tested `RESTORE_ALL.sh --auto-latest`) |
| Backup frequency (RPO) | 1 hour → Google Drive, 15/5 versions retained |
| Uptime coverage | 11 Grafana alert rules + 3 Better Stack monitors + 4 cron heartbeats → Telegram |
| CI checks per push | 8 parallel jobs (lint → security → validate) |
| Cloud cost | Tracked via Infracost GitHub App on every PR |
| Security score | Lynis 70+/100 (hardened Ubuntu 24.04) |

---

## 🔧 My Role — Co-founder & CTO

I own **everything below the application layer** — provisioning, configuration, SSL, monitoring, backups, security, CI/CD, disaster recovery. The developer builds features; I make sure they reach the world.

### What I Built

- **Multi-cloud provisioning** — Terraform modules for AWS EC2 and Hetzner Cloud from a single `deploy.sh` command
- **Server automation** — 15 idempotent Ansible roles covering the full server lifecycle (base → web → database → monitoring → backup → grafana → security)
- **Observability** — VictoriaMetrics + Grafana stack with 11 alert rules (CPU, RAM, Disk, MySQL, Nginx/Apache, PHP-FPM, MODX Core, site availability, VictoriaMetrics, backup cron, site check cron). Grafana Cloud remote write via vmagent for hosted metrics. External watchdog via Better Stack: 3 HTTP monitors + 4 cron heartbeats → Telegram. All provisioned automatically, no manual setup
- **Backup & DR** — hourly MariaDB + file backups to Google Drive (rclone), 15/5 version rotation, one-command `RESTORE_ALL.sh` for disaster recovery. RTO <5 min, RPO ≤1 hour
- **CI/CD** — 8 parallel GitHub Actions jobs: ShellCheck, ruff, ansible-lint, Terraform checks (lint+validate), OpenTofu validate, Trivy, gitleaks, pre-commit. Plus deploy, backup-test, drift-detection, rollback, grafana-cloud workflows
- **Security** — SSH hardening, fail2ban with custom MODX admin login filter, Ansible Vault for secrets, Gitleaks on every push, cloud-native firewalls, Lynis hardening
- **Production safety** — 3-step destroy confirmation on prod (two prompts + typing `destroy prod`), rollback requires `rollback prod` confirmation

---

## 🧰 Tech Stack

| Layer | Tools |
|---|---|
| **Infrastructure** | Terraform · Terraform Cloud (remote state) · AWS EC2 · Hetzner Cloud |
| **Configuration** | Ansible (15 custom roles) |
| **Platform** | MODX CMS · Nginx / Apache · PHP 8.3 · MariaDB |
| **SSL** | Cloudflare proxy (Full SSL) · self-signed origin cert · optional Let's Encrypt |
| **Monitoring** | VictoriaMetrics · Grafana · vmagent → Grafana Cloud · Node/Nginx/MySQL exporters · Telegraf (access log parsing) · 11 alert rules → Telegram · Better Stack (3 HTTP monitors + 4 cron heartbeats) |
| **Backups** | Custom Bash scripts · rclone → Google Drive · versioned retention |
| **Security** | Fail2ban + custom MODX filter · SSH hardening · Ansible Vault · Gitleaks · Trivy · Lynis |
| **CI/CD** | GitHub Actions (6 workflows) · ShellCheck · ruff · ansible-lint · Terraform checks · OpenTofu · Trivy · gitleaks · Renovate |

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
                         │ 04 Monitoring│
                         │ 05 Backup    │
                         │ 06 Grafana   │
                         │ 07 Security  │
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

# Development on Hetzner with Nginx
./deploy.sh dev-hetz -n

# Development on AWS with Apache
./deploy.sh dev-aws -a

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
├── deploy.sh                 # Main orchestrator (800+ lines of battle-tested Bash)
├── .github/actions/          # Composite actions: setup-secrets, setup-terraform, setup-ansible
├── terraform/
│   ├── aws/                  # EC2 + Elastic IP + Security Group
│   ├── hetzner/              # Cloud server + firewall + primary IP
│   └── grafana/              # Grafana Cloud dashboard provisioning via Terraform
├── ansible/
│   ├── playbook-01-base.yml      # OS packages
│   ├── playbook-02-nginx.yml     # Nginx + PHP
│   ├── playbook-02-apache.yml    # Apache + PHP
│   ├── playbook-03-db.yml        # MariaDB + restore logic
│   ├── playbook-04-monitor.yml   # VictoriaMetrics + exporters
│   ├── playbook-05-backup.yml   # Backup cron + Telegram bot
│   ├── playbook-06-grafana.yml   # Grafana dashboards + alerts
│   └── playbook-07-security.yml  # Hardening
├── ansible-roles/            # 15 reusable roles (nginx, mariadb, ssl, …)
├── scripts/                  # Backup, restore, Telegram bot, health checks
├── configs/                  # Fail2ban jails (incl. MODX admin filter)
├── secrets/                  # Secrets: .env (may be vault-encrypted), rclone.conf, ssl/ (gitignored)
├── .tflint.hcl               # Terraform linter config (+ AWS ruleset plugin)
└── .github/workflows/
    ├── ci.yml                # Full lint + security + validation pipeline
    ├── deploy.yml            # One-button deploy via GitHub Actions
    ├── drift-detection.yml   # Daily terraform plan against prod
    ├── backup-test.yml       # Full backup/restore verification with app health checks
    ├── rollback.yml          # Emergency rollback with prod confirmation
    └── grafana-cloud.yml     # Grafana Cloud dashboard provisioning
```

---

## ✨ Infrastructure Highlights

### 🎛️ Multi-Cloud, Single Command
Same deployment command provisions fresh infrastructure on **AWS** or **Hetzner** — each with its own Terraform module, unified Ansible layer. Zero playbook changes between clouds. The deployer doesn't care which cloud runs underneath.

### 🔐 Secure by Default
- SSH: no passwords, no root, no agent forwarding, MaxAuthTries 3, LogLevel VERBOSE
- Fail2ban with **custom MODX admin login filter** — bans brute-force on `/manager/`
- Fail2ban with **custom Grafana login filter** — catches failed auth attempts
- Secrets encrypted with Ansible Vault at rest; `gitleaks` scans every push
- Cloud-native firewalls (AWS SG / Hetzner Firewall) — only ports 22, 80, 443 open
- Full sysctl hardening (ICMP redirects, martian logging, core dumps disabled)

### 📊 Full Observability — Auto-Provisioned
Grafana dashboards, datasources, **and 11 alert rules** deployed automatically — no manual clicking. When a new server spins up, monitoring comes with it:

**Internal (Grafana + VictoriaMetrics on-server):**

- **Node Exporter** (`:9100`) — CPU, RAM, Disk, network
- **Nginx Prometheus Exporter** (`:9113`) / **Apache Exporter** (`:9117`) — web server health
- **MySQLd Exporter** (`:9104`) — queries, connections, slave status
- **VictoriaMetrics** (`:8428`) — 3-month retention, 15s scrape interval
- **Grafana** (`:3000`) — 6 provisioned dashboards, 11 alert rules → Telegram
- **check_site.sh** (cron, every 1m) — pushes `site_up`, `php_fpm_up`, `modx_core_ok`, `victoria_up`

**Grafana Cloud (hosted metrics):**
- **vmagent** (`:8429`) — VictoriaMetrics agent, scrapes on-server exporters and remote-writes to Grafana Cloud
- **Grafana Cloud dashboards** — "Logs Overview" (6 panels) + "Traffic Analysis" (4 panels)
- **Synthetic Monitoring** — Terraform-provisioned HTTP checks from 9 global regions + SSL checks from 3 regions

**External (Better Stack cloud-hosted):**
- **3 HTTP monitors** — `dreamseed.online` (HTTP 200 + keyword check + Grafana endpoint), 3min interval, 4 global regions
- **4 cron heartbeats** — backup (1h/5m), gdrive-upload (24h/30m), report-daily (24h/30m), report-weekly (7d/1h)
- **Public status page** — `status.dreamseed.online` with live uptime history
- **Telegram alerts** via separate webhooks for incident start and resolve

### 💾 Real Backups, Tested Restores
- **Local:** hourly project (hash-checked, skip if unchanged) + DB dump (always), rotated 5/15 versions
- **Cloud:** hourly upload to Google Drive via rclone, rotated 10 project + 20 DB versions
- **Restore:** `RESTORE_ALL.sh --auto-latest` — downloads latest backup from GDrive, extracts, restores DB, clears cache, restarts services. **Full CI verification every week** (`backup-test.yml`)
- **Telegram bot** (`telegram-bot.service`) — check `/status` or `/backups` anytime
- **Alerts:** hourly backup failure → Telegram. No cron for 2h → Grafana alert → Telegram

### 🧪 CI/CD Pipeline — 6 Workflows + Renovate + Infracost App

| Workflow | Trigger |
|----------|---------|
| **CI** — 8 parallel checks | Every PR + push to main |
| **Deploy** — single-click deploy | Manual dispatch (prod, dev-aws, dev-hetz) |
| **Backup Test** — full restore drill | Weekly Monday + manual |
| **Drift Detection** — terraform plan on prod | Daily 07:05 UTC + push |
| **Rollback** — emergency restore | Manual with prod confirmation |
| **Grafana Cloud** — dashboard provisioning | Manual dispatch |

CI checks: ShellCheck · ruff · ansible-lint · **Terraform** (tflint+validate) · **OpenTofu validate** · **Trivy** · **gitleaks** · **pre-commit**. Dependencies: **Renovate** (auto-PRs). Costs: **Infracost App** (PR comments).

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
| `prod` | AWS EC2 (`us-west-1`) | [dreamseed.online](https://dreamseed.online) | Nginx + PHP 8.3 + MariaDB |
| `dev-aws` | AWS EC2 | [aws.vitalikuts.online](https://aws.vitalikuts.online) | Full stack |
| `dev-hetz` | Hetzner (`nbg1`) | [hetz.vitalikuts.online](https://hetz.vitalikuts.online) | Full stack |

All environments are fully monitored, backed up, and behind Cloudflare proxy.

---

<p align="center">
Infrastructure engineered by <a href="https://github.com/W1ckedS1ck">Vitali Kuts</a> · DreamSeed — <em>A promise to follow your dream</em>
</p>

