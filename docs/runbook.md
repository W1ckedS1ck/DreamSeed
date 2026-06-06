# Incident Response Runbook — DreamSeed

> For **junior support staff**. Covers all alerts from all layers (Grafana, Better Stack, Scripts).
> All notifications arrive in a single Telegram chat.
>
> Last updated: 2026-06-04

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
| Grafana Cloud | <https://vitalikuts.grafana.net> | Hosted metrics + Synthetic Monitoring |
| Better Stack | <https://status.dreamseed.online> | Uptime status page |
| Hetzner Cloud | <https://console.hetzner.cloud> | Server console + restart |
| AWS Console | <https://console.aws.amazon.com> | EC2 management (prod) |
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
2. **Open the alert in Grafana** — follow the link from Telegram or go to `https://vitalikuts.grafana.net/alerting/list`
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
| AWS (prod) | <https://console.aws.amazon.com> |

---

## Alert Channels Overview

| Layer | Source | What it monitors | Survives server death? |
|-------|--------|-----------------|----------------------|
| 1 | Grafana (on-server) | CPU, RAM, Disk, Nginx, MySQL, PHP-FPM, Site, MODX, VictoriaMetrics, Backup cron | ❌ No |
| 2 | Better Stack (cloud) | HTTP uptime (3 monitors), Cron heartbeats (4 heartbeats) | ✅ Yes |
| 3 | Scripts (on-server) | Backup failures, GDrive upload failures | ❌ No |

All alerts → same Telegram topic.

---

## ━━━━━━ LAYER 1: GRAFANA ALERTS ━━━━━━

---

### 1. 🔴 High CPU

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

### 2. 🔴 High RAM

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

### 3. 🔴 Low Disk Space

**Metric:** Available space on `/` < 10% for 5+ minutes
**Severity:** Critical (can lead to MySQL crash, failed backups, site down)
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
  # Retention is 3 months by default
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

### 4. 🔴 MySQL Down

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

### 5. 🔴 PHP-FPM Down

**Metric:** `php_fpm_up` = 0 (socket not found or process not running)
**Severity:** CRITICAL — site returns blank page or 502
**Possible causes:** PHP-FPM crashed, OOM killer, config error after deploy

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
sudo php-fpm* -t

# Check for OOM in dmesg
sudo dmesg | grep -i "oom\|php" | tail -10
```

---

### 6. 🔴 Web Server Down (Nginx or Apache)

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

### 8. 🔴 Site Down

**Metric:** `site_up` = 0 (HTTP check from inside the server returned non-200)
**Severity:** CRITICAL — users cannot access the site
**Possible causes:** Nginx down, PHP-FPM down, MySQL down, MODX error, application crash

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
# Check MODX core files (see alert #9)
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

### 9. 🔴 MODX Core Missing

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

  # Extract latest project backup
  sudo tar -xzf /home/ubuntu/backups/project/DreamSeed_latest.tar.gz -C /var/www/
  sudo chown -R www-data:www-data /var/www/html/
  ```

- If permissions are wrong → run MODX perms from security role:

  ```bash
  sudo find /var/www/html -type f -exec chmod 644 {} \;
  sudo find /var/www/html -type d -exec chmod 755 {} \;
  sudo chown -R www-data:www-data /var/www/html/
  ```

---

### 10. 🔴 VictoriaMetrics Down

**Metric:** `victoria_up` = 0 (VictoriaMetrics health check failed)
**Severity:** High — no metrics collected, all Grafana alerts may stop working
**Possible causes:** OOM, disk full, VictoriaMetrics crashed

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

### 11. 🔴 Backup Cron Not Running

**Metric:** `cron_last_run_backup` timestamp > 120 minutes old
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

### 12. 🔴 Site Health Check Not Running

**Metric:** `check_site_last_run` > 180 seconds old
**Severity:** Warning — `check_site.sh` timer may have stopped
**Possible causes:** `check_site.sh` stuck in loop, systemd timer failed, VictoriaMetrics unreachable

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

### 13. 🔴 SSL Cert Expiring Soon

**Metric:** `ssl_days_remaining` < 7 days
**Severity:** Warning — certificate about to expire
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

# If no local cert (Cloudflare edge only) — ignore, metric is pushed as 365d default
```

---

### 14. 🔴 Admin Login Failed

**Metric:** `admin_login_ok` = 0 (hourly probe to `/manager/` returned no MODX login page)
**Severity:** High — admin panel may be down
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

### 15. 🔴 MiniShop2 Write Failed

**Metric:** `db_write_ok` = 0 (hourly INSERT+DELETE probe into `modx_ms2_orders` failed)
**Severity:** High — database write path may be broken
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

### 16. 🔴 Overall Health Check Failed

**Metric:** `dreamseed_health_overall` = 0 (composite check from `check_services.sh`)
**Severity:** High — one or more services or checks are failing
**Note:** This is a meta-alert — check which specific alert(s) fired alongside it. Review the latest `check_services.sh` output.

**Diagnose:**

```bash
# Run the full check manually
bash /home/ubuntu/Scripts/check_services.sh 2>&1

# Check which metrics were pushed
curl -sf http://127.0.0.1:8428/api/v1/query?query=dreamseed_health_overall
```

**Fix:** Address each failing check identified by `check_services.sh`.

---

### 17. 🔴 Site HTTP Status Critical

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

**Fix:** Depends on the HTTP code. See Site Down alert (#8) for detailed steps.

---

### 18. 🔴 Database Tables Below Threshold

**Metric:** `database_tables` < 50 tables in `modx_db`
**Severity:** CRITICAL — DB may be empty or not restored
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

### 19. 🔴 Backup Verification Failed

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
rclone lsf gdrive:DreamSeed/backups/project/ --max-depth 1
rclone lsf gdrive:DreamSeed/backups/db/ --max-depth 1
```

**Fix:**

- If local backup invalid → check smart_backup.sh logs
- If cloud backup missing → check rclone config and GDrive quota
- If rclone auth expired → update secrets/rclone.conf and redeploy

---

## ━━━━━━ LAYER 2: BETTER STACK ALERTS ━━━━━━

---

### 13. 🔴 BetterStack Alert — dreamseed.online (HTTP)

**What triggered:** Better Stack (from 4 global regions) cannot reach `https://dreamseed.online`
**Severity:** CRITICAL — server may be down
**Causes (from most to least likely):**

1. Server is down entirely (AWS/Hetzner issue)
2. Nginx/PHP-FPM crashed (see Layer 1 alerts)
3. Network issue / firewall blocks port 443
4. Cloudflare SSL issue

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

3. **Check Cloudflare status:**
   Visit `https://www.cloudflarestatus.com/` or check if DNS resolves correctly:

   ```bash
   dig dreamseed.online +short
   ```

**Fix:**

- If server is down → restart via cloud console (AWS EC2 / Hetzner Cloud)
- If web server is down → see Nginx/PHP-FPM/MySQL alerts
- If only Better Stack sees it down but site works locally → Cloudflare issue or routing problem

---

### 14. 🔴 BetterStack Alert — dreamseed.online (Keyword "The Dreamers")

**What triggered:** Better Stack checked `https://dreamseed.online/` but text "The Dreamers" was not found in the response
**Severity:** High — site may be returning a different page (error, maintenance, redirect)
**Causes:**

1. Site returned 502/503 instead of HTML
2. MODX changed the page content
3. Maintenance mode enabled

**Diagnose:**

```bash
# Check what the site actually returns
curl -sS https://dreamseed.online/ | grep -o "The Dreamers" || echo "NOT FOUND"

# Check HTTP status
curl -sS -o /dev/null -w "%{http_code}" https://dreamseed.online/
```

**Fix:**

- If HTTP != 200 → see Site Down alert (#8)
- If MODX content changed → update the keyword in Better Stack dashboard (or remove this monitor if outdated)

---

### 15. 🔴 BetterStack Alert — dreamseed.online/grafana

**What triggered:** Better Stack cannot reach `https://dreamseed.online/grafana`
**Severity:** Medium — Grafana is down, but site may still work
**Causes:**

1. Grafana service crashed
2. Nginx reverse proxy to Grafana failed
3. Grafana port :3000 not accessible

**Diagnose:**

```bash
ssh aws "sudo systemctl status grafana-server"
ssh aws "curl -sS -o /dev/null -w '%{http_code}' http://127.0.0.1:3000"
```

**Fix:**

```bash
ssh aws "sudo systemctl restart grafana-server"
```

---

### 16. 🔴 BetterStack Alert — backup heartbeat missed

**What triggered:** `smart_backup.sh` did not ping within 1h + 5m grace
**Severity:** Warning — backup may have failed
**Causes:**

1. `smart_backup.sh` failed (project or DB error)
2. `BETTERUPTIME_BACKUP_KEY` missing from server `.env` (auto-created by `setup_betteruptime.sh` during deploy)
3. Network issue prevented curl to Better Stack

**Diagnose:**

```bash
ssh prod "tail -5 /home/ubuntu/backups/logs/backup_$(date +%Y-%m-%d).log"
```

Look for one of these last lines:

- `Heartbeat: ❌ curl failed` → network issue on server
- `Heartbeat: ⏭ skipped (no BETTERUPTIME_BACKUP_KEY)` → missing key in `.env`
- `Heartbeat: ⏭ skipped (backup failed)` → backup itself failed (check earlier lines for ❌)

**Fix — based on cause:**

- **Missing key:**

  ```bash
  ssh prod "grep BETTERUPTIME_BACKUP_KEY /home/ubuntu/Scripts/.env"
  ```

  If empty → redeploy (run Ansible backup role which calls `setup_betteruptime.sh`), or manually add from local `secrets/.env`.

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

### 17. 🔴 BetterStack Alert — gdrive-upload heartbeat missed

**What triggered:** `upload_backups_to_gdrive.sh` did not ping within 24h + 30m grace
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
  ssh prod "rclone lsd gdrive: 2>&1"
  ```

- If auth expired → update `rclone.conf` (stored in `secrets/` locally, needs redeploy)
- If quota exceeded → cleanup old backups in Google Drive manually

---

### 18. 🔴 BetterStack Alert — report-daily heartbeat missed

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

### 19. 🔴 BetterStack Alert — report-weekly heartbeat missed

**What triggered:** `send_report.sh weekly` did not ping within 7d + 1h grace
**Severity:** Info
**Same diagnosis/fix as report-daily** (alert #18)

---

## ━━━━━━ LAYER 3: SCRIPT DIRECT ALERTS ━━━━━━

---

### 20. 🔴 BACKUP FAILED — direct from script

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

**Note:** Previous backups are preserved in `/tmp/pre_restore_*` snapshots if a restore was recently run. After fixing → the next cron run will succeed automatically (hourly at 00).

---

### 21. 🔴 UPLOAD FAILED — direct from script

**What triggered:** `upload_backups_to_gdrive.sh` ran but `rclone copy` failed
**Severity:** Warning — cloud backup not uploaded
**Format in Telegram:**

```
🔴 UPLOAD FAILED — dreamseed.online
❌ Upload to GDrive failed
```

**Diagnose:**

```bash
ssh prod "rclone lsd gdrive:DreamSeed/backups 2>&1"
```

**Fix:**

```bash
# Check rclone config
ssh prod "rclone config show 2>&1 | head -10"

# If auth expired → update rclone.conf on server
# If quota exceeded → clean old files
ssh prod "rclone delete gdrive:DreamSeed/backups/old_file --dry-run 2>&1"
```

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
3. Create pre-restore snapshots in `/tmp/pre_restore_*` (backup current state before overwrite)
4. Stop Nginx/Apache + PHP-FPM
5. Restore files + DB
6. Clear MODX cache
7. Start services back
8. HTTP 200 health check

Pre-restore snapshots are preserved for manual recovery if needed. Cleanup happens on next restore run.

### B) Server is dead — rebuild from scratch via CLI

```bash
# Local machine
./deploy.sh prod -n -i <NEW_IP>

# After deploy completes, SSH in and restore data from cloud:
ssh prod "bash /home/ubuntu/Scripts/RESTORE_ALL.sh"
```

### C) Rebuild from scratch via GitHub Actions

**Step 1 — Deploy a fresh server:**
Go to <https://github.com/W1ckedS1ck/DreamSeed/actions>

Trigger the **Deploy** workflow:

1. Environment: `prod`
2. Action: `deploy`
3. Web server: `nginx`
4. Optionally provide existing IP (to skip Terraform)
5. Run

**Step 2 — Restore data:**

After Deploy completes, run restore interactively:

```bash
ssh prod "bash /home/ubuntu/Scripts/RESTORE_ALL.sh"
```

To restore the latest backup non-interactively:

```bash
ssh prod "bash /home/ubuntu/Scripts/RESTORE_ALL.sh --auto-latest"
```
