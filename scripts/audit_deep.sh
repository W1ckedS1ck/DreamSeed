#!/bin/bash
# Deep audit checks — supplements check_services.sh with security perimeter,
# PHP config, DB internals, monitoring health, and infrastructure validation.
# Run on-server: bash /home/ubuntu/Scripts/audit_deep.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common_functions.sh"

DOMAIN="${DOMAIN:-}"
fail=0

# ── Auto-detect ──────────────────────────────────────────────────────────────

WEB_SVC=""; WEB_SVC_SHORT=""
if systemctl is-active nginx &>/dev/null; then
    WEB_SVC="nginx"
elif systemctl is-active apache2 &>/dev/null; then
    WEB_SVC="apache2"
fi

PHP_VER=""
for v in /etc/php/*/fpm/pool.d/www.conf; do
    [[ -f "$v" ]] && PHP_VER=$(echo "$v" | sed 's|/etc/php/||; s|/fpm/pool.d/www.conf||')
done
[[ -z "$PHP_VER" ]] && PHP_VER="8.3"

detect_domain() {
    local d
    d=$(ls /etc/nginx/sites-enabled/ 2>/dev/null | grep -v default | grep -v ssl | head -1)
    [[ -z "$d" ]] && d=$(ls /etc/apache2/sites-enabled/ 2>/dev/null | grep -v default | head -1)
    echo "${d:-}"
}
[[ -z "$DOMAIN" ]] && DOMAIN=$(detect_domain)

# Colors
P="${GREEN}✓${NC}"; F="${RED}✗${NC}"; W="${YELLOW}⚠${NC}"

ok()   { echo "  $P $1"; export_metric "audit_$2 1"; }
fail() { echo "  $F $1"; export_metric "audit_$2 0"; fail=1; }
warn() { echo "  $W $1"; export_metric "audit_$2 0"; }

echo ""
echo "═══ DEEP AUDIT REPORT ═══"
echo "  Server: $(hostname)"
echo "  Domain: ${DOMAIN:-unknown}"
echo "  Web:    $WEB_SVC"
echo "  PHP:    $PHP_VER"
echo ""

# ── 1. Security Perimeter ────────────────────────────────────────────────────

echo "── Security Perimeter ──"

# Adminer blocked via domain
_adminer_code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 "https://${DOMAIN}/adminer-4.8.1-mysql.php" 2>/dev/null || echo "000")
if [[ "$_adminer_code" == "403" || "$_adminer_code" == "404" ]]; then
    ok "Adminer blocked (via domain) — $_adminer_code" "adminer_domain_blocked"
else
    fail "Adminer exposed via domain — HTTP $_adminer_code" "adminer_domain_blocked"
fi

# Adminer blocked via direct IP + Host (nginx 444 → empty reply → curl exits 52)
_raw_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
if [[ -n "$_raw_ip" ]]; then
    _adm_rc=0
    _adm_direct=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 -H "Host: ${DOMAIN}" "https://${_raw_ip}/adminer-4.8.1-mysql.php" 2>/dev/null) || _adm_rc=$?
    if [[ $_adm_rc -ne 0 || "$_adm_direct" == "403" || "$_adm_direct" == "404" ]]; then
        ok "Adminer blocked (direct IP) — nginx 444" "adminer_direct_blocked"
    else
        fail "Adminer accessible via direct IP — HTTP $_adm_direct" "adminer_direct_blocked"
    fi
fi

# Direct IP access blocked (nginx returns 444 → empty reply, curl exits 52)
_curl_rc=0
_direct_out=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 "https://${_raw_ip}/" 2>/dev/null) || _curl_rc=$?
if [[ $_curl_rc -ne 0 || "$_direct_out" == "000" ]]; then
    ok "Direct IP blocked — nginx 444" "direct_ip_blocked"
else
    fail "Direct IP not blocked — $_direct_out" "direct_ip_blocked"
fi

# Host header injection
_curl_rc=0
_host_out=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 -H 'Host: evil.com' "https://${_raw_ip}/" 2>/dev/null) || _curl_rc=$?
if [[ $_curl_rc -ne 0 || "$_host_out" == "000" ]]; then
    ok "Host header injection blocked — nginx 444" "host_header_blocked"
else
    fail "Host header injection not blocked — $_host_out" "host_header_blocked"
fi

# Sensitive paths
echo "  ── Sensitive paths ──"
_sp_ok=0
for _sp in /.env /core/config/config.inc.php /.git/config /backup.sql; do
    _sp_code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 "https://${DOMAIN}${_sp}" 2>/dev/null || echo "000")
    if [[ "$_sp_code" == "404" || "$_sp_code" == "403" || "$_sp_code" == "000" ]]; then
        echo "    $P $_sp → $_sp_code"
        ((_sp_ok++)) || true
    else
        echo "    $F $_sp → $_sp_code (exposed!)"
    fi
done
if [[ $_sp_ok -eq 4 ]]; then
    export_metric "audit_sensitive_paths_blocked 1"
else
    export_metric "audit_sensitive_paths_blocked 0"
    fail=1
fi

# Cloudflare real IP count
_cf_count=$(grep -c 'set_real_ip_from' /etc/nginx/conf.d/cloudflare-realip.conf 2>/dev/null || echo "0")
if [[ "$_cf_count" -ge 15 ]]; then
    ok "Cloudflare real IP: $_cf_count ranges" "cloudflare_realip"
else
    warn "Cloudflare real IP only $_cf_count ranges (may be dev)" "cloudflare_realip"
fi

# Fail2ban additional jails
for _fj in modx-admin dreamseed-botsearch dreamseed-bad-request; do
    if sudo fail2ban-client status "$_fj" &>/dev/null; then
        ok "Fail2ban jail: $_fj" "f2b_jail_$_fj"
    else
        warn "Fail2ban jail MISSING: $_fj" "f2b_jail_$_fj"
    fi
done

# ── 2. System Infrastructure ────────────────────────────────────────────────

echo ""
echo "── System Infrastructure ──"

# Unattended upgrades
if systemctl is-active unattended-upgrades &>/dev/null; then
    ok "Unattended upgrades active" "unattended_upgrades"
else
    fail "Unattended upgrades not active" "unattended_upgrades"
fi

# Logrotate entries
_lr_count=$(ls /etc/logrotate.d/ 2>/dev/null | grep -c -E 'nginx|php|mariadb|redis' || echo "0")
if [[ "$_lr_count" -ge 4 ]]; then
    ok "Logrotate: $_lr_count entries" "logrotate_entries"
else
    fail "Logrotate: only $_lr_count entries (expect 4)" "logrotate_entries"
fi

# Swap
if swapon --show 2>/dev/null | grep -q swapfile; then
    ok "Swap enabled" "swap_enabled"
else
    warn "No swap" "swap_enabled"
fi

# Sysctl hardening
_syncookies=$(sysctl net.ipv4.tcp_syncookies 2>/dev/null | awk '{print $3}')
_rpfilter=$(sysctl net.ipv4.conf.all.rp_filter 2>/dev/null | awk '{print $3}')
_sourceroute=$(sysctl net.ipv4.conf.all.accept_source_route 2>/dev/null | awk '{print $3}')
if [[ "$_syncookies" == "1" && "$_rpfilter" == "1" && "$_sourceroute" == "0" ]]; then
    ok "sysctl hardening: syncookies=$_syncookies rp_filter=$_rpfilter srcroute=$_sourceroute" "sysctl_hardening"
else
    fail "sysctl hardening — syncookies=$_syncookies rp_filter=$_rpfilter srcroute=$_sourceroute" "sysctl_hardening"
fi

# systemd Restart=always
_nginx_restart=$(systemctl show nginx 2>/dev/null | grep 'Restart=always' | head -1 || echo "")
_php_restart=$(systemctl show "php${PHP_VER}-fpm" 2>/dev/null | grep 'Restart=always' | head -1 || echo "")
if [[ -n "$_nginx_restart" && -n "$_php_restart" ]]; then
    ok "systemd Restart=always: nginx + php-fpm" "systemd_restart_always"
else
    fail "systemd Restart=always missing" "systemd_restart_always"
fi

# MariaDB bind
_mysql_bind=$(ss -tlnp 2>/dev/null | grep 3306 | grep -c '127.0.0.1:3306' || echo "0")
if [[ "$_mysql_bind" -ge 1 ]]; then
    ok "MariaDB bound to 127.0.0.1:3306" "mysql_bind_local"
else
    fail "MariaDB not bound to localhost" "mysql_bind_local"
fi

# Redis bind
_redis_bind=$(ss -tlnp 2>/dev/null | grep 6379 | grep -c '127.0.0.1:6379' || echo "0")
if [[ "$_redis_bind" -ge 1 ]]; then
    ok "Redis bound to 127.0.0.1:6379" "redis_bind_local"
else
    fail "Redis not bound to localhost" "redis_bind_local"
fi

# Redis dangerous commands renamed
_redis_cmds=$(sudo grep -c 'rename-command' /etc/redis/redis.conf 2>/dev/null || echo "0")
if [[ "$_redis_cmds" -ge 5 ]]; then
    ok "Redis dangerous commands renamed ($_redis_cmds)" "redis_rename_cmds"
else
    warn "Redis: only $_redis_cmds renamed commands (expect 5+)" "redis_rename_cmds"
fi

# SSH hardening
_ssh_root=$(sudo grep -E '^PermitRootLogin' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' || echo "")
_ssh_pw=$(sudo grep -E '^PasswordAuthentication' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' || echo "")
if [[ "$_ssh_root" == "no" && ("$_ssh_pw" == "no" || -z "$_ssh_pw") ]]; then
    ok "SSH hardening: PermitRootLogin=$_ssh_root PasswordAuthentication=${_ssh_pw:-no(default)}" "ssh_hardening"
else
    warn "SSH hardening — root=$_ssh_root pw=$_ssh_pw" "ssh_hardening"
fi

# Cache tmpfs mount
_cache_mount=$(findmnt -n /var/www/html/core/cache 2>/dev/null | grep -c tmpfs || echo "0")
if [[ "$_cache_mount" -ge 1 ]]; then
    ok "Cache on tmpfs" "cache_tmpfs"
else
    warn "Cache NOT on tmpfs" "cache_tmpfs"
fi

# ── 3. PHP Deep ─────────────────────────────────────────────────────────────

echo ""
echo "── PHP Deep ──"

# Extensions
_req_exts="pdo_mysql redis curl mbstring json xml zip gd openssl"
_ext_missing=0
for _ext in $_req_exts; do
    if ! php -m 2>/dev/null | grep -qi "$_ext"; then
        echo "    $F Extension missing: $_ext"
        ((_ext_missing++)) || true
    fi
done
if [[ $_ext_missing -eq 0 ]]; then
    ok "All required PHP extensions loaded" "php_extensions"
else
    fail "PHP: $_ext_missing extension(s) missing" "php_extensions"
fi

# PHP limits
_limits=$(php -i 2>/dev/null | grep -E 'memory_limit|upload_max_filesize|post_max_size|max_execution_time' | awk -F'=>' '{print $2}' | tr -d ' ')
echo "    Limits: $_limits"

# Opcache status
_opcache_enabled=$(php -i 2>/dev/null | grep 'opcache.enable =>' | head -1 | awk '{print $3}')
_opcache_mem=$(php -i 2>/dev/null | grep 'opcache.memory_consumption' | head -1 | awk '{print $3}')
_opcache_files=$(php -i 2>/dev/null | grep 'opcache.max_accelerated_files' | head -1 | awk '{print $3}')
echo "    Opcache: enabled=$_opcache_enabled mem=${_opcache_mem}MB files=$_opcache_files"

# FPM session handler
_fpm_save_handler=$(php-fpm"${PHP_VER}" -i 2>/dev/null | grep 'session.save_handler' | head -1 | awk '{print $3}')
_fpm_save_path=$(php-fpm"${PHP_VER}" -i 2>/dev/null | grep 'session.save_path' | head -1 | awk '{print $3}')
if [[ "$_fpm_save_handler" == "redis" ]]; then
    ok "FPM session handler: redis" "fpm_session_redis"
    echo "    FPM session path: $_fpm_save_path"
else
    warn "FPM session handler: $_fpm_save_handler (expect redis)" "fpm_session_redis"
fi

# FPM processes
_fpm_procs=$(ps aux | grep php-fpm | grep -v grep | wc -l | tr -d ' ')
_fpm_mem=$(ps aux | grep php-fpm | grep -v grep | awk '{sum+=$6; count++} END {if(count>0) print int(sum/count/1024) " MB avg"; else print "0 MB"}')
echo "    FPM processes: $_fpm_procs ($_fpm_mem)"

# ── 4. Database ─────────────────────────────────────────────────────────────

echo ""
echo "── Database ──"

# MODX DB name
_db_name=$(grep "^\\\$dbase" /var/www/html/core/config/config.inc.php 2>/dev/null | cut -d"'" -f2 || echo "")
if [[ -z "$_db_name" ]]; then
    _db_name="modx_db"
    warn "Could not detect DB name from config, using $_db_name" "db_name"
else
    ok "DB name: $_db_name" "db_name"
fi

# MODX table count
_db_tables=$(mysql -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${_db_name}';" 2>/dev/null || echo "0")
if [[ "$_db_tables" -ge 50 ]]; then
    ok "MODX: $_db_tables tables" "modx_tables"
elif [[ "$_db_tables" -ge 1 ]]; then
    warn "MODX: only $_db_tables tables" "modx_tables"
else
    fail "MODX: no tables in $_db_name" "modx_tables"
fi

# MODX DB size
_db_size=$(mysql -N -e "SELECT ROUND(SUM(data_length+index_length)/1024/1024,2) FROM information_schema.tables WHERE table_schema='${_db_name}';" 2>/dev/null || echo "0")
echo "    MODX DB size: ${_db_size} MB"

# InnoDB buffer pool
_innodb_buf=$(mysql -N -e "SHOW VARIABLES LIKE 'innodb_buffer_pool_size'" 2>/dev/null | awk '{print $2}')
_innodb_buf_mb=$(( _innodb_buf / 1024 / 1024 ))
echo "    InnoDB buffer pool: ${_innodb_buf_mb} MB"

# Slow queries
_slow_q=$(mysql -N -e "SHOW GLOBAL STATUS LIKE 'Slow_queries'" 2>/dev/null | awk '{print $2}')
echo "    Slow queries: $_slow_q"

# MariaDB version
_mariadb_ver=$(mysql -V 2>/dev/null)
echo "    Version: $_mariadb_ver"

# ── 5. Redis ────────────────────────────────────────────────────────────────

echo ""
echo "── Redis ──"

_redis_ping=$(redis-cli ping 2>/dev/null)
if [[ "$_redis_ping" == "PONG" ]]; then
    ok "Redis ping OK" "redis_ping"
else
    fail "Redis not responding" "redis_ping"
fi

_redis_mem=$(redis-cli INFO memory 2>/dev/null | grep 'used_memory_human' | cut -d: -f2)
_redis_maxmem=$(redis-cli INFO memory 2>/dev/null | grep 'maxmemory_human' | cut -d: -f2)
_redis_keys=$(redis-cli DBSIZE 2>/dev/null)
_redis_ver=$(redis-server -v 2>/dev/null)
echo "    Version: $_redis_ver"
echo "    Memory: $_redis_mem / $_redis_maxmem"
echo "    Keys: $_redis_keys"

# ── 6. Monitoring ──────────────────────────────────────────────────────────

echo ""
echo "── Monitoring ──"

# VictoriaMetrics scrape targets
_up_targets=$(curl -s 'http://127.0.0.1:8428/api/v1/query?query=up' 2>/dev/null | python3 -c "
import sys,json
d=json.load(sys.stdin)
for r in d['data']['result']:
    print(r['metric']['job'], r['value'][1])
" 2>/dev/null) || _up_targets=""

if echo "$_up_targets" | grep -q '1'; then
    echo "    Scrape targets:"
    echo "$_up_targets" | while read -r _job _val; do
        [[ "$_val" == "1" ]] && echo "      $P $_job" || echo "      $F $_job ($_val)"
    done
    _all_up=$(echo "$_up_targets" | grep -c ' 0$' || true)
    if [[ "$_all_up" -eq 0 ]]; then
        ok "All scrape targets UP" "scrape_targets_up"
    else
        fail "$_all_up scrape target(s) DOWN" "scrape_targets_up"
    fi
else
    warn "Could not query scrape targets" "scrape_targets_up"
fi

# vmagent data flowing
_vmagent_blocks=$(curl -s 'http://127.0.0.1:8429/metrics' 2>/dev/null | grep '^vmagent_remotewrite_blocks_sent_total' | awk '{sum+=$2} END {print sum}' || echo "0")
if [[ "$_vmagent_blocks" -gt 0 ]]; then
    ok "vmagent: $_vmagent_blocks blocks sent" "vmagent_blocks"
else
    warn "vmagent: no blocks sent yet" "vmagent_blocks"
fi

# Node exporter custom metrics
_custom_metrics=$(curl -s 'http://127.0.0.1:9100/metrics' 2>/dev/null | grep -c 'backup_last_success\|upload_last_success' || echo "0")
echo "    Custom node metrics: $_custom_metrics"

# Grafana
_grafana_health=$(curl -s --max-time 5 'http://127.0.0.1:3000/api/health' 2>/dev/null || echo '{"database":"error"}')
_grafana_db=$(echo "$_grafana_health" | python3 -c "import sys,json; print(json.load(sys.stdin).get('database','error'))" 2>/dev/null || echo "error")
_grafana_ver=$(echo "$_grafana_health" | python3 -c "import sys,json; print(json.load(sys.stdin).get('version','unknown'))" 2>/dev/null || echo "unknown")

if [[ "$_grafana_db" == "ok" ]]; then
    ok "Grafana: v$_grafana_ver, DB $_grafana_db" "grafana_health"
else
    fail "Grafana unhealthy: DB=$_grafana_db" "grafana_health"
fi

# Grafana version check (should be 12.4.5 — downgraded from 13)
if [[ "$_grafana_ver" == "12.4.5" ]]; then
    ok "Grafana version: $_grafana_ver (correct downgrade)" "grafana_version"
elif [[ "$_grafana_ver" =~ ^12\. ]]; then
    warn "Grafana version: $_grafana_ver (12.x OK)" "grafana_version"
else
    warn "Grafana version: $_grafana_ver (expect 12.4.5)" "grafana_version"
fi

# Grafana provisioning
if ls /etc/grafana/provisioning/datasources/ /etc/grafana/provisioning/dashboards/ &>/dev/null; then
    ok "Grafana provisioning files present" "grafana_provisioning"
else
    fail "Grafana provisioning missing" "grafana_provisioning"
fi

# Grafana firing alerts
_alerts_firing=$(curl -s 'http://127.0.0.1:3000/api/alertmanager/grafana/api/v2/alerts' 2>/dev/null | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    print(len(d))
except:
    print('error')
" 2>/dev/null || echo "error")
echo "    Grafana alerts firing: $_alerts_firing"

# Grafana memory
_grafana_mem=$(ps aux | grep grafana-server | grep -v grep | head -1 | awk '{printf "%.1f%% (%s MB RSS)", $4, int($6/1024)}' 2>/dev/null || echo "not found")
echo "    Grafana memory: $_grafana_mem"

# ── 7. MODX ─────────────────────────────────────────────────────────────────

echo ""
echo "── MODX ──"

if [[ -f /var/www/html/index.php ]]; then
    ok "index.php present" "modx_index"
else
    fail "index.php missing" "modx_index"
fi

# Cache writable
if sudo -u www-data touch /var/www/html/core/cache/_audit_test 2>/dev/null; then
    sudo rm -f /var/www/html/core/cache/_audit_test
    ok "Cache writable" "modx_cache_writable"
else
    fail "Cache not writable" "modx_cache_writable"
fi

# Session prefix
_session_prefix=$(grep 'table_prefix' /var/www/html/core/config/config.inc.php 2>/dev/null | head -1 | cut -d"'" -f2 || echo "")
if [[ "$_session_prefix" == "modx_" ]]; then
    ok "Session prefix: $_session_prefix" "modx_prefix"
else
    warn "Session prefix: $_session_prefix" "modx_prefix"
fi

# Manager 200
_manager_code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 "https://${DOMAIN}/manager/" 2>/dev/null || echo "000")
if [[ "$_manager_code" == "200" || "$_manager_code" == "301" || "$_manager_code" == "302" ]]; then
    ok "Manager: $_manager_code" "modx_manager"
else
    warn "Manager: $_manager_code" "modx_manager"
fi

# ── 8. SSL ──────────────────────────────────────────────────────────────────

echo ""
echo "── SSL ──"

# Check via curl
if curl -sfk --max-time 5 "https://${DOMAIN}/" > /dev/null 2>&1; then
    ok "SSL: Cloudflare edge (${DOMAIN})" "ssl_active"
elif certbot certificates 2>/dev/null | grep -q "^  Certificate Name:"; then
    ok "SSL: Let's Encrypt" "ssl_active"
elif openssl x509 -in /etc/ssl/certs/ssl-cert-snakeoil.pem -noout 2>/dev/null; then
    ok "SSL: self-signed" "ssl_active"
else
    fail "No SSL certificate" "ssl_active"
fi

# ── 9. Performance ──────────────────────────────────────────────────────────

echo ""
echo "── Performance ──"

# Site via domain
_perf=$(curl -sk -o /dev/null -w 'TTFB: %{time_starttransfer}s | Total: %{time_total}s | Code: %{http_code}' --max-time 10 "https://${DOMAIN}/" 2>/dev/null)
echo "    Site: $_perf"

# Static file
_perf_static=$(curl -sk -o /dev/null -w 'TTFB: %{time_starttransfer}s | Total: %{time_total}s | Code: %{http_code}' --max-time 10 "https://${DOMAIN}/theme/css/style.css" 2>/dev/null)
echo "    Static: $_perf_static"

# Page size
_page_size=$(curl -sk -o /dev/null -w 'Size: %{size_download} bytes' --max-time 10 "https://${DOMAIN}/" 2>/dev/null)
echo "    $_page_size"

# Brotli compression
_brotli=$(curl -sI -H 'Accept-Encoding: br' --max-time 5 "https://${DOMAIN}/theme/css/style.css" 2>/dev/null | grep -ci 'content-encoding: br' || echo "0")
if [[ "$_brotli" -ge 1 ]]; then
    ok "Brotli compression active" "brotli"
else
    warn "Brotli compression not detected" "brotli"
fi

# ── 10. Backup Infrastructure ──────────────────────────────────────────────

echo ""
echo "── Backup Infrastructure ──"

if [[ -f ~/.config/rclone/rclone.conf ]]; then
    ok "Rclone config present" "rclone_config"
else
    fail "Rclone config MISSING" "rclone_config"
fi

_scripts_count=$(ls /home/ubuntu/Scripts/*.sh 2>/dev/null | wc -l)
echo "    Shell scripts: $_scripts_count"

# ── 11. Open Ports ─────────────────────────────────────────────────────────

echo ""
echo "── Open Ports (public) ──"

_open_ports=$(ss -tlnp 2>/dev/null | grep -v '127.0.0.1:\|::1:\|127.0.0.53\|127.0.0.54' | grep LISTEN | awk '{print $4}' | grep -v '^\[' | sort -u || echo "")
if [[ -n "$_open_ports" ]]; then
    echo "$_open_ports" | while read -r _p; do
        echo "    $_p"
    done
    _public_count=$(echo "$_open_ports" | grep -cE '0\.0\.0\.0' || echo "0")
    if [[ "$_public_count" -le 3 ]]; then
        ok "$_public_count public port(s): $(echo "$_open_ports" | grep -oP ':\K\d+' | tr '\n' ' ')" "public_ports"
    else
        warn "$_public_count public ports (expect ≤3: 22,80,443)" "public_ports"
    fi
else
    warn "No public ports detected" "public_ports"
fi

# ── Summary ─────────────────────────────────────────────────────────────────

echo ""
echo "═══ AUDIT SUMMARY ═══"
if [[ $fail -eq 0 ]]; then
    echo "  $P All checks passed"
    export_metric "audit_deep_overall 1"
else
    echo "  $F $fail check(s) failed or warned"
    export_metric "audit_deep_overall 0"
fi
echo ""

exit $fail
