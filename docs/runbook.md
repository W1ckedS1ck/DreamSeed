# Incident Response Runbook — DreamSeed

> For **junior support staff**. Covers all alerts from all layers (Grafana, Better Stack, Scripts).
> All notifications arrive in a single Telegram chat.
>
> Continuously updated. Changelog: [Releases](https://github.com/W1ckedS1ck/DreamSeed/releases).

## Table of Contents

- [Prerequisites — before you start](#prerequisites--before-you-start)
- [First 5 minutes](#first-5-minutes)
- [How to connect](#how-to-connect)
- [Alert Channels Overview](#alert-channels-overview)
- [Layer 1: Grafana Alerts (G1–G29)](#-layer-1-grafana-alerts)
- [Layer 2: Better Stack Alerts (B1–B10)](#-layer-2-better-stack-alerts)
- [Layer 3: Script Direct Alerts (S1–S2)](#-layer-3-script-direct-alerts)
- [Layer 4: CI/CD & Infrastructure Alerts (D1)](#-layer-4-cicd-and-infrastructure-alerts)
- [Quick Reference — What to do first](#quick-reference--what-to-do-first)
- [Emergency contacts](#emergency-contacts)
- [Last resort — full restore](#last-resort--full-restore)

---

## Prerequisites — before you start

Before any alert arrives, make sure you have access to everything below:

### 🔑 SSH key — your own key

You need your **personal SSH public key** added to the servers.

**Step 1 — Generate your key (if you don't have one):**

```bash
ssh-keygen -t ed25519 -C "your@email.com"
# Accept defaults, optionally set a passphrase
```

**Step 2 — Get your public key added:**
There are two ways — the first time, ask a team member:

- **Option A (via CI — automatic):** Send your public key (`cat ~/.ssh/id_ed25519.pub`) to a team member. They'll add it to GitHub secret `USER_SSH_PUBLIC_KEY`. After the next deploy, Ansible's security role will add it to all servers automatically.
- **Option B (manual — immediate):** Ask someone who already has access to run:

  ```bash
  ssh -i ~/.ssh/Vitali.pem ubuntu@<ip> "echo '$(cat ~/.ssh/id_ed25519.pub)' >> ~/.ssh/authorized_keys"
  ```

**Step 3 — Add an SSH alias for convenience:**
Add to `~/.ssh/config`:

```
Host prod
  HostName <prod-ip>
  User ubuntu
  IdentityFile ~/.ssh/id_ed25519

Host dev-hetz
  HostName <dev-hetz-ip>
  User ubuntu
  IdentityFile ~/.ssh/id_ed25519
```

**Step 4 — Verify it works:**

```bash
ssh dev-hetz "echo OK"
ssh prod "echo OK"
```

> 💡 The first time you connect, you'll see `WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED` if the server was rebuilt. This is normal — run `ssh-keygen -R <ip>` and retry.

### 🌐 Sites & dashboards

| Site | URL | What for |
|------|-----|----------|
| DreamSeed (prod) | <https://dreamseed.online> | Check if site is up |
| DreamSeed (dev) | <https://hetz.vitalikuts.online> | Dev/testing environment |
| Grafana (on-server) | <https://dreamseed.online/grafana/> | View dashboards + alerts |
| Grafana Cloud (prod) | <https://dreamseed.grafana.net> | Hosted metrics + Synthetic Monitoring for prod |
| Grafana Cloud (dev) | <https://vitalikuts.grafana.net> | Hosted metrics + SM for dev-aws / dev-hetz |
| Better Stack | <https://status.dreamseed.online> | Uptime status page |
| Telegram bot | DM to the bot | `/status`, `/backups`, `/start` — live server/backup status without SSH |
| Hetzner Cloud | <https://console.hetzner.cloud> | Server console + restart |
| Hetzner Cloud (prod) | <https://console.hetzner.cloud> | Server console + restart (prod-hetz = live prod) |
| Cloudflare | <https://dash.cloudflare.com> | DNS + SSL |
| GitHub | <https://github.com/W1ckedS1ck/DreamSeed> | CI/CD runs, workflows, secrets |

> 💡 **Tip:** Bookmark these. You'll need them during incidents.

### 📦 Telegram alerts

All alerts arrive in a single Telegram chat:

- 🔴 = new alert (firing)
- ✅ = resolved

If you're not in the chat — ask to be added.

### 🧰 What you can do from day 1

- ✅ Read logs and check service status
- ✅ Run `check_services.sh` and `check_site.sh` manually
- ✅ Restart services (nginx, PHP-FPM, MariaDB, Grafana, exporters)
- ✅ Run backup verification
- ✅ Restore from latest backup using `RESTORE_ALL.sh`

### ⚠️ What needs practice

- ⚠️ Terraform Cloud / deploy.sh (prod deploy — requires experience)
- ⚠️ Editing secrets or rclone config
- ⚠️ Adding/modifying Grafana alert rules (Ansible provisioning)

---

## First 5 minutes

1. **Check Telegram** — which alert fired? Look at the title.
2. **Open the alert in Grafana** — follow the link from Telegram or go to the on-server alert list: `https://dreamseed.online/grafana/alerting/list` (Grafana Cloud `https://dreamseed.grafana.net/alerting/list` hosts only Synthetic Monitoring rules)
3. **Find the server IP** — the alert message shows the domain or instance label
4. **SSH into the server** — see below for connection details
5. **Follow the section below** that matches your alert title

---

## How to connect

All commands in this document run **on the server via SSH**.
Use your **own SSH key** (set up in the prerequisites above).

### Connect using the SSH alias (recommended)

```bash
ssh dev-hetz   # dev
ssh prod       # prod
```

### Connect directly (if alias not set up)

```bash
ssh ubuntu@dev-ip
```

### If SSH fails → Server may be down

Use cloud console to restart:

| Cloud | Console |
|-------|---------|
| Hetzner (dev) | <https://console.hetzner.cloud> |
| Hetzner Cloud (prod-hetz) | <https://console.hetzner.cloud> |

---

## Alert Channels Overview

| Layer | Prefix | Source | What it monitors | Survives server death? |
|-------|--------|--------|-----------------|----------------------|
| 1 | G1–G29 | Grafana (on-server) | CPU, RAM, Disk, Swap, Nginx/Apache, MySQL, PHP-FPM, Site, Site slow, MODX core, MODX cache, VictoriaMetrics, Redis, Backup cron, Site check, Service check, SSL, Admin login, MiniShop2, DB tables, Backup verify, VMAgent, Cloud Upload, Fail2ban, Promtail, Node Exporter, Telegram Bot (+ 2 metric-only sections) | ❌ No |
| 2 | B1–B10 | Better Stack (cloud) | HTTP uptime (3 monitors), Cron heartbeats (6 heartbeats), Grafana Cloud SM | ✅ Yes |
| 3 | S1–S2 | Scripts (on-server) | Backup failures, GDrive upload failures | ❌ No |

All alerts → same Telegram topic.

---

## 🔴 Layer 1: Grafana Alerts

---

### G1. 🔴 High CPU

**Metric:** CPU usage > 85% for 5+ minutes
**Severity:** Warning
**Possible causes:** Traffic spike, stuck PHP process, runaway cron, CC attack

**Diagnose:**

```bash
# Top CPU consumers
top -b -n 1 | head -20

# Per-process CPU
ps aux --sort=-%cpu | head -10

# Load average
uptime

# Check for many PHP-FPM children
ps aux | grep php-fpm | wc -l
```

**Fix:**

- If PHP-FPM has many children → check `pm.max_children` in `/etc/php/*/fpm/pool.d/www.conf`
- If a specific process (e.g., `mysqldump`, `tar`) is spiking → wait, it will finish
- If sustained and unexplained → restart the service:

  ```bash
  sudo systemctl restart php*-fpm
  sudo systemctl restart nginx
  ```

- Check `/var/log/nginx/access.log` for unusual traffic patterns

---

### G2. 🔴 High RAM

**Metric:** RAM usage > 90% for 5+ minutes
**Severity:** Warning
**Possible causes:** Memory leak in PHP, MySQL buffer pool too large, traffic spike

**Diagnose:**

```bash
# Memory overview
free -h

# Top RAM consumers
ps aux --sort=-%mem | head -10

# Swap usage
swapon --show

# MySQL memory
sudo mysql -e "SHOW VARIABLES LIKE '%innodb_buffer_pool_size%';"
```

**Fix:**

- If MySQL is using too much → check `innodb_buffer_pool_size` in `/etc/mysql/mariadb.conf.d/` (should be ~25% of RAM)
- If PHP-FPM children accumulate → check `pm.max_requests` setting
- Temporary relief: restart PHP-FPM or MySQL

  ```bash
  sudo systemctl restart php*-fpm
  ```

- If swap is being used heavily → see Disk alert or add more RAM (upgrade server)

**Important:** The server has a 2GB swap file (created during provisioning). If swap is in use, the server is critically low on RAM.

---

### G3. 🔴 Low Disk Space

**Metric:** Available space on `/` < 10% for 5+ minutes
**Severity:** Warning (can lead to MySQL crash, failed backups, site down)
**Possible causes:** Old backups not rotated, log files too large, unexpected growth

**Diagnose:**

```bash
# Disk usage overview
df -h

# Largest directories
sudo du -sh /var/log/* | sort -rh | head -10
sudo du -sh /home/ubuntu/backups/* | sort -rh | head -5
sudo du -sh /var/www/html/* | sort -rh | head -5

# Log sizes
ls -lh /var/log/nginx/*.log /var/log/mysql/*.log 2>/dev/null
```

**Fix:**

- **Rotate logs now:**

  ```bash
  sudo logrotate -f /etc/logrotate.conf
  ```

- **Clean old backups (if backup dir is large):**

  ```bash
  ls /home/ubuntu/backups/project/ | wc -l
  ls /home/ubuntu/backups/db/ | wc -l
  # Manual cleanup if rotation hasn't kicked in
  rm -f $(ls -t /home/ubuntu/backups/project/*.tar.gz | tail -n +6)
  rm -f $(ls -t /home/ubuntu/backups/db/*.sql.gz | tail -n +16)
  ```

- **Clean VictoriaMetrics data (if old):**

  ```bash
  sudo du -sh /var/lib/victoria-metrics/
  # Retention is 3 months by default (vm_retention: 3 — VictoriaMetrics
  # treats a unitless value as months)
  ```

- **Find unexpected large files:**

  ```bash
  sudo find / -xdev -type f -size +100M -exec ls -lh {} \; 2>/dev/null
  ```

- If disk is critically full (< 5%), MySQL may crash. Restart it after freeing space:

  ```bash
  sudo systemctl restart mariadb
  ```

**Prevention:** The server rotates backups to max 5 project + 15 DB. Check that `rotate_files` in `smart_backup.sh` is working.

---

### G4. 🔴 MySQL Down

**Metric:** `mysql_up` = 0 (mysqld_exporter cannot reach MariaDB)
**Severity:** CRITICAL — site will show database errors
**Possible causes:** MariaDB crashed, disk full, out of memory, port blocked

**Diagnose:**

```bash
# Is MariaDB running?
sudo systemctl status mariadb

# Recent errors
sudo journalctl -u mariadb --no-pager -n 50

# MySQL error log
sudo tail -50 /var/log/mysql/error.log 2>/dev/null || sudo tail -50 /var/log/mariadb/error.log 2>/dev/null
```

**Fix:**

```bash
# Try restart
sudo systemctl restart mariadb

# If restart fails, check disk space first (alert #3)
df -h

# If disk is full → free space (see Disk alert), then restart

# If mysqld_exporter failed but MariaDB is running:
sudo systemctl restart mysqld_exporter

# If MariaDB won't start at all → check error log for corruption
# Last resort: restore from latest backup
```

**Check site after fixing:**

```bash
curl -sS -o /dev/null -w "%{http_code}" https://dreamseed.online
```

---

### G5. 🔴 PHP-FPM Down

**Metric:** `php_fpm_up` = 0 (socket not found or process not running)
**Severity:** CRITICAL — site returns blank page or 502
**Possible causes:** PHP-FPM crashed, OOM killer, config error after deploy
**Note:** fires on a real `php_fpm_up=0` value. If it fires together with "Site Health Check Not Running" (G12) that was quiet before — the checker (`check_site.sh`) died, PHP-FPM is likely fine.

**Diagnose:**

```bash
# Is PHP-FPM running?
sudo systemctl status php*-fpm

# PHP socket exists?
ls -la /var/run/php/php*-fpm.sock

# Recent logs
sudo journalctl -u php*-fpm --no-pager -n 30

# PHP error log
sudo tail -20 /var/log/php*-fpm.log 2>/dev/null
```

**Fix:**

```bash
# Restart
sudo systemctl restart php*-fpm

# If it fails to start → check config
sudo php-fpm$(ls /etc/php | head -1) -t

# Check for OOM in dmesg
sudo dmesg | grep -i "oom\|php" | tail -10
```

---

### G6. 🔴 Nginx Down / Apache Down

**Metric:** `nginx_up` = 0 _or_ `apache_up` = 0 (which one fired depends on what's deployed)
**Severity:** CRITICAL — site is down
**Possible causes:** Config error after deploy, port conflict, OOM, cert issue

**Step 1 — Determine which web server is installed:**

```bash
# Check which one is active
if systemctl is-active nginx &>/dev/null; then
    echo "Web server: NGINX"
    WS="nginx"
elif systemctl is-active apache2 &>/dev/null; then
    echo "Web server: APACHE"
    WS="apache2"
else
    echo "NEITHER ACTIVE — both may be down"
fi
```

Alternatively, just check both:

```bash
sudo systemctl status nginx   2>/dev/null | head -5
sudo systemctl status apache2 2>/dev/null | head -5
```

---

**Step 2 — Diagnose (use the right commands for your web server):**

=== For Nginx ===

```bash
# Is it running?
sudo systemctl status nginx

# Config test
sudo nginx -t 2>&1

# Recent logs
sudo journalctl -u nginx --no-pager -n 30
sudo tail -30 /var/log/nginx/error.log
```

=== For Apache ===

```bash
# Is it running?
sudo systemctl status apache2

# Config test
sudo apache2ctl -t 2>&1

# Recent logs
sudo journalctl -u apache2 --no-pager -n 30
sudo tail -30 /var/log/apache2/error.log

# Check enabled sites
ls /etc/apache2/sites-enabled/
```

=== For both ===

```bash
# Port 80/443 listeners — who has them?
sudo ss -tlnp | grep -E ':(80|443) '
```

---

**Step 3 — Fix:**

=== For Nginx ===

```bash
# If config is broken → fix, test, restart
sudo nginx -t 2>&1
sudo systemctl restart nginx
```

=== For Apache ===

```bash
# If config is broken → fix, test, restart
sudo apache2ctl -t 2>&1
sudo systemctl restart apache2
```

=== For both (port conflict) ===

```bash
# If BOTH are installed, only one should be active
# Check who's on port 80/443
sudo ss -tlnp | grep -E ':(80|443) '

# Stop and disable the wrong one:
sudo systemctl stop   nginx && sudo systemctl disable nginx     # if Apache should run
sudo systemctl stop   apache2 && sudo systemctl disable apache2 # if Nginx should run

# Restart the correct one
sudo systemctl restart nginx    # or apache2
```

=== SSL certs ===

```bash
# Check if LetsEncrypt cert exists (Cloudflare DNS-01 validation)
sudo certbot certificates 2>/dev/null || echo "No local certs (using LetsEncrypt + Cloudflare DNS-01)"

# Renewal is automatic; hook restarts web server on renewal
```

---

### G7. 🔴 Site Down

**Metric:** `site_up` = 0 (HTTP probe to local nginx via SNI; public/edge reachability is covered by the Better Stack monitor)
**Severity:** CRITICAL — users cannot access the site
**Possible causes:** Nginx down, PHP-FPM down, MySQL down, MODX error, application crash
**Note:** fires on a real `site_up=0` value. If it fires together with "Site Health Check Not Running" (G12) that was quiet before — the checker (`check_site.sh`) died, the site is likely fine.

**Diagnose:**

```bash
# First check which layer is failing
curl -sS -o /dev/null -w "%{http_code}" https://dreamseed.online

# If 502 → PHP-FPM issue (see alert #5)
# If 503 → maintenance mode or upstream issue
# If 000/DNS → server may be unreachable

# Check if PHP-FPM is running
sudo systemctl status php*-fpm

# Check Nginx error log
sudo tail -50 /var/log/nginx/error.log

# Check site curl verbose
curl -v https://dreamseed.online 2>&1 | head -30
```

**Fix:**
Site Down is usually a symptom of one of the other alerts (MySQL, PHP-FPM, Nginx). Fix the underlying issue first.

If ALL of MySQL/PHP-FPM/Nginx are running but site still returns 5xx:

```bash
# Check MODX core files (see alert #8)
ls -la /var/www/html/core/model/modx/modx.class.php
ls -la /var/www/html/manager/config.core.php

# Clear MODX cache
sudo rm -rf /var/www/html/core/cache/*

# Check disk space (alert #3)
df -h

# Check PHP error log
sudo tail -50 /var/log/php*-fpm.log 2>/dev/null
```

---

### G8. 🔴 MODX Core Missing

**Metric:** `modx_core_ok` = 0 (`manager/config.core.php` or `core/model/modx/modx.class.php` not found)
**Severity:** CRITICAL — MODX application broken
**Possible causes:** Corrupted deploy, filesystem issue, accidental deletion

**Diagnose:**

```bash
# Check if core files exist
ls -la /var/www/html/core/model/modx/modx.class.php
ls -la /var/www/html/manager/config.core.php

# Check directory permissions
ls -la /var/www/html/core/
ls -la /var/www/html/manager/

# Check if project directory is empty
ls /var/www/html/ | head -20
```

**Fix:**

- If files are missing → **restore from latest backup**:

  ```bash
  # List available backups
  ls -lt /home/ubuntu/backups/project/ | head -5

  # Extract latest project backup (names are DreamSeed_<date>.tar.gz — pick the newest)
  sudo tar -xzf "$(ls -t /home/ubuntu/backups/project/DreamSeed_*.tar.gz | head -1)" -C /var/www/
  sudo chown -R www-data:www-data /var/www/html/
  ```

- If permissions are wrong → run MODX perms from security role:

  ```bash
  sudo find /var/www/html -type f -exec chmod 644 {} \;
  sudo find /var/www/html -type d -exec chmod 755 {} \;
  sudo chown -R www-data:www-data /var/www/html/
  ```

---

### G9. 🔴 MODX Cache Not Writable

**Metric:** `modx_cache_ok` = 0 (`core/cache/` directory not writable)
**Severity:** Warning — site performance will degrade, cached data cannot be written
**Possible causes:** Wrong permissions after deploy/restore, filesystem full, SELinux

**Diagnose:**

```bash
# Check cache directory permissions
ls -la /var/www/html/core/ | grep cache

# Test write
sudo -u www-data touch /var/www/html/core/cache/test_write && \
  rm /var/www/html/core/cache/test_write && \
  echo "WRITABLE" || echo "NOT WRITABLE"

# Check disk space
df -h /
```

**Fix:**

```bash
# Fix ownership
sudo chown -R www-data:www-data /var/www/html/core/cache/

# Fix permissions
sudo chmod -R 755 /var/www/html/core/cache/

# If using SELinux (check with getenforce), restore context:
# sudo restorecon -Rv /var/www/html/core/cache/
```

---

### G10. 🔴 VictoriaMetrics Down

**Metric:** `victoria_up` = 0 (pushed by `check_site.sh` every 1 min — also fires when the alert query itself errors, i.e. VM unreachable)
**Severity:** Critical — no metrics collected, all Grafana alerts may stop working
**Possible causes:** OOM, disk full, VictoriaMetrics crashed
**Note:** if it fires together with "Site Health Check Not Running" (G12) + "Site Down" (G7) + "PHP-FPM Down" (G5) that were quiet before — `check_site.sh` itself died; VictoriaMetrics is likely fine.

**Diagnose:**

```bash
# Is VictoriaMetrics running?
sudo systemctl status victoria-metrics

# Health check
curl -s http://127.0.0.1:8428/health

# Recent logs
sudo journalctl -u victoria-metrics --no-pager -n 30

# Disk space (VictoriaMetrics stores data)
df -h /var/lib/victoria-metrics/
```

**Fix:**

```bash
# Restart
sudo systemctl restart victoria-metrics

# If OOM-killed → check memory:
sudo dmesg | grep -i "oom\|victoria" | tail -5

# If VictoriaMetrics was restarted → check_site.sh will repopulate metrics within 1 minute
```

---

### G11. 🔴 Backup Cron Not Running

**Metric:** `cron_last_run_backup` timestamp > 90 minutes old (pushed by `smart_backup.sh` at every run — even a failed run refreshes it)
**Severity:** Warning — backups may have stopped
**Possible causes:** Cron service stopped, script error, server busy, script stuck

**Diagnose:**

```bash
# Is cron running?
sudo systemctl status cron

# Check cron config
crontab -l | grep smart_backup

# Check last backup log
tail -20 /home/ubuntu/backups/logs/backup_*.log 2>/dev/null | tail -20

# Check if backup script got stuck
ps aux | grep smart_backup
```

**Fix:**

```bash
# If cron not running:
sudo systemctl restart cron

# If script failed in the past → check logs for error
cat /home/ubuntu/backups/logs/backup_$(date +%Y-%m-%d).log 2>/dev/null

# Manually run backup to test
cd /home/ubuntu/Scripts && bash smart_backup.sh

# Check heartbeat ping (should show success in Better Stack or in log)
tail -5 /home/ubuntu/backups/logs/backup_$(date +%Y-%m-%d).log
```

---

### G12. 🔴 Site Health Check Not Running

**Metric:** `check_site_last_run` > 180 seconds old
**Severity:** Warning — `check_site.sh` timer may have stopped
**Possible causes:** `check_site.sh` stuck in loop, systemd timer failed, VictoriaMetrics unreachable
**Note:** 🔔 Canary — fires and **keeps firing** until `check_site.sh` runs again. When it fires together with Site Down (G7) / PHP-FPM Down (G5) / VictoriaMetrics Down (G10) that were quiet before, the checker died and those correlated alerts are false — fix the checker, not the services.

**Diagnose:**

```bash
# Check systemd timer (primary — runs every minute)
sudo systemctl status check-site.timer
sudo systemctl status check-site.service

# Check services timer (secondary — runs every 5 min)
sudo systemctl status check-services.timer
sudo systemctl status check-services.service

# Run manually to test
bash /usr/local/bin/check_site.sh 2>&1

# Check check_services
bash /home/ubuntu/Scripts/check_services.sh 2>&1

# Check timer logs
sudo journalctl -u check-site.service --no-pager -n 10
```

**Fix:**

```bash
# Restart timers
sudo systemctl restart check-site.timer
sudo systemctl restart check-services.timer

# If VictoriaMetrics unreachable (metric push will fail):
sudo systemctl restart victoria-metrics
curl -s http://127.0.0.1:8428/health
```

---

### G13. 🔴 SSL Cert Expiring Soon

**Metric:** `ssl_days_remaining` < 7 days
**Severity:** Info — certificate about to expire
**Note:** If using Cloudflare edge SSL (Full/Strict), this alert applies to the origin certificate (LetsEncrypt or self-signed), not Cloudflare's edge cert.

**Diagnose:**

```bash
# Check local certificate
sudo certbot certificates 2>/dev/null || echo "No LE cert"
ls -la /etc/letsencrypt/live/$(hostname | sed 's/dreamseed-//')/fullchain.pem 2>/dev/null

# Check days remaining manually
openssl x509 -enddate -noout -in /etc/letsencrypt/live/*/fullchain.pem 2>/dev/null
```

**Fix:**

```bash
# Renew LetsEncrypt
sudo certbot renew

# If behind Cloudflare with DNS-01:
sudo certbot renew --preferred-challenges dns-01

# If neither local nor edge cert is reachable, nothing is pushed and
# noDataState: OK keeps the alert silent (by design)
```

---

### G14. 🔴 Admin Login Failed

**Metric:** `admin_login_ok` = 0 (probe every 15 min to `/manager/` returned no MODX login page)
**Severity:** Warning — admin panel may be down
**Possible causes:** MODX core issue, PHP error, .htaccess blocking, session table corruption

**Diagnose:**

```bash
# Check admin page directly
curl -sk --max-time 10 https://localhost/manager/ | grep -ci "modx\|login"

# Check PHP error log
sudo tail -30 /var/log/php*-fpm.log 2>/dev/null

# Check MODX session table
mysql modx_db -e "SELECT COUNT(*) FROM modx_session;"
```

**Fix:**

```bash
# Clear MODX cache
sudo rm -rf /var/www/html/core/cache/*

# If session table is corrupted → truncate
mysql modx_db -e "TRUNCATE modx_session;"

# Restart PHP-FPM
sudo systemctl restart php*-fpm
```

---

### G15. 🔴 MiniShop2 Write Failed

**Metric:** `db_write_ok` = 0 (probe every 15 min — INSERT+DELETE into `modx_ms2_orders` — failed)
**Severity:** Warning — database write path may be broken
**Possible causes:** MySQL permissions changed, table corruption, disk full, foreign key constraint

**Diagnose:**

```bash
# Test write manually
mysql modx_db -e "INSERT INTO modx_ms2_orders (context, user_id, createdon) VALUES ('test', 0, NOW()); SELECT LAST_INSERT_ID();"
mysql modx_db -e "DELETE FROM modx_ms2_orders WHERE context = 'test' AND user_id = 0;"

# Check table structure
mysql modx_db -e "SHOW CREATE TABLE modx_ms2_orders\G" | head -10

# Check disk space
df -h
```

**Fix:**

- If disk full → see Low Disk Space alert
- If permissions → check MySQL grants for `modx_user`
- If table corrupted → restore from backup

---

### G16. 📊 Overall Health Check Failed (metric, not a Grafana alert)

**Metric:** `dreamseed_health_overall` = 0 (composite check from `check_services.sh`)
**Severity:** High — one or more services or checks are failing
**Note:** This is not a Grafana alert rule — it's a metric pushed by `check_services.sh`. Fail2ban, Promtail, Node Exporter and Telegram Bot now have their own Grafana alerts (G26–G29); this composite metric is the quick "something is broken" overview. Review the latest script output to see which specific service failed.

**Diagnose:**

```bash
# Run the full check manually
bash /home/ubuntu/Scripts/check_services.sh 2>&1

# Check which metrics were pushed
curl -sf http://127.0.0.1:8428/api/v1/query?query=dreamseed_health_overall
```

**Fix:** Address each failing check identified by `check_services.sh`.

---

### G17. 📊 Site HTTP Status Critical (metric, not a Grafana alert)

**Metric:** `site_http_status` != 1 (site returned non-200/301 HTTP code)
**Severity:** High — site not serving correctly
**Possible causes:** Nginx issue, PHP error, application crash

**Diagnose:**

```bash
# Check HTTP code
curl -sk -o /dev/null -w "%{http_code}" https://localhost/

# Check Nginx error log
sudo tail -30 /var/log/nginx/error.log
```

**Fix:** Depends on the HTTP code. See Site Down alert (#7) for detailed steps.

---

### G18. 🔴 Database Tables Below Threshold

**Metric:** `database_tables` < 50 tables in `modx_db`
**Severity:** Info — DB may be empty or not restored
**Possible causes:** Restore failed, wrong DB name, tables dropped, backup corrupted

**Diagnose:**

```bash
# Count tables
mysql -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='modx_db';"

# List existing tables
mysql -N -e "SELECT table_name FROM information_schema.tables WHERE table_schema='modx_db';" | head -20

# Check DB size
mysql -e "SELECT table_schema, ROUND(SUM(data_length+index_length)/1024/1024,2) AS 'MB' FROM information_schema.tables WHERE table_schema='modx_db' GROUP BY table_schema;"
```

**Fix:**

```bash
# Restore from latest backup
sudo bash /home/ubuntu/Scripts/RESTORE_ALL.sh --auto-latest
```

---

### G19. 🔴 Backup Verification Failed

**Metric:** `backup_verification_ok` = 0 (local or cloud backup verification failed)
**Severity:** Warning — disaster recovery may be compromised
**Possible causes:** Corrupted backup file, rclone failure, GDrive quota

**Diagnose:**

```bash
# Check verification log
cat /home/ubuntu/backups/logs/verify_$(date +%Y-%m-%d).log 2>/dev/null

# Run verification manually
bash /home/ubuntu/Scripts/verify_backups.sh 2>&1

# Check GDrive backup list
rclone lsf gdrive-crypt:DreamSeed/backups/project/ --max-depth 1
rclone lsf gdrive-crypt:DreamSeed/backups/db/ --max-depth 1
```

**Fix:**

- If local backup invalid → check smart_backup.sh logs
- If cloud backup missing → check rclone config and GDrive quota
- If rclone auth expired → update secrets/rclone.conf and redeploy

---

### G20. 🔴 Swap Thrashing Detected

**Metric:** `rate(node_vmstat_pswpin[5m])` > 100 pages/s
**Severity:** Warning — server under memory pressure
**Possible causes:** RAM exhausted, memory leak, too many concurrent PHP processes

**Diagnose:**

```bash
# Check swap usage
swapon --show
free -h

# Top memory consumers
ps aux --sort=-%mem | head -10

# Check for OOM kills
sudo dmesg | grep -i "oom\|killed" | tail -10
```

**Fix:**

- If swap is active → RAM is exhausted. Check for memory leaks in PHP or MySQL.
- If OOM killer fired → a process was killed. Check which one in `dmesg`.
- Temporary relief: restart PHP-FPM or MySQL.
- Permanent fix: investigate memory leak or upgrade server.

---

### G21. 🔴 Redis Down

**Metric:** `redis_up` = 0 (redis_exporter cannot reach Redis)
**Severity:** CRITICAL — MODX sessions will be lost, site may error
**Possible causes:** Redis crashed, out of memory, port blocked, config error

**Diagnose:**

```bash
# Is Redis running?
sudo systemctl status redis-server

# Try connecting
redis-cli ping

# Check logs
sudo journalctl -u redis-server --no-pager -n 30

# Check if port is listening
ss -tlnp | grep 6379
```

**Fix:**

```bash
# Restart Redis
sudo systemctl restart redis-server

# If it fails to start → check config errors in the journal,
# then verify Redis answers
sudo journalctl -u redis-server --no-pager -n 50
redis-cli ping
```

---

### G22. 🔴 Site Response Time > 5s

**Metric:** `site_response_time_seconds` > 5s
**Severity:** Warning — site is slow for users
**Possible causes:** High load, slow DB queries, PHP-FPM pool exhausted, network issue

**Diagnose:**

```bash
# Check current response time
curl -sS -o /dev/null -w "Time: %{time_total}s\nHTTP: %{http_code}\n" https://localhost/

# Check PHP-FPM pool status
sudo cat /etc/php/*/fpm/pool.d/www.conf | grep -E 'pm\.(max_children|start_servers|min_spare|max_spare)'

# Check MySQL slow queries
sudo mysql -e "SHOW GLOBAL STATUS LIKE '%Slow_queries%';"
```

**Fix:**

- If PHP-FPM pool is saturated → increase `pm.max_children` in www.conf
- If MySQL slow queries → check `mysqltuner` or enable slow query log
- If CPU/RAM high → see those alerts

---

### G23. 🔴 Service Check Not Running

**Metric:** `check_services_last_run` stale for >10 min (window 2h)
**Severity:** Warning — health check system may be degraded
**Possible causes:** check-services.timer not running, script crashed, systemd issue
**Note:** 🔔 Canary — fires and **keeps firing** until `check_services.sh` runs again. Its death also silences the support-service metrics it pushes (fail2ban, promtail, node_exporter, telegram-bot) — the canary is the signal for those, not the value alerts.

**Diagnose:**

```bash
# Is the timer active?
sudo systemctl status check-services.timer

# Run the check manually
bash /home/ubuntu/Scripts/check_services.sh

# Check journal for errors
sudo journalctl -u check-services.service --no-pager -n 20
```

**Fix:**

```bash
# Restart timer
sudo systemctl restart check-services.timer
```

---

### G24. 🔴 VMAgent Remote Write Failing

**Metric:** `vmagent_remote_write_ok` = 0 (pushed by `check_services.sh` every 5 min — vmagent cannot push to Grafana Cloud)
**Severity:** CRITICAL — hosted metrics will be stale
**Possible causes:** Grafana Cloud credentials wrong, network issue, vmagent crash, token expired
**Note:** right after a vmagent start/restart the check reports OK (no data yet is not an error), so this does not false-fire on fresh deploys.

**Diagnose:**

```bash
# Is vmagent running?
sudo systemctl status vmagent

# Check vmagent logs
sudo journalctl -u vmagent --no-pager -n 50

# vmagent holds the Grafana Cloud credentials itself (from Ansible vault),
# so test through it: a healthy vmagent = connectivity + token are fine.
# On-server Grafana alerting API (no cloud token needed):
curl -s -u "$GRAFANA_ADMIN_USER:$GRAFANA_ADMIN_PASS" \
  http://127.0.0.1:3000/api/v1/provisioning/alert-rules | head -c 200
```

**Fix:**

- Check Grafana Cloud credentials in secrets/.env and GitHub Secrets
- If token expired → generate new Cloud Access Policy token in Grafana Cloud
- Restart vmagent after fixing credentials:

  ```bash
  sudo systemctl restart vmagent
  ```

---

### G25. 🔴 Cloud Upload Failed

**Metric:** `upload_last_success_timestamp` stale for >2h
**Severity:** Warning — rclone backups not reaching cloud storage
**Possible causes:** rclone config expired, GDrive full, network issue, cron not running

**Diagnose:**

```bash
# Was upload scheduled? Check cron
crontab -l | grep upload

# Run upload manually to see errors
bash /home/ubuntu/Scripts/upload_backups_to_gdrive.sh

# Check rclone config
rclone lsf gdrive-crypt:DreamSeed/backups/project-dev/ --files-only 2>/dev/null | head -3

# Check if VictoriaMetrics received the metric
curl -s "http://127.0.0.1:8428/api/v1/query?query=upload_last_success_timestamp" | \
  python3 -c "import json,sys; r=json.load(sys.stdin)['data']['result']; print(r[0]['value'][1] if r else 'NO DATA')"
```

**Fix:**

- Run manually to see error
- If rclone auth expired → re-deploy or update `secrets/rclone.conf`
- If GDrive full → free up space or increase quota
- If cron not working → check `systemctl status telegram-bot`, check systemd timers

---

### G26. 🔴 Fail2ban Down

**Metric:** `fail2ban_up` = 0 (pushed by `check_services.sh` every 5 min)
**Severity:** Warning — brute-force protection may be degraded
**Possible causes:** fail2ban service crashed, required jails missing (sshd, modx-admin, dreamseed-botsearch, dreamseed-bad-request, recidive)

**Diagnose:**

```bash
sudo systemctl status fail2ban
sudo fail2ban-client status
sudo fail2ban-client status modx-admin
```

**Fix:**

```bash
sudo systemctl restart fail2ban
sudo fail2ban-client status
```

#### Unbanning a blocked developer (false positive)

The `modx-admin` jail counts `POST /connectors/index.php` as brute-force
attempts. Authenticated manager AJAX (element trees, media browser) is excluded
via the filter's `ignoreregex` (Referer `/manager/` + browser UA), but a
scripted client without those headers can still trip the jail — e.g. an AI
agent driving the manager API directly.

```bash
# Who is banned right now?
sudo fail2ban-client status modx-admin

# Unban immediately (ban lives at the Cloudflare edge)
sudo fail2ban-client set modx-admin unbanip 203.0.113.10
```

Permanent whitelist for known developer/AI-agent IPs: set
`FAIL2BAN_IGNOREIP_<TARGET>` (e.g. `FAIL2BAN_IGNOREIP_DEV_AWS`, space-separated
IPs/CIDRs) in `secrets/.env`. It lands in the web jails' `ignoreip` (modx-admin,
botsearch, bad-request) on next deploy; sshd is never whitelisted.

---

### G27. 🔴 Promtail Down

**Metric:** `promtail_up` = 0 (pushed by `check_services.sh` every 5 min)
**Severity:** Warning — logs are not shipping to Loki
**Possible causes:** promtail crashed, config error, OOM

**Diagnose:**

```bash
sudo systemctl status promtail
sudo journalctl -u promtail --no-pager -n 30
```

**Fix:**

```bash
sudo systemctl restart promtail
```

---

### G28. 🔴 Node Exporter Down

**Metric:** `service_status{service="node_exporter"}` = 0 (pushed by `check_services.sh` every 5 min)
**Severity:** Warning — resource metrics (CPU/RAM/disk) are stale
**Possible causes:** node_exporter crashed, OOM, config error

**Diagnose:**

```bash
sudo systemctl status node_exporter
sudo journalctl -u node_exporter --no-pager -n 30
```

**Fix:**

```bash
sudo systemctl restart node_exporter
```

---

### G29. 🔴 Telegram Bot Not Running

**Metric:** `service_status{service="telegram-bot"}` = 0 (pushed by `check_services.sh` every 5 min)
**Severity:** Warning — alerting/reporting bot is down (prod) or a duplicate poller is running (non-prod)
**Possible causes (prod):** bot crashed, python-telegram-bot error, API token revoked
**Possible causes (non-prod):** a running poller on non-prod kills the prod bot (one getUpdates poller per token) — stop it

**Diagnose:**

```bash
sudo systemctl status telegram-bot
sudo journalctl -u telegram-bot --no-pager -n 30
```

**Fix:**

```bash
sudo systemctl restart telegram-bot
```

---

## 🔴 Layer 2: Better Stack Alerts

---

### B1. 🔴 BetterStack Alert — dreamseed.online (Main site monitor)

**What triggered:** Better Stack (from 4 global regions — EU, US, Asia, Australia) cannot reach `https://dreamseed.online` — either the HTTP check failed or the keyword **"The Dreamers"** is missing from the response
**Severity:** CRITICAL — server may be down
**Causes (from most to least likely):**

1. Server is down entirely (AWS/Hetzner issue)
2. Nginx/PHP-FPM crashed (see Layer 1 alerts)
3. Site returns 502/503 / maintenance page (keyword not found)
4. Network issue / firewall blocks port 443
5. Cloudflare SSL issue

**Diagnose — try in order:**

1. **Is the server reachable?**

   ```bash
   ssh prod "uptime"
   ```

   Replace `prod` with your configured SSH alias. If SSH works → go to step 2. If not → server may be down.

2. **Is the site responding locally?**

   ```bash
   ssh prod "curl -sS -o /dev/null -w '%{http_code}' https://dreamseed.online"
   ```

   If 200 → DNS/routing issue (not server). If not 200 → web server issue.

3. **Check what the site actually returns (keyword trigger):**

   ```bash
   # Check HTTP status
   curl -sS -o /dev/null -w "%{http_code}" https://dreamseed.online/

   # Check keyword presence
   curl -sS https://dreamseed.online/ | grep -o "The Dreamers" || echo "NOT FOUND"
   ```

4. **Check Cloudflare status:**
   Visit `https://www.cloudflarestatus.com/` or check if DNS resolves correctly:

   ```bash
   dig dreamseed.online +short
   ```

**Fix:**

- If server is down → restart via cloud console (AWS EC2 / Hetzner Cloud)
- If web server is down → see Nginx/PHP-FPM/MySQL alerts
- If HTTP is fine but keyword missing → site is up but serving a wrong page → see Site Down alert (#7)
- If MODX content changed → update the keyword in Better Stack dashboard
- If only Better Stack sees it down but site works locally → Cloudflare issue or routing problem

---

### B2. 🔴 BetterStack Alert — dreamseed.online/manager (Admin panel)

**What triggered:** Better Stack (from 4 global regions) cannot reach `https://dreamseed.online/manager/`, or the keyword **"MODX"** is missing (login page not served)
**Severity:** Medium — admin panel down, public site may still work
**Causes:**

1. Nginx vhost / MODX manager route broken
2. PHP-FPM crashed (login page is rendered by PHP)
3. MODX core/session issue (see Admin Login alert G14)

**Diagnose:**

```bash
ssh prod "sudo systemctl status nginx php8.3-fpm"
ssh prod "curl -sk --resolve dreamseed.online:443:127.0.0.1 -o /dev/null -w '%{http_code}' https://dreamseed.online/manager/"
```

**Fix:**

- If PHP-FPM down → see PHP-FPM Down alert (G5)
- If nginx config broken → see Web Server Down alert (G6)
- If admin page broken but site works → see Admin Login Failed alert (G14)

---

### B3. 🔴 BetterStack Alert — dreamseed.online/grafana

**What triggered:** Better Stack cannot reach `https://dreamseed.online/grafana`
**Severity:** Medium — Grafana is down, but site may still work
**Causes:**

1. Grafana service crashed
2. Nginx reverse proxy to Grafana failed
3. Grafana port :3000 not accessible

**Diagnose:**

```bash
ssh prod "sudo systemctl status grafana-server"
ssh prod "curl -sS -o /dev/null -w '%{http_code}' http://127.0.0.1:3000"
```

**Fix:**

```bash
ssh prod "sudo systemctl restart grafana-server"
```

---

### B4. 🔴 BetterStack Alert — backup heartbeat missed

**What triggered:** `smart_backup.sh` did not ping within 1h + 5m grace
**Severity:** Warning — backup may have failed
**Causes:**

1. `smart_backup.sh` failed (project or DB error)
2. `BETTERUPTIME_BACKUP_KEY` missing from server `.env` (seeded by Ansible backup role from GitHub secrets)
3. Network issue prevented curl to Better Stack

**Diagnose:**

```bash
ssh dream "tail -5 /home/ubuntu/backups/logs/backup_$(date +%Y-%m-%d).log"
```

Look for one of these last lines:

- `Heartbeat: ❌ failed` → network issue on server
- `Heartbeat: ⏭ skipped (no BETTERUPTIME_BACKUP_KEY)` → missing key in `.env`
- `Heartbeat: ⏭ skipped (backup failed)` → backup itself failed (check earlier lines for ❌)

**Fix — based on cause:**

- **Missing key:**

  ```bash
  ssh prod "grep BETTERUPTIME_BACKUP_KEY /home/ubuntu/Scripts/.env"
  ```

  If empty → redeploy (Ansible backup role re-generates `.env` from GitHub secrets), or manually add from local `secrets/.env`.

- **Backup failed:**

  ```bash
  ssh prod "tail -10 /home/ubuntu/backups/logs/backup_$(date +%Y-%m-%d).log"
  ```

  Check which part failed (project or DB) and fix the underlying issue (disk space, MySQL, permissions).

- **Network issue:**

  ```bash
  ssh prod "curl -sS https://uptime.betterstack.com/api/v1/heartbeat/$BETTERUPTIME_BACKUP_KEY"
  ```

  Should return 200. If not → check server internet connectivity.

---

### B5. 🔴 BetterStack Alert — gdrive-upload heartbeat missed

**What triggered:** `upload_backups_to_gdrive.sh` did not ping within 1h + 5m grace
**Severity:** Warning — cloud backups may have stopped
**Causes:**

1. `rclone` failed (auth expired, quota exceeded, API limit)
2. Script error
3. `BETTERUPTIME_GDRIVE_KEY` missing

**Diagnose:**

```bash
ssh prod "grep gdrive /home/ubuntu/backups/logs/*.log 2>/dev/null" | tail -5
```

**Fix:**

- Check `rclone` config on server:

  ```bash
  ssh prod "rclone lsd gdrive-crypt: 2>&1"
  ```

- If auth expired → update `rclone.conf` (stored in `secrets/` locally, needs redeploy)
- If quota exceeded → cleanup old backups in Google Drive manually

---

### B6. 🔴 BetterStack Alert — report-daily heartbeat missed

**What triggered:** `send_report.sh daily` did not ping within 24h + 30m grace
**Severity:** Info — only the Telegram report failed
**Causes:**

1. `send_report.sh` failed to send (Telegram API issue)
2. Script error
3. `BETTERUPTIME_REPORT_DAILY_KEY` missing

**Diagnose:**

```bash
ssh prod "bash /home/ubuntu/Scripts/send_report.sh daily 2>&1"
```

**Fix:**

- Check Telegram token/server connectivity
- Check script logs

---

### B7. 🔴 BetterStack Alert — report-weekly heartbeat missed

**What triggered:** `send_report.sh weekly` did not ping within 7d + 1h grace
**Severity:** Info
**Same diagnosis/fix as report-daily** (see B6)

---

### B8. 🔴 Synthetic Monitoring Failure (Grafana Cloud)

**What triggered:** Grafana Cloud Synthetic Monitoring checks (4 checks: HTTP main, MultiHTTP, Grafana, SSL) from global probes (US, Canada, Europe, Asia) detected downtime, slow response, or SSL issues
**Severity:** CRITICAL — external visibility is degraded
**Causes:**

1. Server is down (cloud provider issue)
2. Cloudflare edge issue
3. SSL certificate expired at Cloudflare edge
4. Latency spike or packet loss

**Diagnose:**

```bash
# 1. Check if the server responds from localhost (bypasses Cloudflare)
ssh prod "curl -sS -o /dev/null -w '%{http_code}' https://localhost/"

# 2. If localhost is fine → check Cloudflare dashboard for edge errors
#    Cloudflare Dashboard → Analytics → Edge Status Codes

# 3. Check the SM check details in Grafana Cloud:
#    https://vitalikuts.grafana.net → Synthetic Monitoring → Checks

# 4. Check provider status pages
open https://health.aws.amazon.com
# or https://status.hetzner.com
```

**Fix:**

- If all checks fail but localhost works → Cloudflare issue (DDoS protection, edge cert, routing)
- If localhost also fails → server is down (see Layer 1 alerts)
- If SSL check fails → check Cloudflare SSL/TLS settings (should be Full, not Flexible)

**Note:** SM alerts go to Telegram via Grafana Cloud notification policy, **not** through the on-server Grafana. If you receive this alert but the on-server Grafana is healthy, the issue is network-level, not server-level.

---

### B9. 🔴 BetterStack Alert — verify-backups heartbeat missed

**What triggered:** `verify_backups.sh` did not ping within 24h + 10m grace
**Severity:** Warning — daily backup integrity verification may have failed
**Causes:**

1. `verify_backups.sh` failed (corrupted backup, rclone error)
2. `BETTERUPTIME_VERIFY_KEY` missing from server `.env`
3. Network issue prevented curl to Better Stack

**Diagnose:**

```bash
ssh prod "cat /home/ubuntu/backups/logs/verify_$(date +%Y-%m-%d).log 2>/dev/null"
```

**Fix:**

- Run manually to see the error: `ssh prod "bash /home/ubuntu/Scripts/verify_backups.sh"`
- If rclone/auth expired → update rclone config and redeploy
- Check GDrive quota (`rclone lsd gdrive-crypt:`)

---

### B10. 🔴 BetterStack Alert — check-services heartbeat missed

**What triggered:** `check_services.sh` did not ping within 5min + 60s grace
**Severity:** Warning — the health-check watchdog may be down
**Causes:**

1. `check-services.timer`/service stopped
2. Server overloaded or deployed (marker suppresses checks during deploy)
3. `BETTERUPTIME_CHECK_SERVICES_KEY` missing from server `.env`

**Diagnose:**

```bash
ssh prod "sudo systemctl status check-services.timer"
ssh prod "bash /home/ubuntu/Scripts/check_services.sh"
```

**Fix:**

```bash
ssh prod "sudo systemctl restart check-services.timer"
```

---

## 🔴 Layer 3: Script Direct Alerts

---

### S1. 🔴 BACKUP FAILED

**What triggered:** `smart_backup.sh` ran but project backup (tar) or DB dump (mysqldump) failed
**Severity:** Warning — this hour's backup was not created
**Format in Telegram:**

```
🔴 BACKUP FAILED — dreamseed.online
❌ Project backup failed
  or
❌ Database dump failed
```

**Diagnose:**

```bash
ssh prod "tail -10 /home/ubuntu/backups/logs/backup_$(date +%Y-%m-%d).log"
```

Look for errors:

- `Project backup failed` → tar error (check disk space, file permissions)
- `Database dump failed` → mysqldump error (check MySQL is running)

**Fix:**

- **Project backup failed:**

  ```bash
  # Check disk space
  ssh prod "df -h"
  # Check file permissions on /var/www/html
  ssh prod "sudo ls -la /var/www/html/"
  ```

- **DB dump failed:**

  ```bash
  # Check MySQL
  ssh prod "sudo systemctl status mariadb"
  # Test dump manually
  ssh prod "mysqldump modx_db | gzip > /tmp/test.sql.gz"
  ```

**Note:** Previous backups are preserved in `~/.tmp_pre_restore_*` snapshots (hidden dir in `$HOME`, e.g. `~/.tmp_pre_restore_XXXXXX`) if a restore was recently run. After fixing → the next cron run will succeed automatically (hourly at 00).

---

### S2. 🔴 UPLOAD FAILED

**What triggered:** `upload_backups_to_gdrive.sh` ran but `rclone copy` failed
**Severity:** Warning — cloud backup not uploaded
**Format in Telegram:**

```
🔴 UPLOAD FAILED — dreamseed.online
❌ Project upload error: `<file base name>`   *(per-file line; also DB/Redis variants)*
```

**Diagnose:**

```bash
ssh prod "rclone lsd gdrive-crypt:DreamSeed/backups 2>&1"
```

**Fix:**

```bash
# Check rclone config
ssh prod "rclone config show 2>&1 | head -10"

# If auth expired → update rclone.conf on server
# If quota exceeded → clean old files
ssh prod "rclone delete gdrive-crypt:DreamSeed/backups/old_file --dry-run 2>&1"
```

---

## 🔴 Layer 4: CI/CD and Infrastructure Alerts

---

### D1. 🔴 Drift Detection Alert

**What triggered:** `drift-detection.yml` (GitHub Actions, runs daily 07:05 UTC) detected that Terraform plan against the live infrastructure differs from the committed state
**Severity:** Warning — infrastructure drifted from code
**Causes:**

1. Manual change made through cloud console (AWS Console / Hetzner Cloud UI)
2. Terraform state file is out of sync (someone ran `terraform apply` outside deploy.sh)
3. Resource was modified by an automated process (e.g., AWS auto-recovery replaced an instance)
4. Provider API change caused a resource attribute to differ

**Diagnose:**

```bash
# 1. Open the failed workflow run:
#    https://github.com/W1ckedS1ck/DreamSeed/actions/workflows/drift-detection.yml
#    → Click latest failed run → expand "Terraform plan" step

# 2. Read the plan output — it shows what changed:
#    ~ resource "aws_instance" "dreamseed" {
#        ~ ami                                   = "ami-xxx" -> "ami-yyy"
#      }
```

**Common drift scenarios and fixes:**

| Drift detected in | Likely cause | Fix |
|---|---|---|
| `ami` ID | AWS auto-recovery replaced instance with newer AMI | Update `data.aws_ami.ubuntu` filter in `terraform/aws/main.tf`, or accept the drift |
| Security Group rules | Manual SG change in AWS Console | Revert in console, or apply Terraform to overwrite |
| Instance type (e.g., `t3.small` → `t3.medium`) | Manual resize in cloud console | Revert in console, or update `main.tf` and re-apply |
| Hetzner Firewall rules | Manual firewall edit in Hetzner Console | Revert, or accept if intentional |
| `user_data` / cloud-init script | Server re-provisioned outside deploy.sh | Redeploy with `-i <IP> --no-dns` |

**Fix steps:**

```bash
# 1. If the drift is UNINTENTIONAL — restore from Terraform:
#    Run Terraform Apply workflow:
#    https://github.com/W1ckedS1ck/DreamSeed/actions/workflows/terraform-apply.yml
#    → Select provider, workspace, mode: "apply"
#    This will revert the drifted resource to match the code.

# 2. If the drift is INTENTIONAL (e.g., you manually changed something and want to keep it):
#    Update the Terraform code to match, commit, and apply:
#    git add terraform/ && git commit -m "Accept drift: <description>"
#    Then run deploy.yml or terraform-apply.yml

# 3. If drift is caused by Terraform Cloud state issues:
#    terraform init && terraform plan
#    Check if state file is corrupted or locked
```

**Note:** Non-prod environments (dev-aws, dev-hetz, cloudflare) also run drift detection but only notify in Telegram. Prod drift fails the job and notifies Telegram; there is no separate email escalation.

---

## Quick Reference — What to do first

| You see | Step 1 | Step 2 |
|---------|--------|--------|
| Any Grafana alert | `ssh prod "sudo systemctl status <service>"` | Check journalctl |
| Database Tables alert | `mysql -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='modx_db'"` | Run RESTORE_ALL.sh --auto-latest |
| Admin Login Failed | `curl -sk https://localhost/manager/ \| grep -ci "modx\|login"` | Clear MODX cache, restart PHP-FPM |
| MiniShop2 Write Failed | `mysql modx_db -e "INSERT INTO modx_ms2_orders ..."` | Check disk, permissions, table structure |
| Backup Verification Failed | `cat /home/ubuntu/backups/logs/verify_$(date +%Y-%m-%d).log` | Check rclone, GDrive, smart_backup logs |
| Better Stack monitor alert | Try `ssh prod` — if fails → cloud console | If SSH works → web server check |
| Better Stack heartbeat missed | Check backup logs | Run script manually |
| Synthetic Monitoring failure | `curl -sk https://localhost/` → if 200, check Cloudflare | If localhost fails → server down |
| Drift Detection alert | Open workflow run, read plan output | Revert drift or accept + update code |
| Better Stack itself is down | Check <https://status.betterstack.com> (if accessible) | Otherwise rely on Grafana alerts (Layer 1) + Grafana Cloud SM (Layer 2) |
| Backup failed (direct) | Check disk space | Check MySQL and project dir |

## Emergency contacts

### Provider dashboards (for restart, console access)

| Provider | Console |
|----------|---------|
| AWS | <https://console.aws.amazon.com> |
| Hetzner | <https://console.hetzner.cloud> |
| Cloudflare | <https://dash.cloudflare.com> |
| Better Stack | <https://uptime.betterstack.com> |

### Provider status pages (check if THEY have an outage)

| Provider | Status page |
|----------|-------------|
| AWS | <https://health.aws.amazon.com> |
| Hetzner | <https://status.hetzner.com> |
| Cloudflare | <https://www.cloudflarestatus.com> |
| Better Stack | <https://status.betterstack.com> |
| GitHub | <https://www.githubstatus.com> |
| Ubuntu (security) | <https://ubuntu.com/security/notices> |

### Useful links

- **Whois / DNS check:** <https://dns.google>
- **SSL check:** <https://www.ssllabs.com/ssltest/>
- **Uptime history:** <https://go-dreams.betterstackstatus.com>
- **Grafana (on-server):** <https://dreamseed.online/grafana>
- **Grafana Cloud (hosted):** <https://vitalikuts.grafana.net>

> **If Better Stack is completely unavailable:** fall back to Layer 1 (Grafana on-server via dreamseed.online/grafana) and Grafana Cloud Synthetic Monitoring (via vitalikuts.grafana.net). Better Stack is an external layer — its absence does not indicate server issues.

---

## Last resort — full restore

Three scenarios:

### A) Server is alive (SSH works) — data is corrupted

Use the interactive restore menu on the server:

```bash
ssh prod
sudo bash /home/ubuntu/Scripts/RESTORE_ALL.sh
```

It will:

1. List all available backups from Google Drive
2. Let you choose project, DB, or both
3. Create pre-restore snapshots in `~/.tmp_pre_restore_*` (backup current state before overwrite)
4. Stop Nginx/Apache + PHP-FPM
5. Restore files + DB
6. Clear MODX cache
7. Start services back
8. HTTP 200 health check

Pre-restore snapshots (`~/.tmp_pre_restore_*`) are preserved for manual recovery. Each run cleans up only **its own** directory and only on success — snapshots from failed runs accumulate until deleted manually.

### B) Server is dead — rebuild from scratch via CLI

```bash
# Local machine
./deploy.sh prod-hetz -n -i <NEW_IP>

# After deploy completes, SSH in and restore data from cloud:
ssh dream "bash /home/ubuntu/Scripts/RESTORE_ALL.sh"
```

### C) Rebuild from scratch via GitHub Actions

**Step 1 — Deploy a fresh server:**
Go to <https://github.com/W1ckedS1ck/DreamSeed/actions>

Trigger the **Deploy** workflow:

1. Environment: `prod-hetz`
2. Action: `deploy`
3. Web server: `nginx`
4. Optionally provide existing IP (to skip Terraform)
5. Run

**Step 2 — Restore data:**

After Deploy completes, run restore interactively:

```bash
ssh dream "bash /home/ubuntu/Scripts/RESTORE_ALL.sh"
```

To restore the latest backup non-interactively:

```bash
ssh prod "bash /home/ubuntu/Scripts/RESTORE_ALL.sh --auto-latest"
```
