#!/bin/bash
# Post-deploy health checks. Runs on the server.
# Called by deploy.sh via SSH, or manually for debugging.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common_functions.sh"
load_env "$SCRIPT_DIR/.env"

DOMAIN="${DOMAIN:-}"
DB_NAME="${DB_NAME:-modx_db}"

# Auto-detect web server
if systemctl is-active nginx &>/dev/null; then
    WEB_SVC="nginx"
elif systemctl is-active apache2 &>/dev/null; then
    WEB_SVC="apache2"
else
    echo "  ✗ No web server running"
    WEB_SVC=""
fi

# Auto-detect PHP version
PHP_VER=""
for v in /etc/php/*/fpm/pool.d/www.conf; do
    [[ -f "$v" ]] && PHP_VER=$(echo "$v" | sed 's|/etc/php/||; s|/fpm/pool.d/www.conf||')
done
[[ -z "$PHP_VER" ]] && PHP_VER="8.3"

fail=0

# --- Services ---
for s in "${WEB_SVC}" "php${PHP_VER}-fpm" "mariadb" "mysqld_exporter" "victoria-metrics" "grafana-server" "telegram-bot"; do
    st=$(systemctl is-active "$s" 2>/dev/null || echo "inactive")
    if [[ "$st" == "active" ]]; then
        echo "  ✓ $s"
        export_metric "service_status{service=\"$s\"} 1"
    else
        echo "  ✗ $s — $st"
        export_metric "service_status{service=\"$s\"} 0"
        fail=1
    fi
done

# --- Site HTTP ---
if [[ -n "$DOMAIN" ]]; then
    http=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 "https://$DOMAIN/" 2>/dev/null || echo "000")
    if [[ "$http" == "200" || "$http" == "301" ]]; then
        echo "  ✓ HTTP $http $DOMAIN"
        export_metric "site_http_status{domain=\"$DOMAIN\",code=\"$http\"} 1"
    else
        echo "  ✗ HTTP $http $DOMAIN — site not serving"
        export_metric "site_http_status{domain=\"$DOMAIN\",code=\"$http\"} 0"
        fail=1
    fi
fi

# --- SSL ---
if curl -sfk --max-time 5 "https://$DOMAIN/" > /dev/null 2>&1; then
    echo "  ✓ SSL: Cloudflare (edge)"
    export_metric "ssl_certificate_valid{provider=\"cloudflare\"} 1"
elif certbot certificates 2>/dev/null | grep -q "^  Certificate Name:"; then
    echo "  ✓ SSL: letsencrypt"
    export_metric "ssl_certificate_valid{provider=\"letsencrypt\"} 1"
elif openssl x509 -in /etc/ssl/certs/ssl-cert-snakeoil.pem -noout 2>/dev/null; then
    echo "  ⚠ SSL: self-signed (dev)"
    export_metric "ssl_certificate_valid{provider=\"self-signed\"} 1"
else
    echo "  ✗ SSL: no certificate"
    export_metric "ssl_certificate_valid{provider=\"none\"} 0"
    fail=1
fi

# --- MODX ---
if [[ -f /var/www/html/index.php ]]; then echo "  ✓ MODX: index.php"
else echo "  ✗ MODX: index.php missing"; fail=1; fi

# --- Database ---
if [[ ! "$DB_NAME" =~ ^[A-Za-z0-9_]+$ ]]; then
    echo "  ✗ DB: invalid name format"
    export_metric "database_tables{database=\"$DB_NAME\"} 0"
    fail=1
    tables=0
else
    tables=$(mysql --defaults-group-suffix=monitoring -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$DB_NAME';" 2>/dev/null || echo "0")
    export_metric "database_tables{database=\"$DB_NAME\"} $tables"
fi
if [[ "$tables" -ge 50 ]]; then echo "  ✓ DB: $tables tables"
elif [[ "$tables" -ge 1 ]]; then echo "  ⚠ DB: only $tables tables"
else echo "  ✗ DB: no tables"; fail=1; fi

# --- VictoriaMetrics (retry 10 times × 2s — may still be starting) ---
_vm_ok=0
for i in $(seq 1 10); do
    vm=$(curl -sf --max-time 3 "http://127.0.0.1:8428/health" 2>/dev/null || echo "")
    if [[ "$vm" == "OK" ]]; then
        _vm_ok=1
        break
    fi
    sleep 2
done
if [[ $_vm_ok -eq 1 ]]; then
    echo "  ✓ VictoriaMetrics"
    export_metric "victoria_metrics_up 1"
else
    echo "  ✗ VictoriaMetrics (not ready after ~20s)"
    export_metric "victoria_metrics_up 0"
    fail=1
fi

# --- Exporters (retry 5 times × 2s — port may still be binding) ---
_check_ep() {
    local p=$1 k=$2 n=$3
    local raw
    for i in $(seq 1 5); do
        raw=$(curl -sf --max-time 3 "http://127.0.0.1:$p/metrics" 2>/dev/null) || { sleep 2; continue; }
        if grep -q "$k" <<< "$raw" 2>/dev/null; then
            echo "  ✓ $n"; return 0
        fi
        sleep 2
    done
    echo "  ✗ $n"; return 1
}

_check_ep 9100 node_ node_exporter || fail=1
_check_ep 9104 mysql_ mysqld_exporter || fail=1
if [[ "$WEB_SVC" == "nginx" ]]; then
    _check_ep 9113 nginx_ nginx_exporter || fail=1
fi
if [[ "$WEB_SVC" == "apache2" ]]; then
    _check_ep 9117 apache_ apache_exporter || fail=1
fi
if systemctl is-active vmagent &>/dev/null; then
    _check_ep 8429 vmagent_ vmagent || echo "  ⚠ vmagent running but no metrics"
fi

# --- Backup cron ---
if crontab -u ubuntu -l 2>/dev/null | grep -q smart_backup; then
  echo "  ✓ cron: backup"
  export_metric "cron_last_run_backup{instance=\"$DOMAIN\"} $(date +%s)"
else echo "  ✗ cron: backup not set"; fail=1; fi

# --- fail2ban ---
jails=$(sudo fail2ban-client status 2>/dev/null | grep "Jail list" | sed 's/.*:  *//' || echo "")
if echo "$jails" | grep -q "sshd"; then echo "  ✓ fail2ban: $jails"
else echo "  ⚠ fail2ban: no jails ($jails)"; fi

# --- Heartbeat: export last-run timestamp so we can alert if this script stops running ---
export_metric "check_services_last_run{instance=\"$DOMAIN\"} $(date +%s)"

# --- Export overall health status ---
if [[ $fail -eq 0 ]]; then
    export_metric "dreamseed_health_overall 1"
else
    export_metric "dreamseed_health_overall 0"
fi

exit $fail
