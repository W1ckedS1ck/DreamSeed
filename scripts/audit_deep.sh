#!/bin/bash
# Deep audit — covers all auto-checkable items from AUDIT_CHECKLIST.md
# Sections: 1(System), 2(Web), 3(Security), 4(PHP), 5(DB), 6(Redis),
#           7(Sessions), 8(SSL), 9(MODX), 10(Perf), 11(Monitoring),
#           12(Grafana), 13(Backups), 14(Telegram), 15(Security),
#           16(Systemd), 17(Processes), 18(Ports), 19(Logs), 20(Functional)
# Manual only: backup manual run (smart_backup.sh + upload_backups_to_gdrive.sh)
# Run: bash /home/ubuntu/Scripts/audit_deep.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common_functions.sh"
[[ -f "$SCRIPT_DIR/.env" ]] && load_env "$SCRIPT_DIR/.env"

DOMAIN="${DOMAIN:-}"
CURL_RESOLVE=""
PUBLIC_IP=""
if [[ -n "$DOMAIN" ]]; then
  CURL_RESOLVE="--resolve ${DOMAIN}:443:127.0.0.1 --resolve ${DOMAIN}:80:127.0.0.1"
  PUBLIC_IP=$(curl -s --max-time 3 https://checkip.amazonaws.com 2>/dev/null || ip -4 addr show | grep -oP 'inet \K[\d.]+' | grep -v '127\.0\.0\.' | head -1)
  [[ -n "$PUBLIC_IP" ]] && CURL_RESOLVE_PUBLIC="--resolve ${DOMAIN}:443:${PUBLIC_IP} --resolve ${DOMAIN}:80:${PUBLIC_IP}" || CURL_RESOLVE_PUBLIC=""
fi
fail_count=0

# ── Auto-detect ──

WEB_SVC=""
if systemctl is-active nginx &>/dev/null; then WEB_SVC="nginx"
elif systemctl is-active apache2 &>/dev/null; then WEB_SVC="apache2"
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

RAW_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
SSH_KEY="${SSH_KEY:-}"
SCRIPTS_DIR="${SCRIPTS_DIR:-/home/ubuntu/Scripts}"
BACKUP_DIR="${BACKUP_DIR:-/home/ubuntu/backups}"

P="${GREEN}✓${NC}"; F="${RED}✗${NC}"; W="${YELLOW}⚠${NC}"

ok()   { echo "  $P $1"; export_metric "audit_$2 1"; }
fail() { echo "  $F $1"; export_metric "audit_$2 0"; fail_count=1; }
warn() { echo "  $W $1"; export_metric "audit_$2 0"; }
info() { echo "  • $1"; }

echo ""
echo "═══ DEEP AUDIT REPORT ═══"
echo "  Server: $(hostname)"
echo "  Domain: ${DOMAIN:-unknown}"
echo "  Web:    ${WEB_SVC:-unknown}"
echo "  PHP:    $PHP_VER"
echo ""

# ── 1. System ──────────────────────────────────────────────────────────────────

echo "── 1. System ──"

cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d= -f2 | tr -d '"' | while read -r v; do echo "    OS: $v"; done
echo "    Kernel: $(uname -a | awk '{print $3}')"
echo "    Uptime: $(uptime -p 2>/dev/null || uptime | awk '{$1=$2=$3=""; print}')"
echo "    CPU: $(nproc) cores"
echo "    Memory: $(free -h | awk '/Mem/ {print $3 " / " $2}')"
echo "    Disk: $(df -h --total 2>/dev/null | grep total | awk '{print $3 " / " $2 " (" $5 ")"}')"
if swapon --show 2>/dev/null | grep -q .; then
  echo "    Swap: $(swapon --show 2>/dev/null | awk 'NR==2{print $3 " / " $2}')"
fi

# Unattended upgrades
if systemctl is-active unattended-upgrades &>/dev/null; then
  ok "Unattended upgrades active" "unattended_upgrades"
else
  fail "Unattended upgrades not active" "unattended_upgrades"
fi

# Logrotate
_lr_count=$(ls /etc/logrotate.d/ 2>/dev/null | grep -c -E 'nginx|php|mariadb|redis' || true)
if [[ "$_lr_count" -ge 4 ]]; then
  ok "Logrotate: $_lr_count entries (nginx php mariadb redis)" "logrotate_entries"
else
  fail "Logrotate: only $_lr_count entries (expect 4)" "logrotate_entries"
fi

# Swap
if swapon --show 2>/dev/null | grep -q .; then
  ok "Swap enabled" "swap_enabled"
else
  warn "No swap" "swap_enabled"
fi

# Apt updates
_apt_updates=$(apt-get --just-print upgrade 2>/dev/null | grep -c '^Inst' || true)
echo "    Apt updates available: $_apt_updates"

# ── 2. Web Server ──────────────────────────────────────────────────────────────

echo ""
echo "── 2. Web Server ──"

# nginx -t
if [[ "$WEB_SVC" == "nginx" ]]; then
  if sudo nginx -t 2>&1 | grep -q "successful"; then
    ok "nginx config syntax OK" "nginx_syntax"
  else
    fail "nginx config syntax ERROR" "nginx_syntax"
  fi
  # Cloudflare realip (might be in conf.d, not directly in nginx.conf)
  if grep -q 'set_real_ip_from' /etc/nginx/conf.d/cloudflare-realip.conf 2>/dev/null; then
    ok "Cloudflare realip loaded" "cf_realip_loaded"
  else
    warn "Cloudflare realip not found in nginx config" "cf_realip_loaded"
  fi
fi

# HTTP→HTTPS redirect
if [[ -n "$DOMAIN" ]]; then
  _http_code=$(curl -sI -o /dev/null -w '%{http_code}' --max-time 5 $CURL_RESOLVE "http://${DOMAIN}/" 2>/dev/null || echo "000")
  if [[ "$_http_code" == "301" || "$_http_code" == "302" ]]; then
    ok "HTTP→HTTPS redirect ($_http_code)" "http_redirect"
  else
    warn "HTTP redirect: $_http_code (expect 301)" "http_redirect"
  fi
  # Site response
  _site_ttfb=$(curl -sk -o /dev/null -w '%{http_code} (%{time_total}s)' --max-time 10 $CURL_RESOLVE "https://${DOMAIN}/" 2>/dev/null || echo "error")
  echo "    Site: $_site_ttfb"
  # 404 handling
  _404_code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 $CURL_RESOLVE "https://${DOMAIN}/nonexistent" 2>/dev/null || echo "000")
  if [[ "$_404_code" == "404" ]]; then
    ok "404 handling: $_404_code" "http_404"
  else
    warn "404 returns $_404_code (expect 404)" "http_404"
  fi
fi

# Public endpoint check (via server's public IP — simulates external access)
if [[ -n "$CURL_RESOLVE_PUBLIC" ]]; then
  _pub_code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 $CURL_RESOLVE_PUBLIC "https://${DOMAIN}/" 2>/dev/null || echo "000")
  if [[ "$_pub_code" == "200" ]]; then
    ok "Public endpoint: $_pub_code" "public_endpoint"
  else
    warn "Public endpoint: $_pub_code (expect 200)" "public_endpoint"
  fi
elif [[ -n "$DOMAIN" ]]; then
  warn "Public endpoint: no public IP detected" "public_endpoint"
fi

# ── 3. Security Perimeter ──────────────────────────────────────────────────────

echo ""
echo "── 3. Security Perimeter ──"

# Adminer blocked via domain
_adminer_code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 $CURL_RESOLVE "https://${DOMAIN}/adminer-4.8.1-mysql.php" 2>/dev/null || echo "000")
if [[ "$_adminer_code" == "403" || "$_adminer_code" == "404" ]]; then
  ok "Adminer blocked (via domain) — $_adminer_code" "adminer_domain_blocked"
else
  fail "Adminer exposed via domain — HTTP $_adminer_code" "adminer_domain_blocked"
fi

# Adminer blocked via direct IP
if [[ -n "$RAW_IP" ]]; then
  _adm_direct=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 -H "Host: ${DOMAIN}" "https://${RAW_IP}/adminer-4.8.1-mysql.php" 2>/dev/null || echo "000")
  _adm_direct="${_adm_direct:0:3}"
  if [[ "$_adm_direct" == "000" || "$_adm_direct" == "403" || "$_adm_direct" == "404" ]]; then
    ok "Adminer blocked (direct IP)" "adminer_direct_blocked"
  else
    fail "Adminer accessible via direct IP — $_adm_direct" "adminer_direct_blocked"
  fi
fi

# Direct IP blocked
if [[ -n "$RAW_IP" ]]; then
  _direct=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 "https://${RAW_IP}/" 2>/dev/null || echo "000")
  _direct="${_direct:0:3}"
  if [[ "$_direct" == "000" || "$_direct" == "400" || "$_direct" == "403" || "$_direct" == "444" ]]; then
    ok "Direct IP blocked" "direct_ip_blocked"
  else
    fail "Direct IP not blocked — $_direct" "direct_ip_blocked"
  fi
fi

# Host header injection
if [[ -n "$RAW_IP" ]]; then
  _host=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 -H 'Host: evil.com' "https://${RAW_IP}/" 2>/dev/null || echo "000")
  _host="${_host:0:3}"
  if [[ "$_host" == "000" || "$_host" == "400" || "$_host" == "403" || "$_host" == "444" ]]; then
    ok "Host header injection blocked" "host_header_blocked"
  else
    fail "Host header injection not blocked — $_host" "host_header_blocked"
  fi
fi

# Sensitive paths
echo "  ── Sensitive paths ──"
_sp_ok=0
for _sp in /.env /core/config/config.inc.php /.git/config /backup.sql; do
  _sp_code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 $CURL_RESOLVE "https://${DOMAIN}${_sp}" 2>/dev/null || echo "000")
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
  fail_count=1
fi

# Cloudflare real IP
_cf_count=$(grep -c 'set_real_ip_from' /etc/nginx/conf.d/cloudflare-realip.conf 2>/dev/null || true)
if [[ "$_cf_count" -ge 15 ]]; then
  ok "Cloudflare real IP: $_cf_count ranges" "cloudflare_realip"
else
  warn "Cloudflare real IP only $_cf_count ranges" "cloudflare_realip"
fi

# Fail2ban web jails
for _fj in modx-admin dreamseed-botsearch dreamseed-bad-request; do
  if sudo fail2ban-client status "$_fj" &>/dev/null; then
    ok "Fail2ban jail: $_fj" "f2b_jail_$_fj"
  else
    warn "Fail2ban jail MISSING: $_fj" "f2b_jail_$_fj"
  fi
done

# SSH hardening
_ssh_root=$(sudo sshd -T 2>/dev/null | grep -E '^permitrootlogin' | awk '{print $2}')
_ssh_pw=$(sudo sshd -T 2>/dev/null | grep -E '^passwordauthentication' | awk '{print $2}')
if [[ "$_ssh_root" == "no" && ("$_ssh_pw" == "no" || -z "$_ssh_pw") ]]; then
  ok "SSH: PermitRootLogin=$_ssh_root PasswordAuth=${_ssh_pw:-no}" "ssh_hardening"
else
  warn "SSH: root=$_ssh_root pw=$_ssh_pw" "ssh_hardening"
fi

# ── 4. PHP ─────────────────────────────────────────────────────────────────────

echo ""
echo "── 4. PHP ──"

echo "    Version: $(php -v 2>/dev/null | head -1)"
echo "    FPM: $(systemctl is-active "php${PHP_VER}-fpm" 2>/dev/null || echo "inactive")"

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
  ok "All required PHP extensions" "php_extensions"
else
  fail "PHP extensions: $_ext_missing missing" "php_extensions"
fi

# Limits
_limits=$(php -i 2>/dev/null | grep -E 'memory_limit|upload_max_filesize|post_max_size|max_execution_time' | awk -F'=>' '{print $2}' | tr -d ' ')
echo "    Limits: $_limits"

# Opcache
_opcache_enabled=$(php -i 2>/dev/null | grep 'opcache.enable =>' | head -1 | awk '{print $3}')
_opcache_mem=$(php -i 2>/dev/null | grep 'opcache.memory_consumption' | head -1 | awk '{print $3}')
_opcache_files=$(php -i 2>/dev/null | grep 'opcache.max_accelerated_files' | head -1 | awk '{print $3}')
echo "    Opcache: enabled=$_opcache_enabled mem=${_opcache_mem}MB files=$_opcache_files"

# FPM session handler (check pool config — php-fpm -i ignores php_value overrides)
_fpm_save_handler=$(grep -r 'session.save_handler' /etc/php/*/fpm/pool.d/ 2>/dev/null | grep 'php_value' | awk -F'=' '{print $2}' | tr -d ' ' | head -1)
if [[ "$_fpm_save_handler" == "redis" ]]; then
  ok "FPM session handler: redis (pool override)" "fpm_session_redis"
elif redis-cli --scan --pattern 'PHPREDIS_*' 2>/dev/null | head -1 | grep -q .; then
  ok "FPM session handler: pool redis (verified by Redis keys)" "fpm_session_redis"
else
  warn "FPM session handler: $_fpm_save_handler (expect redis)" "fpm_session_redis"
fi

# FPM processes
_fpm_procs=$(ps aux | grep php-fpm | grep -v grep | wc -l | tr -d ' ')
_fpm_mem=$(ps aux | grep php-fpm | grep -v grep | awk '{sum+=$6; count++} END {if(count>0) print int(sum/count/1024) " MB avg"; else print "0 MB"}')
echo "    FPM workers: $_fpm_procs ($_fpm_mem)"

# ── 5. Database ────────────────────────────────────────────────────────────────

echo ""
echo "── 5. Database ──"

echo "    Version: $(mysql -V 2>/dev/null | head -1)"
echo "    Uptime: $(mysql -N -e "SHOW STATUS LIKE \"Uptime\"" 2>/dev/null | awk '{print $2 "s"}')"

_db_name=$(grep "^\\\$dbase" /var/www/html/core/config/config.inc.php 2>/dev/null | cut -d"'" -f2 || echo "modx_db")
_db_tables=$(mysql -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${_db_name}';" 2>/dev/null || true)
if [[ "$_db_tables" -ge 50 ]]; then
  ok "MODX: $_db_tables tables" "modx_tables"
elif [[ "$_db_tables" -ge 1 ]]; then
  warn "MODX: only $_db_tables tables" "modx_tables"
else
  fail "MODX: no tables in $_db_name" "modx_tables"
fi

_db_size=$(mysql -N -e "SELECT ROUND(SUM(data_length+index_length)/1024/1024,2) FROM information_schema.tables WHERE table_schema='${_db_name}';" 2>/dev/null || true)
_innodb_buf=$(mysql -N -e "SHOW VARIABLES LIKE 'innodb_buffer_pool_size'" 2>/dev/null | awk '{printf "%.0f MB", $2/1024/1024}')
_slow_q=$(mysql -N -e "SHOW GLOBAL STATUS LIKE 'Slow_queries'" 2>/dev/null | awk '{print $2}')
echo "    Size: ${_db_size} MB | InnoDB buffer: ${_innodb_buf} | Slow queries: $_slow_q"

if ss -tlnp 2>/dev/null | grep -q '127.0.0.1:3306'; then
  ok "MariaDB bound to localhost" "mysql_bind_local"
else
  fail "MariaDB NOT bound to localhost" "mysql_bind_local"
fi

# ── 6. Redis ───────────────────────────────────────────────────────────────────

echo ""
echo "── 6. Redis ──"

if redis-cli ping 2>/dev/null | grep -q PONG; then
  ok "Redis ping OK" "redis_ping"
else
  fail "Redis not responding" "redis_ping"
fi

echo "    Version: $(redis-server -v 2>/dev/null | awk '{print $3}')"
echo "    Memory: $(redis-cli INFO memory 2>/dev/null | grep 'used_memory_human' | cut -d: -f2) / $(redis-cli INFO memory 2>/dev/null | grep 'maxmemory_human' | cut -d: -f2)"
echo "    Keys: $(redis-cli DBSIZE 2>/dev/null)"

if ss -tlnp 2>/dev/null | grep -q '127.0.0.1:6379'; then
  ok "Redis bound to localhost" "redis_bind_local"
else
  fail "Redis NOT bound to localhost" "redis_bind_local"
fi

_redis_cmds=$(sudo grep -c 'rename-command' /etc/redis/redis.conf 2>/dev/null || true)
if [[ "$_redis_cmds" -ge 5 ]]; then
  ok "Redis dangerous commands renamed ($_redis_cmds)" "redis_rename_cmds"
else
  warn "Redis: only $_redis_cmds renamed (expect 5+)" "redis_rename_cmds"
fi

# ── 7. Sessions ────────────────────────────────────────────────────────────────

echo ""
echo "── 7. PHP Sessions (Redis via FPM) ──"

# session_handler_class
_handler_class=$(mysql -N "$_db_name" -e "SELECT \`value\` FROM \`${_db_name}\`.\`modx_system_settings\` WHERE \`key\` = \"session_handler_class\"" 2>/dev/null || echo "")
if [[ -z "$_handler_class" || "$_handler_class" == "" ]]; then
  ok "session_handler_class empty → PHP native handler" "session_handler_class"
else
  fail "session_handler_class = '$_handler_class' (should be empty!)" "session_handler_class"
fi

# Redis session test
_redis_before=$(redis-cli DBSIZE 2>/dev/null || true)
_session_keys=$(redis-cli --scan --pattern "PHPREDIS_SESSION:*" 2>/dev/null | head -3 | tr '\n' ' ' || true)
echo "    Redis session keys: $_redis_before total ($_session_keys)"

# ── 8. SSL ─────────────────────────────────────────────────────────────────────

echo ""
echo "── 8. SSL ──"

# Cloudflare edge
if curl -sfk --max-time 5 $CURL_RESOLVE "https://${DOMAIN}/" > /dev/null 2>&1; then
  ok "SSL: Cloudflare edge" "ssl_active"
else
  warn "SSL check failed for $DOMAIN" "ssl_active"
fi

# Local certificates
if sudo certbot certificates 2>/dev/null | grep -q "Certificate Name:"; then
  echo "    Certbot: certificates present"
  sudo certbot certificates 2>/dev/null | grep "Expiry Date" | head -1 | sed 's/^/    /'
elif ls /etc/ssl/certs/selfsigned.crt 2>/dev/null; then
  _expiry=$(sudo openssl x509 -enddate -noout -in /etc/ssl/certs/selfsigned.crt 2>/dev/null | cut -d= -f2 || echo "unknown")
  echo "    Self-signed, expires: $_expiry"
else
  warn "No local SSL certificates" "ssl_cert"
fi

# ── 9. MODX ────────────────────────────────────────────────────────────────────

echo ""
echo "── 9. MODX ──"

if [[ -f /var/www/html/index.php ]]; then
  ok "index.php present" "modx_index"
else
  fail "index.php MISSING" "modx_index"
fi

if sudo -u www-data touch /var/www/html/core/cache/_audit_test 2>/dev/null; then
  sudo rm -f /var/www/html/core/cache/_audit_test
  ok "Cache writable" "modx_cache_writable"
else
  fail "Cache NOT writable" "modx_cache_writable"
fi

# Cache on tmpfs
if findmnt -n /var/www/html/core/cache 2>/dev/null | grep -q tmpfs; then
  ok "Cache on tmpfs" "cache_tmpfs"
else
  warn "Cache NOT on tmpfs" "cache_tmpfs"
fi

_prefix=$(grep 'table_prefix' /var/www/html/core/config/config.inc.php 2>/dev/null | head -1 | cut -d"'" -f2 || echo "")
echo "    Table prefix: $_prefix"

_manager_code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 $CURL_RESOLVE "https://${DOMAIN}/manager/" 2>/dev/null || echo "000")
if [[ "$_manager_code" == "200" || "$_manager_code" == "301" || "$_manager_code" == "302" ]]; then
  ok "Manager: $_manager_code" "modx_manager"
else
  warn "Manager: $_manager_code" "modx_manager"
fi

# ── 10. Performance ────────────────────────────────────────────────────────────

echo ""
echo "── 10. Performance ──"

_site=$(curl -sk -o /dev/null -w 'HTTP %{http_code} | TTFB: %{time_starttransfer}s | Total: %{time_total}s' --max-time 10 $CURL_RESOLVE "https://${DOMAIN}/" 2>/dev/null || echo "error")
echo "    Site: $_site"

_static=$(curl -sk -o /dev/null -w 'HTTP %{http_code} | TTFB: %{time_starttransfer}s | Total: %{time_total}s' --max-time 10 $CURL_RESOLVE "https://${DOMAIN}/theme/css/style.css" 2>/dev/null || echo "error")
echo "    Static: $_static"

_size=$(curl -sk -o /dev/null -w '%{size_download} bytes' --max-time 10 $CURL_RESOLVE "https://${DOMAIN}/" 2>/dev/null || echo "error")
echo "    Page size: $_size"

_brotli=$(curl -skI -H 'Accept-Encoding: br' --resolve "${DOMAIN}:443:127.0.0.1" --max-time 5 "https://${DOMAIN}/theme/css/style.css" 2>/dev/null | grep -ci 'content-encoding: br' || true)
if [[ "$_brotli" -ge 1 ]]; then
  ok "Brotli compression" "brotli"
else
  warn "Brotli not detected" "brotli"
fi

# ── 11. Monitoring ─────────────────────────────────────────────────────────────

echo ""
echo "── 11. Monitoring ──"

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
    fail "$_all_up target(s) DOWN" "scrape_targets_up"
  fi
else
  warn "Could not query scrape targets" "scrape_targets_up"
fi

# vmagent
_vmagent_blocks=$(curl -s 'http://127.0.0.1:8429/metrics' 2>/dev/null | grep '^vmagent_remotewrite_blocks_sent_total' | awk '{sum+=$2} END {print sum}' || true)
_vmagent_errors=$(curl -s 'http://127.0.0.1:8429/metrics' 2>/dev/null | grep '^vmagent_remotewrite_errors_total' | awk '{sum+=$2} END {print sum}' || true)
if [[ "$_vmagent_blocks" -gt 0 && "$_vmagent_errors" -eq 0 ]]; then
  ok "vmagent: $_vmagent_blocks blocks sent, 0 errors" "vmagent"
else
  warn "vmagent: $_vmagent_blocks blocks, $_vmagent_errors errors" "vmagent"
fi

# Exporters HTTP 200
for _p in 9100 9113 9121 9104; do
  _n="node"; case $_p in 9113) _n="nginx";; 9121) _n="redis";; 9104) _n="mysql";; esac
  _code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:$_p/" 2>/dev/null || echo "000")
  if [[ "$_code" == "200" ]]; then
    ok "${_n}_exporter ($_p)" "${_n}_exporter"
  else
    warn "${_n}_exporter ($_p): $_code" "${_n}_exporter"
  fi
done

# Custom metrics (pushed directly to VictoriaMetrics, not via node_exporter)
_backup_metric=$(curl -s --max-time 5 'http://127.0.0.1:8428/api/v1/query?query=backup_last_success_timestamp' 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d['data']['result']))" 2>/dev/null || echo "0")
_upload_metric=$(curl -s --max-time 5 'http://127.0.0.1:8428/api/v1/query?query=upload_last_success_timestamp' 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d['data']['result']))" 2>/dev/null || echo "0")
echo "    Backup metric in VictoriaMetrics: $_backup_metric"
echo "    Upload metric in VictoriaMetrics: $_upload_metric"

# ── 12. Grafana ────────────────────────────────────────────────────────────────

echo ""
echo "── 12. Grafana ──"

_grafana_health=$(curl -s --max-time 5 'http://127.0.0.1:3000/api/health' 2>/dev/null || echo '{"database":"error"}')
_grafana_db=$(echo "$_grafana_health" | python3 -c "import sys,json; print(json.load(sys.stdin).get('database','error'))" 2>/dev/null || echo "error")
_grafana_ver=$(echo "$_grafana_health" | python3 -c "import sys,json; print(json.load(sys.stdin).get('version','unknown'))" 2>/dev/null || echo "unknown")

if [[ "$_grafana_db" == "ok" ]]; then
  ok "Grafana: v$_grafana_ver, DB $_grafana_db" "grafana_health"
else
  fail "Grafana unhealthy: DB=$_grafana_db" "grafana_health"
fi

if [[ "$_grafana_ver" =~ ^13\. ]]; then
  ok "Grafana version: $_grafana_ver (13.x OK)" "grafana_version"
elif [[ "$_grafana_ver" =~ ^12\. ]]; then
  ok "Grafana version: $_grafana_ver (12.x OK)" "grafana_version"
else
  warn "Grafana version: $_grafana_ver (expect 13.x)" "grafana_version"
fi

if ls /etc/grafana/provisioning/datasources/ /etc/grafana/provisioning/dashboards/ &>/dev/null; then
  ok "Grafana provisioning files present" "grafana_provisioning"
else
  fail "Grafana provisioning missing" "grafana_provisioning"
fi

# Endpoint requires auth; read admin password directly from the systemd EnvironmentFile
# (never exported to the shell — /etc/grafana/grafana.env is root:grafana 0600).
_grafana_pass=$(sudo grep -oP '(?<=GF_SECURITY_ADMIN_PASSWORD=).*' /etc/grafana/grafana.env 2>/dev/null || true)
if [[ -n "$_grafana_pass" ]]; then
  # Credentials via netrc-file (not argv — keeps the password out of `ps aux`).
  _grafana_netrc=$(mktemp) 2>/dev/null || _grafana_netrc=""
  if [[ -n "$_grafana_netrc" ]]; then
    chmod 600 "$_grafana_netrc"
    printf 'machine 127.0.0.1 login admin password %s\n' "$_grafana_pass" > "$_grafana_netrc"
    _alerts_firing=$(curl -s --netrc-file "$_grafana_netrc" 'http://127.0.0.1:3000/api/alertmanager/grafana/api/v2/alerts' 2>/dev/null | python3 -c "
import sys,json
try:
  d=json.load(sys.stdin)
  print(len(d) if isinstance(d, list) else 'error')
except Exception:
  print('error')
" 2>/dev/null || echo "error")
    rm -f "$_grafana_netrc"
  else
    _alerts_firing="error"
  fi
  echo "    Grafana alerts firing: $_alerts_firing"
else
  warn "Grafana alerts firing: could not read admin password" "grafana_alerts_auth"
fi
unset _grafana_pass

_grafana_mem=$(ps aux | grep grafana-server | grep -v grep | head -1 | awk '{printf "%.1f%% (%s MB RSS)", $4, int($6/1024)}' 2>/dev/null || echo "not found")
echo "    Grafana memory: $_grafana_mem"

# ── 13. Backups ────────────────────────────────────────────────────────────────

echo ""
echo "── 13. Backups ──"

# Cron jobs (check ubuntu user — sudo inherits root crontab)
_CRON_USER="ubuntu"
_cron_count=$(sudo -u "$_CRON_USER" crontab -l 2>/dev/null | grep -c "^[0-9]" || true)
if [[ "$_cron_count" -ge 5 ]]; then
  ok "Backup crons: $_cron_count entries" "backup_crons"
else
  warn "Backup crons: $_cron_count (expect 5+)" "backup_crons"
fi
sudo -u "$_CRON_USER" crontab -l 2>/dev/null | grep "^[0-9]" | while read -r _c; do echo "    $_c"; done

# Rclone config
if [[ -f ~/.config/rclone/rclone.conf ]]; then
  ok "Rclone config present" "rclone_config"
else
  fail "Rclone config MISSING" "rclone_config"
fi

# Backup dirs
for _d in project db redis; do
  if [[ -d "$BACKUP_DIR/$_d" ]]; then
    _fc=$(ls "$BACKUP_DIR/$_d" 2>/dev/null | wc -l)
    echo "    $_d/: $_fc files"
  else
    echo "    $_d/: MISSING"
  fi
done

# rclone_retry in scripts
_rr=$(grep -c "rclone_retry" "$SCRIPTS_DIR/common_functions.sh" 2>/dev/null || true)
if [[ "$_rr" -ge 1 ]]; then
  ok "rclone_retry in common_functions.sh ($_rr)" "rclone_retry"
else
  warn "rclone_retry not found" "rclone_retry"
fi

# ── 14. Telegram Bot ─────────────────────────────────────────────────────────

echo ""
echo "── 14. Telegram Bot ──"

# telegram-bot is a long-polling singleton: Telegram allows ONE getUpdates
# poller per token. It intentionally runs on prod only (see backup role);
# "not active" on a non-prod host is expected, not a fault.
_tg_env_prod=0
[[ "${ENV:-}" == "prod" ]] && _tg_env_prod=1

if systemctl is-active telegram-bot &>/dev/null; then
  ok "Telegram bot active" "tg_bot_active"
  # sudo: ubuntu user is not in adm/systemd-journal, plain journalctl silently omits entries
  _tg_conflict=$(sudo journalctl -u telegram-bot --no-pager 2>/dev/null | grep -ci 'Conflict: terminated by other getUpdates' || true)
  if [[ "$_tg_conflict" -eq 0 ]]; then
    ok "Telegram bot: single poller (no Conflict)" "tg_bot_conflict"
  else
    warn "Telegram bot: $_tg_conflict Conflict(s) - duplicate poller detected" "tg_bot_conflict"
  fi
  _tg_errors=$(sudo journalctl -u telegram-bot --no-pager 2>/dev/null | grep -ci 'error\|traceback\|exception' || true)
  if [[ "$_tg_errors" -eq 0 ]]; then
    ok "Telegram bot: 0 errors" "tg_bot_errors"
  else
    warn "Telegram bot: $_tg_errors error(s)" "tg_bot_errors"
  fi
else
  if [[ "$_tg_env_prod" -eq 1 ]]; then
    warn "Telegram bot not active" "tg_bot_active"
  else
    info "Telegram bot not active (expected on non-prod singleton)" "tg_bot_active"
  fi
fi

# ── 15. Security (extra) ─────────────────────────────────────────────────────

echo ""
echo "── 15. Security (extra) ──"

# systemd Restart=always
_nginx_restart=$(systemctl show nginx 2>/dev/null | grep 'Restart=always' | head -1 || echo "")
_php_restart=$(systemctl show "php${PHP_VER}-fpm" 2>/dev/null | grep 'Restart=always' | head -1 || echo "")
if [[ -n "$_nginx_restart" && -n "$_php_restart" ]]; then
  ok "systemd Restart=always: nginx + php-fpm" "systemd_restart_always"
else
  fail "systemd Restart=always missing" "systemd_restart_always"
fi

# Sysctl hardening
_syncookies=$(sysctl net.ipv4.tcp_syncookies 2>/dev/null | awk '{print $3}')
_rpfilter=$(sysctl net.ipv4.conf.all.rp_filter 2>/dev/null | awk '{print $3}')
_sourceroute=$(sysctl net.ipv4.conf.all.accept_source_route 2>/dev/null | awk '{print $3}')
if [[ "$_syncookies" == "1" && "$_rpfilter" == "1" && "$_sourceroute" == "0" ]]; then
  ok "sysctl: syncookies=$_syncookies rp_filter=$_rpfilter srcroute=$_sourceroute" "sysctl_hardening"
else
  fail "sysctl: syncookies=$_syncookies rp_filter=$_rpfilter srcroute=$_sourceroute" "sysctl_hardening"
fi

# Fail2ban bans
echo "  ── Fail2ban bans ──"
for _fj in dreamseed-botsearch dreamseed-bad-request modx-admin recidive sshd; do
  _b=$(sudo fail2ban-client status "$_fj" 2>/dev/null | grep "Total banned" | awk '{print $4}' || true)
  echo "    $_fj: $_b total banned"
done

# ── 16. Systemd Services ─────────────────────────────────────────────────────

echo ""
echo "── 16. Systemd Services ──"

_expected_services=(
  nginx "php${PHP_VER:-8.3}-fpm" mariadb redis-server fail2ban grafana-server promtail
  node_exporter mysqld_exporter nginx_exporter redis_exporter
  victoria-metrics vmagent ssh cron unattended-upgrades
)
# telegram-bot is prod-only (long-polling singleton, one getUpdates poller per
# token) — only required to be running on prod; never expected on a dev host.
if [[ "${ENV:-}" == "prod" ]]; then
  _expected_services+=( telegram-bot )
fi
_all_active=0
for _s in "${_expected_services[@]}"; do
  if systemctl is-active "$_s" &>/dev/null; then
    echo "    $P $_s"
    ((_all_active++)) || true
  else
    echo "    $F $_s (inactive)"
  fi
done
if [[ $_all_active -eq ${#_expected_services[@]} ]]; then
  ok "All ${#_expected_services[@]} systemd services active" "systemd_services"
else
  fail "$_all_active/${#_expected_services[@]} services active" "systemd_services"
fi

# ── 17. Processes ────────────────────────────────────────────────────────────

echo ""
echo "── 17. Top Processes (by memory) ──"

ps aux --sort=-%mem 2>/dev/null | head -8 | awk '{printf "  %-30s %5s %6s MB\n", $11, $4, int($6/1024)}'

# ── 18. Open Ports ─────────────────────────────────────────────────────────

echo ""
echo "── 18. Open Ports (public) ──"

_open_ports=$(ss -tlnp 2>/dev/null | grep LISTEN | awk '{print $4}' | grep -vE '^127\.|^::1' | sort -u || echo "")
if [[ -n "$_open_ports" ]]; then
  _port_nums=$(echo "$_open_ports" | grep -oP ':\K\d+' | sort -u | tr '\n' ' ')
  _public_count=$(echo "$_port_nums" | wc -w | tr -d ' ')
  echo "    Public ports: $_port_nums"
  if [[ "$_public_count" -le 3 ]]; then
    ok "Public ports ($_public_count: $_port_nums)" "public_ports"
  else
    warn "$_public_count public ports (expect ≤3: 22,80,443)" "public_ports"
  fi
else
  warn "No public ports detected" "public_ports"
fi

# ── 19. Journal Errors ─────────────────────────────────────────────────────

echo ""
echo "── 19. Journal Errors (last 1h) ──"

# sudo: ubuntu user is not in adm/systemd-journal, plain journalctl silently omits entries
_err_count=$(sudo journalctl --since "1 hour ago" -p err --no-pager 2>/dev/null | grep -v 'snapd\|ModemManager\|shutdown\|loop\|-- No entries --' | wc -l || true)
if [[ "$_err_count" -eq 0 ]]; then
  ok "0 journal errors in last hour" "journal_errors"
else
  warn "$_err_count journal error(s) in last hour" "journal_errors"
  sudo journalctl --since "1 hour ago" -p err --no-pager 2>/dev/null | grep -v 'snapd\|ModemManager\|shutdown\|loop\|-- No entries --' | head -5 | while read -r _l; do echo "    $_l"; done
fi

# ── 20. Functional ──────────────────────────────────────────────────────────

echo ""
echo "── 20. Functional Checks ──"

# Brotli (duplicate check for completeness)
_brotli2=$(curl -skI -H 'Accept-Encoding: br' --resolve "${DOMAIN}:443:127.0.0.1" --max-time 5 "https://${DOMAIN}/theme/css/style.css" 2>/dev/null | grep -ci 'content-encoding: br' || true)
if [[ "$_brotli2" -ge 1 ]]; then
  ok "Brotli compression" "functional_brotli"
fi

# sysctl functional check (already done above, just reference)
echo "    sysctl: syncookies=$_syncookies rp_filter=$_rpfilter srcroute=$_sourceroute"

# Faro RUM (nginx sub_filter)
_faro=$(curl -sk --max-time 5 $CURL_RESOLVE "https://${DOMAIN}/" 2>/dev/null | grep -c 'faro-web-sdk' || true)
if [[ "$_faro" -ge 1 ]]; then
  ok "Faro RUM (sub_filter active)" "functional_faro"
else
  warn "Faro RUM not found (sub_filter missing?)" "functional_faro"
fi

# Promtail log shipping (Loki is remote SaaS; gauge shipped bytes from Promtail's own /metrics)
if systemctl is-active promtail &>/dev/null; then
  _promtail_jobs=$(grep -c 'job_name' /etc/promtail/promtail.yml 2>/dev/null || true)
  _promtail_sent=$(curl -sf --max-time 5 "http://127.0.0.1:9080/metrics" 2>/dev/null | awk '/^promtail_sent_bytes_total/ {print $2}' || true)
  _promtail_sent=${_promtail_sent:-0}
  _promtail_sent=$(printf '%.0f' "$_promtail_sent" 2>/dev/null || echo 0)
  if [[ "$_promtail_jobs" -ge 3 && "$_promtail_sent" -gt 0 ]]; then
    ok "Promtail: ${_promtail_jobs} jobs, ${_promtail_sent} bytes sent to Loki" "functional_promtail"
  elif [[ "$_promtail_jobs" -ge 3 ]]; then
    ok "Promtail: ${_promtail_jobs} jobs, waiting for first batch (fresh/idle)" "functional_promtail"
  else
    warn "Promtail: ${_promtail_jobs} jobs configured (expected >=3)" "functional_promtail"
  fi
else
  warn "Promtail not running" "functional_promtail"
fi

# ── Summary ─────────────────────────────────────────────────────────────────

echo ""
echo "═══ AUDIT SUMMARY ═══"
if [[ $fail_count -eq 0 ]]; then
  echo "  $P All checks passed"
  export_metric "audit_deep_overall 1"
else
  echo "  $F $fail_count check(s) failed or warned"
  export_metric "audit_deep_overall 0"
fi
echo ""

exit $fail_count
