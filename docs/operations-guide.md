# Operations Guide

> Day-to-day maintenance procedures for DreamSeed infrastructure.
> Not incident response — see `runbook.md` for that.

---

## Deploy Troubleshooting

### SSH timeout during Terraform stage

```bash
# Check if server is reachable
ssh -o ConnectTimeout=5 ubuntu@<ip> "echo OK"

# If unreachable after 5+ min → check cloud console (AWS/Hetzner)
#   AWS: console → EC2 → instance → "Get screenshot" (shows boot log)
#   Hetzner: console → server → "VNC" (shows boot log)
```

Common causes:

- **AWS:** Security group not attached, wrong VPC, EBS volume stuck
- **Hetzner:** Firewall blocking your IP, image not found

Fix: `./deploy.sh <target> -x` → fix the issue → repeat deploy.

### cloud-init hang (step waits 5+ min)

```bash
# SSH in when it eventually comes up, check what failed:
sudo journalctl -u cloud-init --no-pager -n 100
sudo cat /var/log/cloud-init-output.log
```

If Hetzner `user_data` script failed (e.g., `apt update` timeout):

- The cloud-init script is in `terraform/hetzner/cloud-init.tftpl` (template rendered by Terraform `templatefile()`, see `main.tf`)
- Common: apt repo timeout, `ADDITIONAL_SSH_KEYS` contains invalid key
- Fix: fix the issue, then `./deploy.sh <target> -n -i <ip> --no-dns` (re-run Ansible only)

### certbot SSL failure

Playbook 02 (web) handles SSL. Three modes, tried in order:

1. **Restore from `secrets/ssl/`** — copies cert files from local repo
2. **Cloudflare DNS-01** — requires `CLOUDFLARE_API_TOKEN` to be set
3. **Self-signed** — fallback for origin cert (Cloudflare edge serves real cert)

```
ssl: mode=MODE → details
  MODE=local-restore   → cert restored from secrets/ssl/
  MODE=dns-cloudflare  → cert issued via DNS-01 challenge
  MODE=self-signed     → fallback for origin (Cloudflare handles edge SSL)
```

If SSL fails → check:

```bash
# Is Cloudflare token valid?
curl -s -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  https://api.cloudflare.com/client/v4/user/tokens/verify

# Does DNS point to server?
dig +short @8.8.8.8 dreamseed.online

# Compare with actual server IP
SSH into server: curl -s ifconfig.me
```

If DNS hasn't propagated → wait 5-10 min and re-run: `./deploy.sh <target> -n -i <ip> --no-dns`

---

### Ansible playbook fails mid-deploy

Check the last playbook output. Common failures:

| Symptom | Cause | Fix |
|---------|-------|-----|
| `apt` lock timeout | cloud-init still running | Wait, re-run with `-i <ip> --no-dns` |
| `no_log: true` task fails | MariaDB/Grafana password wrong | Check `secrets/.env` |
| Jinja2 undefined variable | DEPLOY_VARS_TMP missing a key | Check logs — `cat` the temp vars file |
| SSH connection timeout mid-run | Server overloaded | Add `-p` (parallel mode) to speed through phases |

Re-run from last success:

```bash
# After fixing the cause, re-deploy config only:
./deploy.sh <target> -n -i <ip>
# This skips Terraform + cloud-init, re-runs all 7 playbooks
```

---

### `check_services` fails after deploy

The final health check runs all services. Check the specific failure:

```bash
# If DB tables < 50: restore role may have skipped (rclone.conf missing?)
ls secrets/rclone.conf

# If site returns 403: restore incomplete or MODX config wrong
SSH → sudo tail /var/log/nginx/error.log

# If vmagent fails: Grafana Cloud credentials missing or wrong
SSH → sudo journalctl -u vmagent --no-pager -n 20
```

---

## Managing Grafana Alert Rules

### Where alerts are defined

All 24 alert rules live in one file:

```
ansible-roles/grafana/templates/grafana-alerts.yaml.j2
```

This is a Jinja2 template rendered by Ansible and provisioned into Grafana on every deploy.

### Alert structure

```yaml
groups:
  - name: dreamseed
    rules:
      - alert: MySQL Down
        expr: mysql_up == 0
        for: 2m
        labels:
          severity: critical
        annotations:
          summary: "MariaDB is down on {{ $labels.env }}"
```

Key fields:

- `expr` — PromQL expression
- `for` — how long condition must hold before alert fires
- `labels.severity` — `critical` / `warning` / `info`
- `annotations.summary` — shown in Telegram

### Design rules (from CLAUDE.md)

- **`noDataState: Alerting`** — only for critical services with always-on metrics (MySQL, Nginx, PHP-FPM, Site, VM, Backup Cron)
- **`noDataState: OK`** — for push/probe metrics (admin-login, ms2, db-tables, modx-core, ssl-expiry, backup-verify)
- **`for:`** — scraped 15s → 2m, pushed 1m → 10m, probes 15m → 6m, backup-verify 24h → 5m
- **`repeat_interval`** — critical: 1h, warning/info: 4h

### How to add a new alert

1. Open `ansible-roles/grafana/templates/grafana-alerts.yaml.j2`
2. Add a new rule under `rules:` in the appropriate group
3. If it needs a new metric → update the script that pushes it (e.g., `check_services.sh` for service checks, `smart_backup.sh` for backup metrics)
4. Update the VictoriaMetrics recording rule if needed (`victoria-metrics@.service.j2`)
5. Bump the alert count in:
   - `ansible/group_vars/all.yml` (if there's a count variable)
   - `docs/runbook.md` (alert reference table, line ~173)
   - `docs/architecture.md` (alert rules table, line ~175)
6. Deploy: `./deploy.sh <target> -n -i <ip> --no-dns`

---

### How to test an alert

```bash
# SSH into server, force the condition:

# Example: trigger High CPU
stress --cpu 2 --timeout 120

# Example: stop MySQL
sudo systemctl stop mariadb

# Watch alert state in Grafana:
curl -s http://127.0.0.1:3000/api/alertmanager/grafana/api/v2/alerts
# (requires auth — use browser Grafana UI instead)

# The alert should fire after `for:` duration + scrape interval (~2-3 min)
```

---

## Adding a New Ansible Role

### Convention

All roles live in `ansible-roles/` — not `ansible/roles/` (overridden in `ansible.cfg`).

### Minimum structure

```bash
ansible-roles/<name>/
├── tasks/
│   └── main.yml          # Required — entry point
├── templates/             # .j2 files (optional)
├── files/                 # Static files (optional)
├── handlers/
│   └── main.yml          # Service restarts (optional)
├── defaults/
│   └── main.yml          # Default variable values (optional)
└── vars/
    └── main.yml          # Override variables (optional)
```

### Steps

1. **Create the role directory:**

   ```bash
   mkdir -p ansible-roles/<name>/{tasks,templates,files,handlers,defaults,vars}
   ```

2. **Write tasks:** Always use `become: true` where needed. Follow existing patterns:

   ```yaml
   # tasks/main.yml
   - name: Install <package>
     ansible.builtin.apt:
       name: <package>
       state: present
   ```

3. **Register in a playbook:** Pick the right one:

   - `playbook-01-base.yml` — packages, users, system config
   - `playbook-02-web.yml` — web server config
   - `playbook-03-db.yml` — database
   - `playbook-04-security.yml` — security
   - `playbook-05-monitor.yml` — monitoring
   - `playbook-06-backup.yml` — backup/restore
   - `playbook-07-grafana.yml` — Grafana

   Add a single include:

   ```yaml
   - name: Configure <something>
     ansible.builtin.include_role:
       name: <name>
   ```

4. **Add variables to `ansible/group_vars/all.yml`** if the role needs config

5. **Deploy:** `./deploy.sh <target> -n -i <ip> --no-dns`

### Gotchas (from CLAUDE.md)

- `inject_facts_as_vars = False` — use `{{ ansible_facts['memtotal_mb'] }}`, not `{{ ansible_memtotal_mb }}`
- `become` is NOT set at playbook level (except 04/05/06) — opt in with `become: true` per task
- Use `ansible.builtin.` modules, not bare `command:` or `shell:` unless necessary
- `no_log: true` on any task handling passwords, tokens, keys
- No collections other than `ansible.mysql` and `ansible.posix`

---

## Security Incident Recovery

### Scenario A: SSH key compromised

If a deploy key or personal SSH key is compromised:

```bash
# 1. Generate new key pair
ssh-keygen -t ed25519 -f ~/.ssh/new_deploy_key -C "github-actions@dreamseed"

# 2. Update GitHub Secrets (SSH_PRIVATE_KEY)
#    GitHub → Settings → Secrets → Actions → SSH_PRIVATE_KEY

# 3. Redeploy to push new key to all servers
./deploy.sh prod -n -i <ip>

# 4. Remove old key from:
#    - ~/.ssh/authorized_keys on all servers
#    - GitHub deploy keys
#    - Hetzner Cloud SSH keys panel
```

### Scenario B: Telegram bot token compromised

```bash
# 1. Revoke old token: BotFather → /revoke → select bot
# 2. Create new token: BotFather → /token → select bot
# 3. Update:
#    - secrets/.env (TG_TOKEN)
#    - GitHub Secret (TG_TOKEN)
# 4. Redeploy: ./deploy.sh prod -n -i <ip>
# 5. Notify the team (old token can no longer send messages)
```

### Scenario C: Cloudflare API token leaked

```bash
# 1. Revoke the token in Cloudflare Dashboard
#    My Profile → API Tokens → ... → Delete

# 2. Create new token (Permissions: Zone:DNS:Edit, Zone:Zone:Read)
#    Scope: dreamseed.online zone only (minimal scope)

# 3. Update:
#    - secrets/.env (CLOUDFLARE_API_TOKEN)
#    - GitHub Secret (CLOUDFLARE_API_TOKEN)

# 4. Redeploy to renew any certs that used the old token
./deploy.sh prod -n -i <ip>
```

### Scenario D: MariaDB root password leaked

The root password is NOT stored in secrets/.env — it's generated during deploy and stored in `/root/.my.cnf` on the server. If the server itself is compromised:

```bash
# 1. Rebuild the server (cannot just change password — there's no access)
./deploy.sh prod -x   # destroy
./deploy.sh prod -n   # rebuild

# 2. All data is restored from backup during deploy
# 3. New root password is auto-generated
```

If only the backup user credentials leaked:

```bash
# 1. SSH into server
# 2. Create new backup user with new password
sudo mysql -e "CREATE USER IF NOT EXISTS 'backup'@'localhost' IDENTIFIED BY '<newpass>';"
sudo mysql -e "GRANT SELECT, LOCK TABLES, PROCESS, SHOW VIEW, TRIGGER, EVENT ON *.* TO 'backup'@'localhost';"

# 3. Update ~/.my.cnf with new password
# 4. Update smart_backup.sh to use the new user
```

### Scenario E: Full server compromise

If an attacker gains root access to the server:

```bash
# 1. DO NOT SSH in — they may have modified the SSH config
# 2. Snapshot the server (if needed for forensics):
#    AWS: console → EC2 → instance → actions → image and template → create image
#    Hetzner: console → server → snapshots → create snapshot

# 3. REBUILD from scratch:
./deploy.sh prod -x   # destroy
./deploy.sh prod -n   # fresh deploy + restore from backup

# 4. After rebuild:
#    - Rotate ALL secrets (TG_TOKEN, DB_PASS, GRAFANA_PASS, CLOUDFLARE_API_TOKEN)
#    - Revoke and recreate Cloudflare API token
#    - Check GitHub for any modified workflows or secrets
#    - Review audit logs (AWS CloudTrail / Hetzner Audit Log)

# 5. Investigate how they got in:
sudo journalctl -u sshd --no-pager | grep "Failed password"
sudo cat /var/log/fail2ban.log
```

### Prerequisites for recovery

Store these **outside the repo** (password manager / team vault):

- `~/.vault_pass_dreamseed` — needed to decrypt `secrets/.env`
- GitHub admin access — to update secrets
- Cloudflare Dashboard login — to rotate API tokens
- BotFather access — to rotate Telegram bot token
- Hetzner / AWS console access — to destroy/rebuild servers
