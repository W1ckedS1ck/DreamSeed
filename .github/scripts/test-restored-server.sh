#!/bin/bash
# Test restored server services. Run from CI workflow.
# Usage: test-restored-server.sh <SERVER_IP>
set -euo pipefail

SERVER_IP="${1:?Usage: $0 <SERVER_IP>}"
DB_NAME="${DB_NAME:-modx_db}"
if [[ ! "$DB_NAME" =~ ^[a-zA-Z0-9_]+$ ]]; then
    echo "ERROR: DB_NAME contains invalid characters (got: '$DB_NAME')" >&2
    exit 1
fi
SSH_KEY="${SSH_KEY:-${HOME}/.ssh/deploy_key}"
ssh() { command ssh -i "$SSH_KEY" "$@" 2>/dev/null; }

P=0 F=0 W=0
FAIL_ITEMS=""

pass() {
    echo "[PASS] $1"
    ((++P))
}
fail() {
    echo "[FAIL] $1"
    ((++F))
    [ -n "$FAIL_ITEMS" ] && FAIL_ITEMS="$FAIL_ITEMS, "
    FAIL_ITEMS="${FAIL_ITEMS}${1%% *}"
}
warn() {
    echo "[WARN] $1"
    ((++W))
}

# ==== Checks start ====

# --- MODX cache state ---
CACHE_STALE=$(ssh ubuntu@"$SERVER_IP" "find /var/www/html/core/cache/ -mmin -10 -type f 2>/dev/null | head -1 | wc -l" || echo 0)
[ "$CACHE_STALE" -gt 0 ] && pass "MODX cache populated after restore" || warn "MODX cache empty or inaccessible"

# --- Database ---
ssh ubuntu@"$SERVER_IP" "systemctl is-active mariadb" && pass "MariaDB running" || fail "MariaDB"
ssh ubuntu@"$SERVER_IP" "mysql \"$DB_NAME\" -N -e 'SELECT 1'" && pass "DB connect" || fail "DB connect"
ROWS=$(ssh ubuntu@"$SERVER_IP" "mysql \"$DB_NAME\" -N -e 'SELECT COUNT(*) FROM modx_site_content'" 2>/dev/null || echo 0)
echo "content_rows=$ROWS"
[ "${ROWS:-0}" -gt 0 ] && pass "Content rows: $ROWS" || fail "No content rows"

# --- Web server ---
ssh ubuntu@"$SERVER_IP" "systemctl is-active nginx" && pass "Nginx running" || fail "Nginx"
ssh ubuntu@"$SERVER_IP" "systemctl is-active php8.3-fpm" && pass "PHP-FPM running" || fail "PHP-FPM"
DOMAIN=$(ssh ubuntu@"$SERVER_IP" "grep -hs 'server_name' /etc/nginx/sites-available/*.conf 2>/dev/null | grep -v 'server_name _' | awk '{print \$2}' | tr -d ';' | head -1" 2>/dev/null || echo "localhost")
HTTPS_CODE=$(ssh ubuntu@"$SERVER_IP" "curl -sk --resolve '$DOMAIN:443:127.0.0.1' -o /dev/null -w '%{http_code}' 'https://$DOMAIN/'" 2>/dev/null || echo "000")
[ "$HTTPS_CODE" = "200" ] && pass "HTTPS 200" || fail "HTTPS $HTTPS_CODE"

# Nginx config syntax (needs sudo — ubuntu can't read Let's Encrypt keys,
# plain `nginx -t` fails with [emerg] Permission denied even when nginx is
# healthy and serving 200)
ssh ubuntu@"$SERVER_IP" "sudo nginx -t 2>&1 | grep -q 'syntax is ok'" && pass "Nginx config syntax OK" || fail "Nginx config: syntax check failed"

# --- MODX core ---
ssh ubuntu@"$SERVER_IP" "test -f /var/www/html/core/config/config.inc.php" && pass "Config exists" || fail "Config missing"
# Permissions come from the backup archive (chown -R www-data on restore), not
# from a template — so 640/660 are both valid. Real requirement: NOT
# world-readable (last octal digit 0) so other OS users can't read DB creds.
CONFIG_PERMS=$(ssh ubuntu@"$SERVER_IP" "stat -c '%a' /var/www/html/core/config/config.inc.php 2>/dev/null || echo ''")
CONFIG_OWNER=$(ssh ubuntu@"$SERVER_IP" "stat -c '%U' /var/www/html/core/config/config.inc.php 2>/dev/null || echo ''")
if [ -n "$CONFIG_PERMS" ] && [ "${CONFIG_PERMS: -1}" = "0" ]; then
    [ "$CONFIG_OWNER" = "www-data" ] && pass "Config permissions: $CONFIG_PERMS ($CONFIG_OWNER)" || warn "Config owner: $CONFIG_OWNER (expected www-data)"
else
    warn "Config permissions: ${CONFIG_PERMS:-N/A} (expected 640/660, not world-readable)"
fi
ssh ubuntu@"$SERVER_IP" "test -d /var/www/html/assets" && pass "Assets exists" || fail "Assets missing"

# --- PHP logs ---
PHP_ERRORS=$(ssh ubuntu@"$SERVER_IP" "sudo cat /var/log/php*-fpm.log 2>/dev/null | grep -ci 'PHP Fatal error' || true")
[ "${PHP_ERRORS:-0}" -eq 0 ] 2>/dev/null && pass "No PHP Fatal errors" || warn "PHP Fatal errors: $PHP_ERRORS"

# --- Monitoring stack ---
ssh ubuntu@"$SERVER_IP" "curl -sf -o /dev/null http://127.0.0.1:8428/health" && pass "VictoriaMetrics health" || warn "VM health: FAIL"

ssh ubuntu@"$SERVER_IP" "curl -sf http://127.0.0.1:9100/metrics 2>/dev/null | grep -q 'node_cpu'" && pass "Node Exporter metrics" || warn "Node Exporter: FAIL"

# --- Security ---
F2B=$(ssh ubuntu@"$SERVER_IP" "systemctl is-active fail2ban" 2>/dev/null || echo "inactive")
[ "$F2B" = "active" ] && pass "fail2ban running" || warn "fail2ban: $F2B"

ssh ubuntu@"$SERVER_IP" "grep -q 'MaxAuthTries 3' /etc/ssh/sshd_config.d/00-hardening.conf 2>/dev/null" && pass "SSH hardening" || warn "SSH hardening: FAIL"

TBL=$(ssh ubuntu@"$SERVER_IP" "mysql \"$DB_NAME\" -N -e 'SELECT COUNT(*) FROM information_schema.tables WHERE table_schema=\"$DB_NAME\"'" 2>/dev/null || echo 0)
[ "${TBL:-0}" -ge 50 ] && pass "DB tables: $TBL" || warn "DB tables: ${TBL:-0} (expected 50+)"

ssh ubuntu@"$SERVER_IP" "systemctl is-active check-site.timer" && pass "check_site.timer" || fail "check_site.timer"
ssh ubuntu@"$SERVER_IP" "systemctl is-active check-services.timer" && pass "check-services.timer" || fail "check-services.timer"

ssh ubuntu@"$SERVER_IP" "systemctl is-active grafana-server" && pass "Grafana running" || warn "Grafana not running"

VMAGENT=$(ssh ubuntu@"$SERVER_IP" "systemctl is-active vmagent" 2>/dev/null || echo "inactive")
[ "$VMAGENT" = "active" ] && pass "vmagent running" || warn "vmagent: $VMAGENT"

ssh ubuntu@"$SERVER_IP" "systemctl is-active mysqld_exporter" && pass "MySQLd Exporter running" || warn "MySQLd Exporter not running"

VMAE=$(ssh ubuntu@"$SERVER_IP" "curl -sf http://127.0.0.1:8429/metrics 2>/dev/null | grep 'vmagent_remotewrite_errors_total' | grep -o '[0-9]*$'" 2>/dev/null || echo "NO_DATA")
[ "$VMAE" = "0" ] && pass "vmagent remote write: 0 errors" || fail "vmagent remote write errors: $VMAE"

WEB_EXP=$(ssh ubuntu@"$SERVER_IP" "systemctl is-active nginx_exporter 2>/dev/null || systemctl is-active apache_exporter 2>/dev/null || echo inactive")
[ "$WEB_EXP" = "active" ] && pass "Web exporter running" || warn "Web exporter: $WEB_EXP"

CRON=$(ssh ubuntu@"$SERVER_IP" "crontab -l 2>/dev/null" || true)
echo "$CRON" | grep -q "smart_backup" && pass "Cron: hourly backup" || fail "Cron: hourly backup missing"
echo "$CRON" | grep -q "upload_backups_to_gdrive" && pass "Cron: daily gdrive upload" || warn "Cron: daily gdrive upload missing"
echo "$CRON" | grep -q "send_report.sh daily" && pass "Cron: daily report" || warn "Cron: daily report missing"
echo "$CRON" | grep -q "send_report.sh weekly" && pass "Cron: weekly report" || warn "Cron: weekly report missing"
echo "$CRON" | grep -q "verify_backups" && pass "Cron: backup verification" || warn "Cron: backup verification missing"
echo "$CRON" | grep -q "session-cleanup" && warn "Cron: session cleanup (unexpected — Redis handles sessions)" || pass "Cron: no session cleanup (Redis handles sessions)"

# --- Backup ---
SCRIPTS_DIR="/home/ubuntu/Scripts"
for script in smart_backup.sh upload_backups_to_gdrive.sh verify_backups.sh; do
    ssh ubuntu@"$SERVER_IP" "test -f $SCRIPTS_DIR/$script" && pass "Script: $script" || fail "Script: $script missing"
done

GDRIVE=$(ssh ubuntu@"$SERVER_IP" "rclone lsf gdrive-crypt:DreamSeed/backups/project/ --max-depth 1 2>/dev/null | grep . || rclone lsf gdrive:DreamSeed/backups/project/ --max-depth 1 2>/dev/null | sort -r | head -1 || echo NO_BACKUPS")
[ "$GDRIVE" != "NO_BACKUPS" ] && pass "GDrive backups: $(echo "$GDRIVE" | tr -d '\n')" || fail "GDrive backups: not found"

ssh ubuntu@"$SERVER_IP" "systemctl is-active telegram-bot" && pass "Telegram bot running" || warn "Telegram bot not running"

ssh ubuntu@"$SERVER_IP" "sudo fail2ban-client status modx-admin 2>/dev/null | grep -q 'Total banned'" && pass "fail2ban modx-admin jail" || warn "fail2ban modx-admin: disabled (behind CF)"
ssh ubuntu@"$SERVER_IP" "sudo fail2ban-client status grafana 2>/dev/null | grep -q 'Total banned'" && pass "fail2ban grafana jail" || warn "fail2ban grafana: disabled (not deployed)"

# --- Redis ---
ssh ubuntu@"$SERVER_IP" "systemctl is-active redis-server" && pass "Redis server running" || fail "Redis server"
REDIS_EXP=$(ssh ubuntu@"$SERVER_IP" "systemctl is-active redis_exporter 2>/dev/null || echo inactive")
[ "$REDIS_EXP" = "active" ] && pass "Redis exporter running" || warn "Redis exporter: $REDIS_EXP"

REDIS_BACKUP=$(ssh ubuntu@"$SERVER_IP" "ls -1 /home/ubuntu/backups/redis/redis_dump_*.rdb 2>/dev/null | head -1 || echo ''")
if [ -n "$REDIS_BACKUP" ]; then
    pass "Redis backup exists: $(basename "$REDIS_BACKUP")"
    REDIS_BACKUP_NAME=$(basename "$REDIS_BACKUP")
else
    fail "Redis backup: not found"
    REDIS_BACKUP_NAME="none"
fi

REDIS_CLOUD=$(ssh ubuntu@"$SERVER_IP" "rclone lsf gdrive-crypt:DreamSeed/backups/redis/ --max-depth 1 2>/dev/null | wc -l")
echo "redis_cloud_backups=$REDIS_CLOUD"

SHC=$(ssh ubuntu@"$SERVER_IP" "mysql -N \"$DB_NAME\" -e \"SELECT value FROM modx_system_settings WHERE \\\`key\\\` = 'session_handler_class'\" 2>/dev/null" || echo QUERY_FAILED)
if [ "$SHC" = "QUERY_FAILED" ]; then
    fail "session_handler_class: query failed (mysql error)"
    echo "session_handler_ok=query_error"
elif [ -z "$SHC" ]; then
    pass "session_handler_class empty (Redis sessions)"
    echo "session_handler_ok=yes"
else
    fail "session_handler_class = '$SHC' (should be empty)"
    echo "session_handler_ok=no"
fi

BEFORE=$(ssh ubuntu@"$SERVER_IP" "redis-cli DBSIZE 2>/dev/null || echo 0")
SESSIONS=$(ssh ubuntu@"$SERVER_IP" "redis-cli --scan --pattern 'PHPREDIS_SESSION:*' 2>/dev/null | head -3 | tr '\n' ' '" || true)
AFTER=$(ssh ubuntu@"$SERVER_IP" "redis-cli DBSIZE 2>/dev/null || echo 0")
echo "Redis keys: before=$BEFORE session_keys=$SESSIONS total=$AFTER"
if [ -n "$(echo "$SESSIONS" | tr -d ' ')" ]; then
    pass "Redis sessions active ($AFTER keys)"
    echo "redis_session_keys=$AFTER"
else
    ssh ubuntu@"$SERVER_IP" "curl -sk --resolve '$DOMAIN:443:127.0.0.1' -o /dev/null 'https://$DOMAIN/' 2>/dev/null || true"
    sleep 1
    AFTER2=$(ssh ubuntu@"$SERVER_IP" "redis-cli DBSIZE 2>/dev/null || echo 0")
    SESSIONS2=$(ssh ubuntu@"$SERVER_IP" "redis-cli --scan --pattern 'PHPREDIS_SESSION:*' 2>/dev/null | head -3 | tr '\n' ' '" || true)
    if [ -n "$(echo "$SESSIONS2" | tr -d ' ')" ]; then
        pass "Redis sessions active after curl ($AFTER2 keys)"
        echo "redis_session_keys=$AFTER2"
    else
        warn "Redis: no session keys (may need login first)"
        echo "redis_session_keys=0"
    fi
fi

# --- Promtail ---
PROMTAIL_POS=$(ssh ubuntu@"$SERVER_IP" "test -f /var/lib/promtail/positions.yml && echo yes || echo no" 2>/dev/null || echo "no")
[ "$PROMTAIL_POS" = "yes" ] && pass "Promtail positions: /var/lib/promtail/positions.yml" || fail "Promtail positions file missing"

PROMTAIL_ERRS=$(ssh ubuntu@"$SERVER_IP" "journalctl -u promtail --no-pager -n 50 2>/dev/null | grep -c 'error' || true")
[ "${PROMTAIL_ERRS:-0}" -eq 0 ] && pass "Promtail: 0 errors (last 50 lines)" || warn "Promtail: ${PROMTAIL_ERRS} errors (last 50 lines)"

PROMTAIL_PHP=$(ssh ubuntu@"$SERVER_IP" "curl -sf http://127.0.0.1:9080/metrics 2>/dev/null | grep -c 'promtail_read_bytes_total.*php.*fpm' || true")
[ "${PROMTAIL_PHP:-0}" -gt 0 ] && pass "Promtail: reading PHP-FPM log" || fail "Promtail: NOT reading PHP-FPM log"

PHP_LOG_PERMS=$(ssh ubuntu@"$SERVER_IP" "stat -c '%a %G' /var/log/php*-fpm.log 2>/dev/null || echo 'missing'")
echo "$PHP_LOG_PERMS" | grep -q '640 adm' && pass "PHP-FPM log: 640 adm" || fail "PHP-FPM log perms: $PHP_LOG_PERMS"

MANAGER_CODE=$(ssh ubuntu@"$SERVER_IP" "curl -sk --resolve '$DOMAIN:443:127.0.0.1' -o /dev/null -w '%{http_code}' 'https://$DOMAIN/manager/' 2>/dev/null || echo '000'")
[ "$MANAGER_CODE" = "200" ] && pass "MODX manager: HTTP 200" || warn "MODX manager: HTTP $MANAGER_CODE"
echo "modx_manager_code=$MANAGER_CODE"

RESP_TIME=$(ssh ubuntu@"$SERVER_IP" "curl -sk --resolve '$DOMAIN:443:127.0.0.1' -o /dev/null -w '%{time_total}' 'https://$DOMAIN/' 2>/dev/null || echo '0'" | tr ',' '.')
RESP_MS=$(printf "%.0f" "$RESP_TIME" 2>/dev/null || echo "0")
echo "response_time_ms=$RESP_MS"
[ "${RESP_MS:-999}" -lt 2000 ] && pass "Response time: ${RESP_MS}ms" || warn "Response time: ${RESP_MS}ms (slow)"

MEM_TOTAL=$(ssh ubuntu@"$SERVER_IP" "free -m | awk 'NR==2 {print \$2}'" 2>/dev/null || echo "0")
MEM_USED=$(ssh ubuntu@"$SERVER_IP" "free -m | awk 'NR==2 {print \$3}'" 2>/dev/null || echo "0")
MEM_PCT=$(ssh ubuntu@"$SERVER_IP" "free -m | awk 'NR==2 {printf \"%.0f\", \$3/\$2*100}'" 2>/dev/null || echo "0")
echo "memory_usage=${MEM_USED}MB/${MEM_TOTAL}MB (${MEM_PCT}%)"
echo "memory_pct=$MEM_PCT"

PROJ_CLOUD=$(ssh ubuntu@"$SERVER_IP" "rclone lsf gdrive-crypt:DreamSeed/backups/project/ --max-depth 1 2>/dev/null | wc -l")
DB_CLOUD=$(ssh ubuntu@"$SERVER_IP" "rclone lsf gdrive-crypt:DreamSeed/backups/db/ --max-depth 1 2>/dev/null | wc -l")
echo "cloud_project=$PROJ_CLOUD"
echo "cloud_db=$DB_CLOUD"
echo "cloud_redis=$REDIS_CLOUD"

EXP_NODE=$(ssh ubuntu@"$SERVER_IP" "curl -sf http://127.0.0.1:9100/metrics 2>/dev/null | grep -c 'node_cpu' || echo 0")
EXP_MYSQL=$(ssh ubuntu@"$SERVER_IP" "curl -sf http://127.0.0.1:9104/metrics 2>/dev/null | grep -c 'mysql_up' || echo 0")
EXP_REDIS=$(ssh ubuntu@"$SERVER_IP" "curl -sf http://127.0.0.1:9121/metrics 2>/dev/null | grep -c 'redis_up' || echo 0")
EXP_NGINX=$(ssh ubuntu@"$SERVER_IP" "curl -sf http://127.0.0.1:9113/metrics 2>/dev/null | grep -c 'nginx_connections_active' || curl -sf http://127.0.0.1:9117/metrics 2>/dev/null | grep -c 'apache_up' || echo 0")
EXP_VM=$(ssh ubuntu@"$SERVER_IP" "curl -sf http://127.0.0.1:8428/health 2>/dev/null | grep -c 'OK' || echo 0")
echo "exporter_node=$EXP_NODE"
echo "exporter_mysql=$EXP_MYSQL"
echo "exporter_redis=$EXP_REDIS"
echo "exporter_web=$EXP_NGINX"
echo "exporter_vm=$EXP_VM"

CRON_COUNT=$(ssh ubuntu@"$SERVER_IP" "crontab -l 2>/dev/null | grep -v '^#' | grep -v '^$' | wc -l" || echo 0)
echo "cron_jobs=$CRON_COUNT"
[ "${CRON_COUNT:-0}" -ge 5 ] && pass "Cron jobs: $CRON_COUNT" || warn "Cron jobs: ${CRON_COUNT:-0} (expected 5+)"

GRAFANA_LOGIN=$(ssh ubuntu@"$SERVER_IP" 'PW=$(sudo grep -oP "(?<=GF_SECURITY_ADMIN_PASSWORD=).*" /etc/grafana/grafana.env 2>/dev/null || true); if [ -z "$PW" ]; then echo "no-env"; exit 0; fi; F=$(mktemp); chmod 600 "$F"; printf "machine 127.0.0.1\nlogin admin\npassword %s\n" "$PW" > "$F"; R=$(curl -s -o /dev/null -w "%{http_code}" --netrc-file "$F" http://127.0.0.1:3000/api/user 2>/dev/null || echo "000"); rm -f "$F"; echo "$R"' 2>/dev/null || echo "000")
[ "${GRAFANA_LOGIN:-000}" = "200" ] && pass "Grafana admin login OK (HTTP 200)" || warn "Grafana admin login: HTTP ${GRAFANA_LOGIN:-000}"

# ==== Checks end ====
echo "test_summary=P:${P} F:${F} W:${W}"
echo "test_fails=${FAIL_ITEMS:-none}"
[ "$F" -eq 0 ]
