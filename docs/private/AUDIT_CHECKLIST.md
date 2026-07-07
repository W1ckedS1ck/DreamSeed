# Server Audit Checklist

> Use this to verify a deployed server is fully functional.
> After completing all checks, generate audit report as:
> **`<server-name>_YYYY-MM-DD.md`** in `docs/private/`
>
> **Automation:** `scripts/audit_deep.sh` covers **all sections except** fail2ban regex tests,
> iptables chains, and running backup manually. Run it first, then spot-check anything in `warn` or `fail`.

---

## Connection

```bash
ssh -o LogLevel=ERROR -i ~/.ssh/Vitali.pem ubuntu@<IP>
```

---

## 1. System — Manual

| Check | Command |
|-------|---------|
| OS version | `cat /etc/os-release \| grep PRETTY` |
| Kernel | `uname -a` |
| Uptime | `uptime` |
| CPU | `nproc` |
| Memory | `free -h` |
| Disk | `df -h --total \| grep -v tmpfs\|devtmpfs\|overlay\|loop` |
| Swap | `swapon --show 2>/dev/null \|\| echo "no swap"` |
| Network | `ip -4 addr show \| grep -v 127.0.0.1` |
| DNS | `cat /etc/resolv.conf \| grep nameserver` |
| FSTAB | `cat /etc/fstab` |
| Apt updates | `apt-get --just-print upgrade 2>/dev/null \| grep -c '^Inst' \|\| echo "0"` |
| Unattended upgrades | `systemctl is-active unattended-upgrades` → expect **active** |
| Logrotate configured | `ls /etc/logrotate.d/ \| grep -E 'nginx\|php\|mariadb\|redis'` → expect **4 entries** |

## 2. Web Server — Manual

| Check | Command |
|-------|---------|
| Active site | `ls /etc/nginx/sites-enabled/` (nginx) or `ls /etc/apache2/sites-enabled/` (apache) |
| Syntax | `sudo nginx -t 2>&1` or `sudo apachectl -t 2>&1` |
| Config includes | `grep 'include' /etc/nginx/nginx.conf` (check cloudflare-realip loaded) |
| HTTP → HTTPS redirect | `curl -sI http://<domain> \| head -5` |
| Response time | `curl -o /dev/null -w 'HTTP %{http_code} (%{time_total}s)\n' https://<domain>/` |
| 404 handling | `curl -s -o /dev/null -w '%{http_code}' https://<domain>/nonexistent` |

## 3. Security Perimeter — Manual

| Check | Command |
|-------|---------|
| Adminer blocked (direct) | `curl -sk -o /dev/null -w '%{http_code}\n' -H 'Host: <domain>' https://<IP>/adminer-4.8.1-mysql.php` → expect **403** |
| Adminer blocked (via CF) | `curl -sk -o /dev/null -w '%{http_code}\n' https://<domain>/adminer-4.8.1-mysql.php` → expect **403** |
| Direct IP blocked | `curl -sk -o /dev/null -w '%{http_code}\n' https://<IP>/` → expect **000** (444) |
| $host check active | `curl -sk -H 'Host: evil.com' -o /dev/null -w '%{http_code}\n' https://<IP>/` → expect **000** |
| Cloudflare real IP | `grep -c 'set_real_ip_from' /etc/nginx/conf.d/cloudflare-realip.conf` → expect **15-23** |
| Sensitive paths | `for p in /.env /core/config/config.inc.php /.git/config /backup.sql; do curl -sk -o /dev/null -w '%{http_code}\n' https://<domain>$p; done` → expect **404/403** |
| Rate limit on connectors | `ab -n 200 -c 10 https://<domain>/connectors/index.php 2>&1 \| grep 'Failed requests'` or check nginx logs for 503 |

## 4. PHP — Automated (audit_deep.sh)

| Check | Command |
|-------|---------|
| Version | `php -v \| head -1` |
| FPM status | `systemctl is-active php*-fpm` |
| FPM pool | `ls /etc/php/*/fpm/pool.d/` |
| FPM processes | `ps aux \| grep php-fpm \| grep -v grep \| wc -l` |
| FPM memory | `ps aux \| grep php-fpm \| grep -v grep \| awk '{sum+=$6; count++} END {print int(sum/count/1024) " MB avg"}'` |
| Extensions loaded | `php -m \| grep -iE 'pdo_mysql|redis|curl|mbstring|json|xml|zip|gd|openssl'` |
| Limits | `php -i \| grep -E 'memory_limit|upload_max|post_max|max_execution|max_input'` |
| Opcache | `php -i \| grep -E 'opcache.enable\|opcache.memory_consumption\|opcache.max_accelerated_files'` |
| Opcache status | `php -r '$s=opcache_get_status(false);$m=$s["memory_usage"];$t=$s["opcache_statistics"];echo "Mem: ".round($m["used_memory"]/1024/1024,2)."/".round(($m["used_memory"]+$m["free_memory"])/1024/1024,2)." MB | Files: ".$t["num_cached_scripts"]." | Hits: ".$t["hits"]." | Hit rate: ".round($t["hits"]/($t["hits"]+$t["misses"])*100,2)."%"'` |

## 5. Database (MariaDB) — Automated (audit_deep.sh)

| Check | Command |
|-------|---------|
| Version | `mysql -V` |
| Running | `systemctl is-active mariadb` |
| Uptime | `mysql -e "SHOW STATUS LIKE 'Uptime'" \| tail -1` |
| Connections | `mysql -e "SHOW STATUS LIKE 'Threads_connected'" \| tail -1` |
| Users | `mysql -e "SELECT User,Host FROM mysql.user"` |
| Databases | `mysql -e "SHOW DATABASES"` |
| MODX tables | `grep 'dbase' /var/www/html/core/config/config.inc.php \| cut -d"'" -f4 \| xargs -I{} mysql -e 'SELECT COUNT(*) AS tables FROM information_schema.tables WHERE table_schema="{}"'` |
| MODX DB size | `grep 'dbase' /var/www/html/core/config/config.inc.php \| cut -d"'" -f4 \| xargs -I{} mysql -e 'SELECT ROUND(SUM(data_length+index_length)/1024/1024,2) AS "MB" FROM information_schema.tables WHERE table_schema="{}"'` |
| InnoDB buffer | `mysql -e "SHOW VARIABLES LIKE 'innodb_buffer_pool_size'" \| tail -1` |
| Slow queries | `mysql -e "SHOW GLOBAL STATUS LIKE 'Slow_queries'" \| tail -1` |
| Network bind | `ss -tlnp \| grep 3306` (should be `127.0.0.1:3306`) |

## 6. Redis — Automated (audit_deep.sh)

| Check | Command |
|-------|---------|
| Ping | `redis-cli ping` |
| Version | `redis-server -v 2>/dev/null` |
| Uptime | `redis-cli INFO server \| grep uptime_in_seconds` |
| Memory | `redis-cli INFO memory \| grep -E 'used_memory_human\|maxmemory_human'` |
| Keys | `redis-cli DBSIZE` |
| Network bind | `ss -tlnp \| grep 6379` (should be `127.0.0.1:6379`) |
| Config (renamed commands) | `sudo grep rename-command /etc/redis/redis.conf` (should block FLUSHALL, CONFIG, SHUTDOWN, DEBUG) |

## 7. PHP Sessions (Redis via FPM) — Automated (audit_deep.sh)

| Check | Command |
|-------|---------|
| FPM session handler | `php-fpm8.3 -i 2>/dev/null \| grep session.save_handler` → expect **redis** |
| FPM session path | `php-fpm8.3 -i 2>/dev/null \| grep session.save_path` → expect **tcp://127.0.0.1:6379** |
| Pool config | `grep -A2 'session.save_handler' /etc/php/*/fpm/pool.d/www.conf` |

**Note:** CLI `php -i` shows `files` — this is expected. FPM uses Redis.

## 7b. Redis Session — Practical Test — Automated (audit_deep.sh)

| Check | Command |
|-------|---------|
| Redis before | `redis-cli DBSIZE` |
| Create test PHP | `echo '<?php session_start(); echo session_id();' > /tmp/session_test.php && sudo mv /tmp/session_test.php /var/www/html/` |
| Call via FPM | `curl -sk --max-time 5 'https://localhost/session_test.php'` → expect **session ID string** |
| Redis after | `redis-cli DBSIZE` (expect +1) |
| Verify key | `redis-cli KEYS 'PHPREDIS_SESSION:*'` → expect **session key** |
| Cleanup | `sudo rm -f /var/www/html/session_test.php` |

**Note:** GET `/manager/` and POST `/connectors/` trigger `session_start()` and create Redis sessions. Even plain GET `/` may create sessions if MODX starts them for anonymous visitors.
**Critical:** `session_handler_class` must be **empty** in MODX system settings — otherwise MODX overrides PHP handler and writes to DB:
```bash
mysql -N modx_db -e "SELECT key, value FROM modx_system_settings WHERE key = \"session_handler_class\""
# → output must be empty (value = '')
```

## 8. SSL — Manual

| Check | Command |
|-------|---------|
| Cloudflare edge | `openssl s_client -connect <domain>:443 -servername <domain> </dev/null 2>/dev/null \| openssl x509 -text \| grep -E 'Subject:\|Issuer:\|Not Before\|Not After'` |
| Local cert (if direct) | `ls /etc/letsencrypt/live/ 2>/dev/null \|\| echo "no local cert"` |
| Certbot certs | `sudo certbot certificates 2>/dev/null` |

## 9. MODX — Automated (audit_deep.sh)

| Check | Command |
|-------|---------|
| index.php | `head -3 /var/www/html/index.php` |
| config.core.php | `cat /var/www/html/config.core.php` |
| DB config | `head -12 /var/www/html/core/config/config.inc.php` (check dbname, prefix) |
| Core structure | `ls /var/www/html/core/` |
| Cache mount | `df -h /var/www/html/core/cache` (expect **tmpfs** ~64M) |
| Cache writable | `sudo -u www-data touch /var/www/html/core/cache/_test && rm /var/www/html/core/cache/_test && echo 'YES'` |
| Cache contents | `ls /var/www/html/core/cache/` |
| HTTP 200 | `curl -s -o /dev/null -w '%{http_code}' https://<domain>/` |

## 10. Performance / Speed — Manual

| Check | Command |
|-------|---------|
| Site via CF (warm) | `curl -o /dev/null -w '%{http_code} | TTFB: %{time_starttransfer}s | Total: %{time_total}s\n' https://<domain>/` |
| Site via CF (cold) | run twice — first is cold, second is cached |
| Direct to server | `curl -sk -H 'Host: <domain>' -o /dev/null -w 'TTFB: %{time_starttransfer}s | Total: %{time_total}s | Size: %{size_download}B\n' https://<IP>/` |
| Manager | `curl -sk -o /dev/null -w '%{http_code} | %{time_total}s\n' https://<domain>/manager/` |
| Static file (cached) | `curl -sk -o /dev/null -w '%{http_code} | %{time_total}s\n' https://<domain>/theme/css/style.css` |
| Page size | `curl -sk -o /dev/null -w 'Size: %{size_download} bytes (%{content_type})\n' https://<domain>/` |

## 11. Monitoring — Automated (audit_deep.sh)

| Check | Command |
|-------|---------|
| node_exporter | `curl -s localhost:9100/metrics \| head -2` |
| nginx_exporter | `curl -s localhost:9113/metrics \| head -2` |
| apache_exporter | `curl -s localhost:9117/metrics \| head -2` (apache only) |
| mysqld_exporter | `curl -s localhost:9104/metrics \| head -2` |
| redis_exporter | `curl -s localhost:9121/metrics \| head -2` |
| VictoriaMetrics | `curl -s localhost:8428/health` |
| vmagent | `curl -s localhost:8429/health` |
| vmagent remote write | `curl -s localhost:8429/metrics \| grep vmagent_remotewrite_blocks_sent_total` |
| Scrape targets | `curl -s 'localhost:8428/api/v1/query?query=up' \| python3 -c "import sys,json; d=json.load(sys.stdin); [print(r['metric']['job'], r['value'][1]) for r in d['data']['result']]"` |
| Exporter errors | `curl -s localhost:8428/api/v1/query?query=up \| python3 -c "import sys,json; d=json.load(sys.stdin); down=[r for r in d['data']['result'] if r['value'][1]=='0']; print(f'{len(down)} down') if down else print('all up')"` |

## 12. Grafana — Automated (audit_deep.sh)

| Check | Command |
|-------|---------|
| API health | `curl -s -u admin:\$GRAFANA_PASS localhost:3000/api/health` |
| Provisioning | `ls /etc/grafana/provisioning/datasources/ /etc/grafana/provisioning/dashboards/` |
| Datasource | `curl -s -u admin:\$GRAFANA_PASS localhost:3000/api/datasources` |
| Alerts firing | `curl -s -u admin:\$GRAFANA_PASS localhost:3000/api/alertmanager/grafana/api/v2/alerts \| python3 -c "import sys,json; d=json.load(sys.stdin); print(f'{len(d)} alerts firing')"` |
| Memory | `ps aux \| grep grafana \| grep -v grep \| awk '{printf "%.1f%% (%s MB RSS)\\n", $4, $6/1024}'` |
| Log errors | `journalctl -u grafana-server --no-pager --since "1 hour ago" \| grep -ci 'error\|panic' \|\| echo "0"` |
| Alerts in Telegram | `journalctl -u grafana-server --no-pager --since "1 hour ago" \| grep -c 'notify\|alert.*sent\|notified' \|\| echo "no alerts triggered"` |

## 13. Backups — Automated (audit_deep.sh)

| Check | Command |
|-------|---------|
| Cron jobs | `crontab -l 2>/dev/null \| grep -v '^#' \| grep -v '^$'` |
| Backup dirs | `ls ~/backups/project/ ~/backups/db/ ~/backups/redis/ 2>/dev/null` |
| Backup scripts | `ls /home/ubuntu/Scripts/` |
| **rclone_retry in common_functions** | `grep -c 'rclone_retry' /home/ubuntu/Scripts/common_functions.sh` → expect ≥ **1** |
| **Run backup manually** | `bash /home/ubuntu/Scripts/smart_backup.sh && ls -lah ~/backups/project/ ~/backups/db/` |
| **Upload backup** | `bash /home/ubuntu/Scripts/upload_backups_to_gdrive.sh` |
| **Prune no-block metric** | After upload, check `journalctl -u cron --no-pager --since '1 hour ago' \| grep upload` — prune warnings ok, metric must push |
| Systemd timers | `systemctl list-timers --no-legend \| awk '{print $NF}'` |

## 14. Telegram Bot — Automated (audit_deep.sh)

| Check | Command |
|-------|---------|
| Status | `systemctl is-active telegram-bot` |
| Recent logs | `journalctl -u telegram-bot --no-pager --since "1 hour ago" \| tail -10` |
| Error count | `journalctl -u telegram-bot --no-pager \| grep -ci 'error\|traceback\|exception' \|\| echo "0"` |

## 15. Security — Automated (audit_deep.sh)

| Check | Command |
|-------|---------|
| SSH port | `grep -E '^Port ' /etc/ssh/sshd_config \|\| echo "default 22"` |
| Root login | `grep -E '^PermitRootLogin' /etc/ssh/sshd_config` |
| Password auth | `grep -E '^PasswordAuthentication' /etc/ssh/sshd_config` |
| Sudo | `sudo -l 2>/dev/null \| head -5` |
| UFW status | `sudo ufw status \| head -5 \|\| echo "ufw not active"` |
| Fail2ban jails | `sudo fail2ban-client status \| grep 'Jail list'` |
| Fail2ban per jail | `for j in $(sudo fail2ban-client status 2>/dev/null \| grep 'Jail list' \| sed 's/.*\t//' \| tr ',' ' '); do echo "$j: $(sudo fail2ban-client status $j 2>/dev/null \| grep -E 'Currently banned\|Total banned')"; done` |
| Fail2ban regex — sshd | `printf 'Jul 5 09:30:00 host sshd[1234]: Failed password for root from 10.0.0.1 port 22 ssh2\n' \| sudo fail2ban-regex /dev/stdin sshd 2>&1 \| grep matched` |
| Fail2ban regex — modx-admin | `printf '1.2.3.4 - - [05/Jul/2026:09:30:00 +0000] "POST /connectors/index.php HTTP/2" 200 123 "-" "Mozilla/5.0"\n' \| sudo fail2ban-regex /dev/stdin modx-admin 2>&1 \| grep matched` |
| Fail2ban regex — botsearch | `printf '1.2.3.4 - - [05/Jul/2026:09:30:00 +0000] "GET /wp-login.php HTTP/1.1" 404 162 "-" "curl"\n' \| sudo fail2ban-regex /dev/stdin nginx-botsearch 2>&1 \| grep matched` |
| Fail2ban regex — bad-request | `printf '1.2.3.4 - - [05/Jul/2026:09:30:00 +0000] " " 400 0 "-" "-"\n' \| sudo fail2ban-regex /dev/stdin nginx-bad-request 2>&1 \| grep matched` |
| Fail2ban real ban (SSH) | `ssh -o PasswordAuthentication=no nonexistent@<IP> 2>&1 \|\| true; sleep 3; sudo fail2ban-client status sshd \| grep 'Total failed'` → expect **total > 0** |
| iptables f2b chains | `sudo iptables -L -n 2>/dev/null \| grep -c f2b \|\| echo "0 (no bans yet)"` |

## 16. Systemd Services — ALL Running — Automated (audit_deep.sh)

```bash
systemctl list-units --type=service --state=running --no-legend | awk '{print $1}'
```

Expected: nginx, php*-fpm, mariadb, redis-server, fail2ban, grafana-server,
node_exporter, mysqld_exporter, nginx_exporter (or apache_exporter),
redis_exporter, victoria-metrics, vmagent, promtail, telegram-bot, ssh, cron, unattended-upgrades

## 17. Processes — Top by Memory — Automated (audit_deep.sh)

```bash
ps aux --sort=-%mem | head -10 | awk '{printf "%-25s %5s %s MB\n", $11, $4, int($6/1024)}'
```

Expected: Grafana ~250-350MB, MariaDB ~150-200MB, VM ~50-70MB,
vmagent ~30-40MB, fail2ban ~40-50MB, PHP-FPM ~30MB each

## 18. Open Ports (Public) — Automated (audit_deep.sh)

| Check | Command |
|-------|---------|
| From inside server | `ss -tlnp \| grep -v '127.0.0.1:\|::1:' \| grep LISTEN` |
| From outside (via CF) | `curl -sk -o /dev/null -w '%{http_code}\n' https://<domain>:<port>` for ports 80, 443, 3306, 6379, 3000, 8428, 8429, 9100, 9113, 9121 |

Expected public ports: **22, 80, 443** only.

## 19. Logs — Errors in Last Hour — Automated (audit_deep.sh)

```bash
journalctl --since "1 hour ago" -p err --no-pager | grep -v 'snapd\|ModemManager\|shutdown\|loop' | head -20
```

## 20. Functional Checks (code actually works) — Automated (audit_deep.sh)

| Check | Command | Expected |
|-------|---------|----------|
| Backup archives exist | `ls ~/backups/project/ 2>/dev/null \|\| echo "EMPTY"` | non-empty |
| Rclone config exists | `ls ~/.config/rclone/rclone.conf 2>/dev/null \|\| echo "MISSING"` | present |
| Brotli compression | `curl -sI -H 'Accept-Encoding: br' https://<domain>/theme/css/style.css \| grep content-encoding` | `br` |
| MariaDB optimizations | `mysql -e "SHOW VARIABLES LIKE '%optimiz%'" \| tail -5` | settings from optimizations.cnf |
| Swap exists | `swapon --show \| grep swapfile` | `/swapfile` |
| sysctl hardening | `sysctl net.ipv4.tcp_syncookies net.ipv4.conf.all.rp_filter net.ipv4.conf.all.accept_source_route 2>/dev/null` | syncookies=1, rp_filter=1, accept_source_route=0 |
| SSH key auth (no password) | `sudo grep -E '^PasswordAuthentication' /etc/ssh/sshd_config` | `no` |
| SSH deploy_key isolated | `ls /etc/ssh/sshd_config.d/50-cloud-init.conf 2>/dev/null \|\| echo "no cloud-init override"` | should exist or be stripped |
| systemd nginx restart | `systemctl show nginx \| grep Restart=always` | `Restart=always` |
| systemd php-fpm restart | `systemctl show php8.3-fpm \| grep Restart=always` | `Restart=always` |
| MODX session prefix | `grep 'table_prefix' /var/www/html/core/config/config.inc.php` | `modx_` |
| Grafana alerts in Telegram | `journalctl -u grafana-server --no-pager --since '1 hour ago' \| grep -c 'alert.*notify\|notify\|sent' \|\| echo 'no alerts triggered'` | varies |
| VMagent data flowing | `curl -s localhost:8429/metrics \| grep vmagent_remotewrite_blocks_sent_total \| awk '{sum+=\\$NF} END {print sum " blocks sent"}'` | >0 |
| Node exporter custom metrics | `curl -s localhost:9100/metrics 2>/dev/null \| grep -c 'backup_last_success\|upload_last_success' \|\| echo "no custom metrics"` | >0 |
| Promtail service | `systemctl is-active promtail` | active |
| Promtail positions | `sudo promtail --dry-run -config.file /etc/promtail/promtail.yml 2>&1 \| grep -c 'nginx\|php-fpm\|syslog' \|\| echo "check file paths"` | >0 |
| Faro RUM (nginx sub_filter) | `curl -sk https://localhost/ -H 'Host: $DOMAIN' \| grep -c 'faro-web-sdk\|/faro-collect'` | >0 |
| Faro RUM (CSP connect-src) | `curl -skI https://localhost/ -H 'Host: $DOMAIN' \| grep 'connect-src.*self'` | 'self' (no external) |
| fail2ban_up metric | `curl -s localhost:8428/api/v1/query?query=fail2ban_up 2>/dev/null \| grep -c '"value".*"1"' \|\| echo "fail2ban_up != 1"` | 1 |
| Better Stack check-services | `curl -s https://uptime.betterstack.com/api/v1/heartbeat/\$BETTERUPTIME_CHECK_SERVICES_KEY 2>/dev/null` | 200 |

---

## Generating Audit Report

After completing all checks, create a report:

```bash
cat > docs/private/<server-name>_$(date +%Y-%m-%d).md << 'REPORT'
# <server-name> Server Audit — <YYYY-MM-DD>

...
REPORT
```

Include:
- All check results
- Any anomalies (deviation from expected)
- Grafana memory (check against GOMEMLIMIT 800MiB)
- Open ports audit
- Fail2ban ban count (fresh deploy = 0, production = growing)
- MODX table count vs expected (from config.inc.php dbase)
- Adminer block status
- Direct IP block status
- Performance metrics (TTFB, total time)
- PHP session handler (FPM = redis, CLI = files — both expected)
- Faro RUM sub_filter present in nginx SSL config
- Promtail service active + logs flowing to Loki
- Better Stack heartbeats check-services up
- fail2ban_up metric in VictoriaMetrics
