# 🌱 DreamSeed

![CI](https://github.com/W1ckedS1ck/DreamSeed/actions/workflows/ci.yml/badge.svg)
![Deploy](https://github.com/W1ckedS1ck/DreamSeed/actions/workflows/deploy.yml/badge.svg)
![Rollback](https://github.com/W1ckedS1ck/DreamSeed/actions/workflows/rollback.yml/badge.svg)
![Backup Test](https://github.com/W1ckedS1ck/DreamSeed/actions/workflows/backup-test.yml/badge.svg)
![Drift Detection](https://github.com/W1ckedS1ck/DreamSeed/actions/workflows/drift-detection.yml/badge.svg)

![Terraform](https://img.shields.io/badge/Terraform-1.1%2B-7B42BC?logo=terraform)
![Ansible](https://img.shields.io/badge/Ansible-2.15%2B-EE0000?logo=ansible)
![AWS](https://img.shields.io/badge/AWS-EC2-FF9900?logo=amazon-aws)
![Hetzner](https://img.shields.io/badge/Hetzner-Cloud-D50C2D?logo=hetzner)
![Ubuntu](https://img.shields.io/badge/Ubuntu-24.04-E95420?logo=ubuntu)
![MariaDB](https://img.shields.io/badge/MariaDB-10.11-003545?logo=mariadb)
![PHP](https://img.shields.io/badge/PHP-8.3-777BB4?logo=php)
![Grafana](https://img.shields.io/badge/Grafana-10-F46800?logo=grafana)
![Cloudflare](https://img.shields.io/badge/Cloudflare-DNS-F38020?logo=cloudflare)
![GitHub last commit](https://img.shields.io/github/last-commit/W1ckedS1ck/DreamSeed/main)
![GitHub issues](https://img.shields.io/github/issues/W1ckedS1ck/DreamSeed)

> **Infrastructure powering a global social experiment about human dreams.**
> Built and owned by the Co-founder & CTO — from empty cloud account to production-ready platform in under 15 minutes.

---

## 🌍 About the Product

**DreamSeed** ([dreamseed.online](https://dreamseed.online)) is a global social experiment and challenge — *"The Dreamers"*.

Participants take an 8-question **Wheel of Life** self-assessment, choose a virtual **bonsai tree** symbolising their dream category (Health, Career, Family, Finances, Creativity, Personal Growth, Joy, Relationships), and pay **$1.99** as a personal promise to pursue that dream. Each tree is placed on an interactive **Garden of Dreamers** world map, building a live global dataset around four core hypotheses:

> *"Only 1% of adults are dreamers. Most dreamers hide in megacities. Money is the main dream of our generation. Dreaming is a privilege for 18–25-year-olds."*

The experiment runs until summer 2026, after which full anonymous results are published.

**The developer built the MODX-based platform** — catalog, questionnaire, payments, user accounts, and the world map. **My job** was to build and maintain everything that keeps it online, fast, secure, and recoverable.

---

## 👥 Team

| Role | Responsibilities |
|------|-----------------|
| **Investor / CEO** | Product vision, experiment design, content, business decisions |
| **Backend Developer** | MODX CMS platform: questionnaire engine, virtual catalog, payments, user accounts, Garden map |
| **Co-founder & CTO** *(Vitali Kuts)* | All infrastructure: cloud provisioning, deployment automation, SSL, monitoring, backups, security, CI/CD |
| **Support Engineers** (2–3) | Participant support, onboarding, documentation — report directly to CTO |

---

## 🔧 My Role as Co-founder & CTO

The developer writes features; I make sure they reach the world. I designed and built the entire infrastructure layer from scratch — everything below the application:

- **Cloud provisioning** — Terraform modules for AWS EC2 and Hetzner Cloud
- **Server automation** — 15+ idempotent Ansible roles covering the full server lifecycle
- **Deployment pipeline** — single `./deploy.sh` command takes the platform from zero to live
- **Security** — SSH hardening, Fail2ban with a MODX-specific admin login filter, Ansible Vault for secrets, cloud-native firewalls
- **Observability** — Prometheus + VictoriaMetrics + Grafana stack deployed automatically; Telegram alerts for the team
- **Backup & recovery** — daily DB + file backups to Google Drive via rclone, tested one-command `RESTORE_ALL.sh` restore path
- **CI/CD** — 7-job GitHub Actions pipeline with linting and security scanning on every push
- **Knowledge transfer** — operational runbooks and hands-on training for 2–3 support engineers who report directly to me

---

## 🧰 Tech Stack

| Layer | Tools |
|---|---|
| **Infrastructure** | Terraform · Terraform Cloud (remote state) · AWS EC2 · Hetzner Cloud |
| **Configuration** | Ansible (15+ custom roles) |
| **Platform** | MODX CMS · Nginx / Apache · PHP 8.3 · MariaDB |
| **SSL** | Cloudflare proxy (Full SSL) · self-signed origin cert · optional Let's Encrypt via `ssl_skip_certbot: false` |
| **Monitoring** | Prometheus · VictoriaMetrics · Grafana · Node/Apache/Nginx/MySQL exporters |
| **Backups** | Custom Bash scripts · rclone → Google Drive · Telegram notifications |
| **Security** | Fail2ban + custom MODX filter · SSH hardening · UFW-style cloud firewalls · Ansible Vault |
| **CI/CD** | GitHub Actions · ShellCheck · ruff · ansible-lint · tflint · tfsec · gitleaks |

---

## 🏛️ Architecture at a Glance

```
           ┌──────────────────┐
           │    deploy.sh     │   ← one entry point
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

Terraform provisions the infrastructure; Ansible configures it. `deploy.sh` orchestrates both with SSH retry logic, cloud-init validation, coloured progress output, and timestamped logs.

---

## 🚀 Deploy Commands

```bash
# Production on AWS with Nginx
./deploy.sh prod -n

# Development on Hetzner with Nginx
./deploy.sh dev-hetz -n

# Development on AWS with Apache
./deploy.sh dev-aws -a

# Reconfigure an existing server (skip provisioning)
./deploy.sh prod -n -i 1.2.3.4
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
├── deploy.sh                 # Main orchestrator (≈900 lines of battle-tested Bash)
├── terraform/
│   ├── aws/                  # EC2 + Elastic IP + Security Group
│   └── hetzner/              # Cloud server + firewall + primary IP
├── ansible/
│   ├── playbook-01-base.yml      # OS packages
│   ├── playbook-02-nginx.yml     # Nginx + PHP
│   ├── playbook-02-apache.yml    # Apache + PHP
│   ├── playbook-03-db.yml        # MariaDB + restore logic
│   ├── playbook-04-monitor.yml   # Prometheus + exporters
│   ├── playbook-04.5-backup.yml  # Backup cron + Telegram bot
│   ├── playbook-05-grafana.yml   # Grafana dashboards
│   └── playbook-06-security.yml  # Hardening
├── ansible-roles/            # 15 reusable roles (nginx, mariadb, ssl, …)
├── scripts/                  # Backup, restore, Telegram bot, daily/weekly reports, secrets upload
├── configs/                  # Fail2ban jails (incl. MODX admin filter)
├── secrets/                  # Ansible Vault encrypted secrets (gitignored)
└── .github/workflows/
    ├── ci.yml                # Full lint + security + validation pipeline
    ├── deploy.yml            # One-button deploy via GitHub Actions (no local machine needed)
    ├── drift-detection.yml   # Daily terraform plan against prod — alerts on infrastructure drift
    ├── backup-test.yml       # Automated backup/restore verification (daily)
    └── rollback.yml          # Emergency rollback to previous backup
```

---

## ✨ Infrastructure Highlights

### 🎛️ Multi-Cloud
Same deployment command works on **AWS** and **Hetzner** — each with its own Terraform module, unified Ansible layer. Switching providers requires no playbook changes.

### 🔐 Secure by Default
- SSH hardening (no password auth, restricted ciphers)
- Fail2ban with a **custom MODX admin login filter** against CMS brute-force
- Cloud-native firewalls (AWS SG / Hetzner Firewall)
- Environment secrets (`secrets/.env`) encrypted at rest with Ansible Vault; CI runs `gitleaks` on every push

### 📊 Full Observability
Grafana dashboards auto-wired to VictoriaMetrics with Node, Nginx/Apache, and MySQL exporters. Team gets Telegram alerts for anomalies and deployment events.

### 💾 Real Backups, Tested Restores
Daily MariaDB + file backups with rotation to Google Drive via rclone. `RESTORE_ALL.sh` gives one-command disaster recovery — validated in a full backup drill before going to production.

### 🧪 CI Pipeline — 7 Parallel Jobs + Additional Workflows
ShellCheck · ruff · ansible-lint · tflint · tfsec · gitleaks · terraform validate

Additional workflows:
- **Drift Detection** — daily `terraform plan` against prod (Terraform Cloud)
- **Backup Test** — daily automated backup/restore verification
- **Rollback** — emergency rollback to previous backup

### 🛑 Production Safeguards
Any `deploy.sh prod` run — whether deploying or destroying — requires manual confirmation before touching production.

- **Deploy**: prompts `Continue? [y/N]` before Terraform runs, preventing accidental reconfiguration of a live server
- **Destroy**: three-step confirmation — two `[y/N]` prompts and typing the literal phrase `destroy prod`

---

## 🔍 Key Engineering Decisions

- **Idempotent Ansible roles** — every playbook re-runs safely; updates config without breaking live services
- **Cloudflare-first SSL** — all environments sit behind Cloudflare proxy (Full SSL mode); origin uses a self-signed cert, eliminating Let's Encrypt rate limits and certbot failures on fresh deploys. To enable Let's Encrypt, set `ssl_skip_certbot: false` in `group_vars/all.yml`. To use a custom certificate, place it in `secrets/ssl/letsencrypt/live/<domain>/` and it will be restored automatically.
- **Isolated Terraform workspaces** — `prod` and `dev` state files are fully separated; destroying dev cannot affect prod
- **SSH + cloud-init polling in `deploy.sh`** — waits for the VM to fully boot before handing off to Ansible, eliminating first-deploy race conditions
- **Telegram bot as systemd service** — deployment, backup, and alert notifications go directly to the team's phones
- **Tested restore path** — `RESTORE_ALL.sh` was validated in a drill before being trusted in production

---

## 📸 Live Environments

| Target | Provider | Domain |
|---|---|---|
| `prod` | AWS EC2 (`us-west-1`) | dreamseed.online |
| `dev-aws` | AWS EC2 | aws.vitalikuts.online |
| `dev-hetz` | Hetzner (`nbg1`) | hetz.vitalikuts.online |

---

## 📜 License

Internal infrastructure — architecture and patterns are open for reference.

---

<p align="center">
Infrastructure engineered by <a href="https://github.com/W1ckedS1ck">Vitali Kuts</a> · DreamSeed — <em>A promise to follow your dream</em>
</p>
