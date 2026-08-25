#!/bin/bash
# Post-deploy health checks. Runs on the server.
# Called by deploy.sh via SSH, or manually for debugging.
# Uses flock to prevent concurrent runs (deploy.sh + systemd timer).
set -euo pipefail

LOCK_DIR="${HOME:-/root}/.locks"
mkdir -p "$LOCK_DIR"
LOCK_FILE="$LOCK_DIR/check_services.lock"
exec 200>"$LOCK_FILE"
flock -n 200 || {
    echo "check_services already running, skipping"
    exit 0
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common_functions.sh"

# Skip while a deploy is provisioning (marker written by playbook-01) so the
# 5-min timer doesn't false-alert on half-configured services. A stale marker
# (>30 min, e.g. left behind by a failed deploy) is ignored — checks resume.
# The heartbeat is still pushed so the "Not Running" alert doesn't false-fire
# during a >10-min deploy (checks are intentionally paused, not broken).
if [ -f /tmp/.dreamseed_deploying ]; then
    _deploy_marker_mtime=$(stat -c %Y /tmp/.dreamseed_deploying 2>/dev/null || echo 0)
    if [ $(($(date +%s) - _deploy_marker_mtime)) -lt 1800 ]; then
        # Fresh server, early deploy: playbook-06 hasn't rendered .env yet.
        # The skip path only needs the DOMAIN label — don't hard-fail on .env.
        DOMAIN=""
        if [ -f "$SCRIPT_DIR/.env" ]; then
            DOMAIN="$(grep -E '^DOMAIN=' "$SCRIPT_DIR/.env" 2>/dev/null | head -1 | cut -d= -f2- | tr -d "\"'")"
        fi
        export_metric "check_services_last_run{instance=\"$DOMAIN\"} $(date +%s)"
        echo "Deploy in progress — skipping health check"
        exit 0
    fi
fi

# Normal run needs the full .env (DB creds, tokens, etc.) — fail loudly if it's
# missing, never run half-configured.
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
# grafana-server is intentionally ABSENT from this loop: it installs LAST as a
# fallback (see check #2) and must never gate the deploy or the heartbeat.
for s in "${WEB_SVC}" "php${PHP_VER}-fpm" "mariadb" "redis-server" "node_exporter" "mysqld_exporter" "nginx_exporter" "redis_exporter" "victoria-metrics"; do
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

# --- telegram-bot (long-polling singleton) ---
# Telegram allows ONE getUpdates poller per token, so the bot runs on prod only.
# On prod it must be active; on any non-prod host it must be inactive (a running
# poller there would kill the prod instance via Conflict).
_tbg=$(systemctl is-active telegram-bot 2>/dev/null || echo "inactive")
if [[ "${ENV:-}" == "prod" ]]; then
    if [[ "$_tbg" == "active" ]]; then
        echo "  ✓ telegram-bot"
        export_metric 'service_status{service="telegram-bot"} 1'
    else
        echo "  ✗ telegram-bot — $_tbg"
        export_metric 'service_status{service="telegram-bot"} 0'
        fail=1
    fi
else
    if [[ "$_tbg" == "active" ]]; then
        echo "  ⚠ telegram-bot active on non-prod (duplicate poller risk) — $ENV"
        export_metric 'service_status{service="telegram-bot"} 0'
    else
        echo "  ✓ telegram-bot (expected inactive on non-prod)"
        export_metric 'service_status{service="telegram-bot"} 1'
    fi
fi

# --- Promtail (optional) ---
if command -v promtail &>/dev/null; then
    if systemctl is-active promtail &>/dev/null; then
        echo "  ✓ promtail"
        export_metric 'promtail_up 1'
    else
        echo "  ✗ promtail (inactive)"
        export_metric 'promtail_up 0'
        fail=1
    fi
fi

# --- Site HTTP (via localhost with SNI — bypasses Cloudflare, no DNS dependency) ---
page=$(curl -sk --max-time 10 --resolve "${DOMAIN}:443:127.0.0.1" -w '\n%{http_code}' "https://${DOMAIN}/" 2>/dev/null || echo "000")
http="${page##*$'\n'}"
body="${page%$'\n'*}"
if [[ "$http" == "200" || "$http" == "301" ]]; then
    if [[ "$http" == "200" ]] && { [[ -z "$body" ]] || [[ "$body" != *"<html"* ]]; }; then
        # 200 but not an HTML page (empty body, error string, maintenance stub)
        echo "  ✗ HTTP $http ${DOMAIN:-localhost} — 200 but not HTML (${#body} bytes)"
        export_metric "site_http_status{domain=\"${DOMAIN:-localhost}\",code=\"$http\"} 0"
        fail=1
    else
        echo "  ✓ HTTP $http ${DOMAIN:-localhost}"
        export_metric "site_http_status{domain=\"${DOMAIN:-localhost}\",code=\"$http\"} 1"
    fi
elif [[ "$http" == "520" ]]; then
    echo "  ⚠ HTTP $http ${DOMAIN:-localhost} — Cloudflare upstream sync (non-fatal)"
    export_metric "site_http_status{domain=\"${DOMAIN:-localhost}\",code=\"$http\"} 0"
else
    echo "  ✗ HTTP $http ${DOMAIN:-localhost} — site not serving"
    export_metric "site_http_status{domain=\"${DOMAIN:-localhost}\",code=\"$http\"} 0"
    fail=1
fi

# --- SSL ---
if curl -sfk --max-time 5 "https://$DOMAIN/" >/dev/null 2>&1; then
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
if [[ -f /var/www/html/index.php ]]; then
    echo "  ✓ MODX: index.php"
else
    echo "  ✗ MODX: index.php missing"
    fail=1
fi

# --- Database ---
if [[ ! "$DB_NAME" =~ ^[A-Za-z0-9_]+$ ]]; then
    echo "  ✗ DB: invalid name format"
    export_metric "database_tables{database=\"$DB_NAME\"} 0"
    fail=1
    tables=0
else
    tables=$(mysql -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${DB_NAME//\'/''}';" 2>/dev/null || echo "0")
    export_metric "database_tables{database=\"$DB_NAME\"} $tables"
fi
if [[ "$tables" -ge 50 ]]; then
    echo "  ✓ DB: $tables tables"
elif [[ "$tables" -ge 1 ]]; then
    echo "  ⚠ DB: only $tables tables"
else
    echo "  ✗ DB: no tables"
    fail=1
fi

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
        raw=$(curl -sf --max-time 3 "http://127.0.0.1:$p/metrics" 2>/dev/null) || {
            sleep 2
            continue
        }
        if grep -q "$k" <<<"$raw" 2>/dev/null; then
            echo "  ✓ $n"
            return 0
        fi
        sleep 2
    done
    echo "  ✗ $n"
    return 1
}

_check_ep 9100 node_ node_exporter || fail=1
_check_ep 9104 mysql_ mysqld_exporter || fail=1
if [[ "$WEB_SVC" == "nginx" ]]; then
    _check_ep 9113 nginx_ nginx_exporter || fail=1
fi
if [[ "$WEB_SVC" == "apache2" ]]; then
    _check_ep 9117 apache_ apache_exporter || fail=1
fi
_check_ep 9121 redis_ redis_exporter || fail=1
# --- Backup crons ---
if crontab -u ubuntu -l 2>/dev/null | grep -q smart_backup; then
    echo "  ✓ cron: backup"
    # NOT pushed — cron-backup alert must track smart_backup.sh runs, not this.
else
    echo "  ✗ cron: backup not set"
    fail=1
fi
if crontab -u ubuntu -l 2>/dev/null | grep -q upload_backups_to_gdrive; then
    echo "  ✓ cron: upload"
else
    echo "  ✗ cron: upload not set"
    fail=1
fi

# --- fail2ban ---
_f2b_active=$(systemctl is-active fail2ban 2>/dev/null || echo "inactive")
if [[ "$_f2b_active" != "active" ]]; then
    echo "  ✗ fail2ban: service $_f2b_active"
    export_metric "fail2ban_up 0"
    fail=1
else
    _f2b_jails=$(sudo fail2ban-client status 2>/dev/null | grep "Jail list" | sed 's/.*:[[:space:]]*//' || echo "")
    _f2b_missing=0
    for _j in sshd modx-admin dreamseed-botsearch dreamseed-bad-request recidive; do
        if echo "$_f2b_jails" | grep -q "$_j"; then
            :
        else
            _f2b_missing=1
        fi
    done
    if [[ "$_f2b_missing" -eq 0 ]]; then
        echo "  ✓ fail2ban: active ($_f2b_jails)"
        export_metric "fail2ban_up 1"
    else
        echo "  ⚠ fail2ban: active but missing jails"
        export_metric "fail2ban_up 0"
    fi
    # Edge-ban config (cloudflare-token action) — if absent, web jails are log-only
    if sudo grep -q 'cloudflare-token' /etc/fail2ban/jail.d/custom.conf 2>/dev/null; then
        echo "  ✓ fail2ban: edge-ban active (cloudflare-token)"
    else
        echo "  ⚠ fail2ban: web jails log-only (cloudflare-token not configured)"
        export_metric "fail2ban_up 0"
    fi
    # Jail file holds the CF firewall token — must be 0640, never world-readable
    _f2b_mode=$(stat -c %a /etc/fail2ban/jail.d/custom.conf 2>/dev/null || echo "?")
    if [[ "$_f2b_mode" == "640" ]]; then
        echo "  ✓ fail2ban jail.d mode 640"
    else
        echo "  ⚠ fail2ban jail.d/custom.conf mode $_f2b_mode (expect 640)"
        export_metric "fail2ban_up 0"
    fi
fi

# --- Systemd timers ---
for _t in check-site.timer check-services.timer; do
    if systemctl is-active "$_t" &>/dev/null; then
        echo "  ✓ $_t"
    else
        echo "  ✗ $_t (inactive)"
        fail=1
    fi
done

# --- vmagent (Grafana Cloud metrics agent) ---
if systemctl is-active vmagent &>/dev/null; then
    _raw=$(curl -sf --max-time 5 "http://127.0.0.1:8429/metrics" 2>/dev/null || echo "")
    _blocks=$(echo "$_raw" | awk '/^vmagent_remotewrite_blocks_sent_total/ {print $2}')
    _blocks=${_blocks:-0}
    _errors=$(echo "$_raw" | awk '/^vmagent_remotewrite_errors_total/ {print $2}')
    _errors=${_errors:-0}

    _errfile="/var/tmp/.vmagent_errors_last"
    # Baseline for the errors delta. Robust to: file lost (first run / tmp cleaner)
    # -> no delta; unreadable file -> no set -e abort; vmagent counter reset
    # (errors < prev) -> no delta.
    _had_file=false
    [[ -r "$_errfile" ]] && _had_file=true
    _prev=$(cat "$_errfile" 2>/dev/null || echo 0)
    if [[ "$_had_file" != true || "$_errors" -lt "$_prev" ]]; then
        _new=0
    else
        _new=$((_errors - _prev))
    fi
    echo "$_errors" >"$_errfile" 2>/dev/null || true

    if [[ "$_blocks" -gt 0 && "$_new" -eq 0 ]]; then
        export_metric 'vmagent_remote_write_ok 1'
        echo "  ✓ vmagent: remote write OK"
    elif [[ "$_blocks" -gt 0 && "$_new" -gt 0 ]]; then
        export_metric 'vmagent_remote_write_ok 0'
        echo "  ⚠ vmagent: +$_new errors (total $_errors)"
    else
        # no blocks yet (fresh start) — not an error, avoid false critical.
        export_metric 'vmagent_remote_write_ok 1'
        echo "  ✓ vmagent: running, no blocks yet (normal right after start)"
    fi
else
    export_metric 'vmagent_remote_write_ok 0'
    echo "  ✗ vmagent: not running"
    fail=1
fi

# --- TIER 1 CRITICAL CHECKS ---
# LOCAL services (FAIL deploy if broken)
# EXTERNAL services (WARN if broken — cloud issues shouldn't block deploy)

_local_fail=0
_external_warn=0

# 1. Redis connectivity (LOCAL — CRITICAL for sessions)
if redis-cli ping >/dev/null 2>&1; then
    echo "  ✓ Redis: ping OK"
else
    echo "  ✗ Redis: not responding (sessions will be lost)"
    _local_fail=1
fi

# 2. Grafana /api/health (LOCAL — WARN: grafana is a fallback, deploy must not fail)
# Grafana installs LAST as a fallback; if it's absent/broken the deploy still
# succeeds. /api/health is public (used by LB probes) — no auth, no password in argv.
# Warn-only: a broken Grafana must NOT suppress the Better Stack heartbeat below,
# otherwise a healthy site pages as "down". service_status metric still flips to
# 0 so dashboard alerting keeps visibility without paging.
if curl -sf --max-time 5 "http://127.0.0.1:3000/api/health" 2>/dev/null | grep -q '"database": "ok"'; then
    echo "  ✓ Grafana: healthy"
    export_metric 'service_status{service="grafana-server"} 1'
else
    echo "  ⚠ Grafana: not healthy (fallback — non-fatal)"
    export_metric 'service_status{service="grafana-server"} 0'
fi

# 3. Promtail → Loki connectivity (EXTERNAL — check via Promtail metrics)
# Loki is Grafana Cloud SaaS, not local. Check if Promtail has sent data to cloud.
_prom_metrics=$(curl -sf --max-time 5 "http://127.0.0.1:9080/metrics" 2>/dev/null || echo "")
_prom_sent=$(echo "$_prom_metrics" | awk '/^promtail_sent_bytes_total/ {print $2}' || echo "0")
_prom_sent=$(printf "%.0f" "$_prom_sent" 2>/dev/null || echo "0")
if [[ "${_prom_sent:-0}" -gt 0 ]]; then
    echo "  ✓ Promtail → Loki: ${_prom_sent} bytes sent"
else
    echo "  ⚠ Promtail → Loki: no data sent yet (may be normal on fresh deploy)"
    _external_warn=1
fi

# 4. Telegram API connectivity (EXTERNAL — warn if broken)
if [[ -n "${TG_TOKEN:-}" ]]; then
    _tg_cfg=$(mktemp) || {
        echo "  ⚠ Telegram: mktemp failed"
        _external_warn=1
        _tg_cfg=""
    }
    if [[ -n "$_tg_cfg" ]]; then
        chmod 600 "$_tg_cfg"
        printf 'url = "https://api.telegram.org/bot%s/getMe"\n' "$TG_TOKEN" >"$_tg_cfg"
        if curl -sf --max-time 5 --config "$_tg_cfg" 2>/dev/null | grep -q '"ok":true'; then
            echo "  ✓ Telegram: API OK"
        else
            echo "  ⚠ Telegram: API unreachable (alerts won't send)"
            _external_warn=1
        fi
        rm -f "$_tg_cfg"
    fi
else
    echo "  ⊘ Telegram: TG_TOKEN not configured (alerts disabled)"
fi

# --- Heartbeat ---
export_metric "check_services_last_run{instance=\"$DOMAIN\"} $(date +%s)"

# --- Export overall health status ---
if [[ $fail -eq 0 && $_local_fail -eq 0 ]]; then
    export_metric "dreamseed_health_overall 1"
else
    export_metric "dreamseed_health_overall 0"
fi

# --- Ping external heartbeat ONLY when all checks passed (same condition as
#     dreamseed_health_overall): silence = alert in Better Stack.
#     Mirrors smart_backup / verify_backups / upload_backups_to_gdrive. ---
if [[ $fail -eq 0 && $_local_fail -eq 0 ]]; then
    ping_heartbeat "${BETTERUPTIME_CHECK_SERVICES_KEY:-}" || true
fi

# --- Exit status ---
if [[ $_local_fail -eq 1 ]]; then
    echo ""
    echo "❌ CRITICAL: Local services failed — deploy cannot proceed"
    exit 1
else
    # TIER 1 checks passed. Old checks may have warnings, but don't block deploy.
    echo ""
    if [[ $fail -eq 0 ]]; then
        echo "✅ All checks passed"
    elif [[ $_local_fail -eq 0 ]]; then
        echo "✅ Critical checks passed (warnings above)"
    fi
    if [[ $_external_warn -eq 1 ]]; then
        echo "⚠️  WARNING: External services unreachable (non-fatal)"
        echo "   Deploy succeeded but verify cloud connectivity"
    fi
    exit 0
fi
