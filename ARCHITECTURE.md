# Architecture

## Deployment Flow

```
deploy.sh TARGET -n|-a [OPTIONS]
       │
       ├─ 1. Preflight checks
       │      SSH key, .env, provider vars, TF dir
       │
       ├─ 2. Terraform
       │      init → workspace → apply → output server_ipv4
       │      backup tfstate → ssh-keygen -R
       │
       ├─ 3. Wait for SSH
       │      AWS: 40×10s | Hetzner: 20×1s polling
       │
       ├─ 4. Wait for cloud-init
       │      timeout 300s + 15×2s fallback
       │
       ├─ 5. Generate inventory + vault
       │      hosts-<workspace>.yml, VAULT_TMP (0600)
       │
       ├─ 6. Ansible (7 playbooks)
       │      01 Base ─── packages, swap, PHP, MariaDB
       │      02 Web ───── Nginx/Apache + SSL + PHP-FPM
       │      03 DB ────── MariaDB tuning, users, restore
       │      04 Monitor ─ Exporters + VictoriaMetrics
       │      05 Backup ── Scripts, crons, Telegram bot
       │      06 Grafana ─ Dashboards, datasources, alerts
       │      07 Security ── SSH, fail2ban, sysctl, MODX perms
       │
       └─ 7. Post-deploy checks
              systemctl is-active (5 services)
              curl https://$DOMAIN/ → 200|301
              Telegram summary
```

---

## Infrastructure Layers

```
Internet
   │
   ▼
Cloudflare Proxy (Full SSL)
   │
   ├─ dreamseed.online ───→ Nginx :443 → PHP-FPM → MariaDB
   │                          Nginx :80  → redirect to :443
   │
   ├─ dreamseed.online/grafana/ ───→ Grafana :3000 (behind nginx proxy_pass)
   │
   ├─ dreamseed.online/manager/ → MODX admin panel
   │
   └─ Monitoring backplane (127.0.0.1 only)
        Node Exporter :9100
        Nginx Exporter :9113 / Apache Exporter :9117
        MySQLd Exporter :9104
        VictoriaMetrics :8428
```

---

## Secrets Flow

```
secrets/.env (plaintext, gitignored)
   │
   ├─ ansible-vault encrypt → CI (base64 GitHub Secret)
   │                              │
   │                              ▼ deploy.yml / backup-test.yml
   │                              echo "$ENV_FILE_B64" | base64 -d
   │                              │
   │                              ▼
   │                         deploy.sh → VAULT_TMP (mktemp, 0600)
   │                              │
   │                              ▼
   │                         ansible-playbook --extra-vars @VAULT_TMP
   │
   └─ Server-side: /home/ubuntu/Scripts/.env (0600)
```

---

## Backup Pipeline

```
smart_backup.sh (hourly via cron)
   │
   ├─ Project: md5 hash check → skip if unchanged
   │            tar.gz → rotate keep 5
   │
   ├─ Database: mysqldump via ~/.my.cnf → gzip → rotate keep 15
   │
   └─ Push cron_last_run_backup to VictoriaMetrics

upload_backups_to_gdrive.sh (daily at 03:15 UTC)
   │
   ├─ rclone copy latest project + db → gdrive:DreamSeed/backups/
   │
   └─ Prune cloud: 10 project + 20 db → cleanup trash

RESTORE_ALL.sh (interactive or --auto-latest)
   │
   ├─ auto-latest: download from GDrive → local → restore
   ├─ Interactive: menu → choose scope → choose archive
   │
   ├─ Stop web + PHP-FPM
   ├─ Restore project (tar -xzf)
   ├─ Restore DB (gunzip | mysql) + TRUNCATE modx_session
   ├─ Detect rollback via modx_site_content.editedon
   └─ Restart services → health check → Telegram summary
```

---

## Monitoring & Alerting

```
┌──────────────┐    :8428    ┌─────────────────┐
│  Exporters   │─────────────│ VictoriaMetrics │
│  node_exporter              │ retention: 3mo  │
│  nginx_exporter             │ scrape: 15s     │
│  mysqld_exporter            └────────┬────────┘
│  check_site.sh (every 1m)           │
│  smart_backup.sh (heartbeat)        │
└─────────────────────────────────────┘
                                       │
                                       │ Grafana datasource
                                       ▼
                                ┌─────────────┐
                                │   Grafana    │
                                │  :3000       │
                                │              │
                                │ 6 dashboards │
                                │ 8 alert rules│
                                └──────┬──────┘
                                       │
                                       │ Telegram contact point
                                       ▼
                                 Telegram (chat_id)
```

### Alert Rules

| Alert | Condition | Response |
|-------|-----------|----------|
| CPU >85% | 5m avg | Check processes |
| RAM >90% | 5m avg | Check OOM |
| Disk <10% | 5m | Cleanup / resize |
| MySQL down | instantaneous | Check mariadb |
| Nginx down | instantaneous | Check nginx.service |
| Site down | instantaneous | Check HTTP 200 |
| VM down | instantaneous | Check victoria-metrics |
| Backup stale | >120min since last | Check smart_backup.sh |
| Cron no heartbeat | >2h since cron_last_run | Check cron |

---

## Security Layers

```
Layer 1 — Network:
  Cloudflare proxy (hides origin IP)
  Hetzner Firewall / AWS SG: ports 22, 80, 443 only

Layer 2 — SSH:
  PermitRootLogin no, MaxAuthTries 3, LogLevel VERBOSE
  Disable EC2 Instance Connect (AuthorizedKeysCommand stripped)

Layer 3 — Application:
  fail2ban: custom MODX /manager/ login filter
  fail2ban: custom Grafana login filter
  MODX core dirs: 0750, config: 0640 root:www-data

Layer 4 — System:
  sysctl hardening (ICMP redirects, martians, core dumps disabled)
  PAM password quality (libpam-passwdqc)
  Password max age: 90 days

Layer 5 — Secrets:
  Ansible Vault at rest
  .env on disk: 0600
  gitleaks on every commit
```

---

## CI/CD Pipeline

```
Trigger            Workflow              Jobs
───────            ────────              ────
Push / PR          CI                    ShellCheck, ruff, ansible-lint,
                                          Terraform checks (tflint+validate),
                                          OpenTofu validate, Trivy, gitleaks
                   ────────── 7 parallel ──────────

Manual dispatch    Deploy                Setup → secrets → deploy.sh / destroy
                   Rollback              Get IP → confirm → RESTORE_ALL.sh
                                          → Telegram

Schedule 07:05     Drift Detection       terraform plan -detailed-exitcode
Daily                                       (AWS prod only)

Schedule Mon 10:00 Backup Test           Provision Hetzner → Ansible deploy
Manual                                      → Tests (DB/Web/MODX/cart/SMTP)
                                            → DAST scan (nuclei)
                                            → Lynis audit → Destroy
                                            → Telegram report

Bot events         Renovate              Dependency updates (auto PRs)
                   Infracost App         Cost estimate comments on PRs
```

---

## Project Layout

```
DreamSeed/
├── deploy.sh              # Orchestrator (Terraform → Ansible → checks)
├── terraform/
│   ├── aws/               # EC2 + SG + key_pair + optional EIP
│   └── hetzner/           # Server + firewall + primary IP
├── ansible/
│   ├── playbook-01-base.yml ... playbook-07-security.yml
│   └── group_vars/all.yml
├── ansible-roles/         # 16 custom roles
├── scripts/               # Backup, restore, Telegram bot, health checks
├── .github/workflows/     # 5 workflows + Renovate + Infracost App
├── secrets/               # gitignored: .env, rclone.conf, tfstate-backup
└── configs/               # fail2ban jails
```
