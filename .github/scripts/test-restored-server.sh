#!/bin/bash
# Test restored server services. Run from CI workflow.
# Usage: test-restored-server.sh <SERVER_IP>
set -euo pipefail

SERVER_IP="${1:?Usage: $0 <SERVER_IP>}"
DB_NAME="${DB_NAME:-modx_db}"

{
# ====== Checks start ======

# Database
ssh ubuntu@"$SERVER_IP" "systemctl is-active mariadb" && echo "[PASS] MariaDB running" || echo "[FAIL] MariaDB"
ssh ubuntu@"$SERVER_IP" "mysql \"$DB_NAME\" -N -e 'SELECT 1'" && echo "[PASS] DB connect" || echo "[FAIL] DB connect"
ROWS=$(ssh ubuntu@"$SERVER_IP" "mysql \"$DB_NAME\" -N -e 'SELECT COUNT(*) FROM modx_site_content'" 2>/dev/null || echo 0)
echo "content_rows=$ROWS"
[ "${ROWS:-0}" -gt 0 ] && echo "[PASS] Content rows: $ROWS" || echo "[FAIL] No content rows"

# Web server
ssh ubuntu@"$SERVER_IP" "systemctl is-active nginx" && echo "[PASS] Nginx running" || echo "[FAIL] Nginx"
ssh ubuntu@"$SERVER_IP" "systemctl is-active php8.3-fpm" && echo "[PASS] PHP-FPM running" || echo "[FAIL] PHP-FPM"
ssh ubuntu@"$SERVER_IP" "curl -sk -o /dev/null -w '%{http_code}' https://localhost/" | grep -q 200 \
  && echo "[PASS] HTTPS 200" || echo "[FAIL] HTTPS not 200"

# MODX core
ssh ubuntu@"$SERVER_IP" "test -f /var/www/html/core/config/config.inc.php" && echo "[PASS] Config exists" || echo "[FAIL] Config missing"
ssh ubuntu@"$SERVER_IP" "test -d /var/www/html/assets" && echo "[PASS] Assets exists" || echo "[FAIL] Assets missing"

# Keyword check
KEYWORDS=$(ssh ubuntu@"$SERVER_IP" "curl -sk --max-time 10 https://localhost/ 2>/dev/null | grep -coi 'Lucky Bamboo\|bonsai\|sakura\|maple\|oak\|pine\|willow\|cypress\|Dreamers\|Wheel of Life'" 2>/dev/null || echo 0)
[ "${KEYWORDS:-0}" -ge 3 ] && echo "[PASS] Site keywords ($KEYWORDS matches)" || echo "[WARN] Keywords low ($KEYWORDS)"

# Cart test (add product via miniShop2, then clean)
CART_RESULT=$(ssh ubuntu@"$SERVER_IP" '
    DB_NAME="'"$DB_NAME"'"
    ID=$(mysql "$DB_NAME" -N -e "SELECT id FROM modx_site_content WHERE class_key=\"msProduct\" AND published=1 AND deleted=0 LIMIT 1")
    [ -z "$ID" ] && echo "NO_PRODUCT" && exit 0
    RESP=$(curl -sk --max-time 10 -X POST -H "X-Requested-With: XMLHttpRequest" \
        -d "ms2_action=cart/add&id=$ID&count=1&options=[]" \
        "https://localhost/assets/components/minishop2/action.php" 2>/dev/null)
    case "$RESP" in
      *success*true*) echo "OK" ;;
      *) echo "$RESP" ;;
    esac
    curl -sk --max-time 10 -X POST -H "X-Requested-With: XMLHttpRequest" \
        -d "ms2_action=cart/clean" \
        "https://localhost/assets/components/minishop2/action.php" > /dev/null 2>&1
')
case "$CART_RESULT" in
    OK) echo "[PASS] Cart add + clean OK" ;;
    NO_PRODUCT) echo "[WARN] No products in DB" ;;
    *) echo "[FAIL] Cart: $CART_RESULT" ;;
esac

# SMTP
SMTP_RESULT=$(ssh ubuntu@"$SERVER_IP" "timeout 10 bash -c 'echo | openssl s_client -starttls smtp -connect mail.privateemail.com:587 2>/dev/null | grep -q \"Verification: OK\" && echo OK || echo FAIL'" 2>/dev/null || echo "FAIL")
[ "$SMTP_RESULT" = "OK" ] && echo "[PASS] SMTP TLS OK" || echo "[WARN] SMTP failed"

# Monitoring — VictoriaMetrics health
VM_HEALTH=$(ssh ubuntu@"$SERVER_IP" "curl -sf http://127.0.0.1:8428/health 2>/dev/null && echo OK || echo FAIL")
[ "$VM_HEALTH" = "OK" ] && echo "[PASS] VictoriaMetrics health" || echo "[WARN] VM health: $VM_HEALTH"

# Monitoring — node_exporter metrics
NE_CHECK=$(ssh ubuntu@"$SERVER_IP" "curl -sf http://127.0.0.1:9100/metrics 2>/dev/null | grep -q 'node_cpu' && echo OK || echo FAIL")
[ "$NE_CHECK" = "OK" ] && echo "[PASS] Node Exporter metrics" || echo "[WARN] Node Exporter: $NE_CHECK"

# Security — fail2ban running
F2B_STATUS=$(ssh ubuntu@"$SERVER_IP" "systemctl is-active fail2ban" 2>/dev/null || echo "inactive")
[ "$F2B_STATUS" = "active" ] && echo "[PASS] fail2ban running" || echo "[WARN] fail2ban: $F2B_STATUS"

# Security — SSH hardening in place
SSH_HARDENING=$(ssh ubuntu@"$SERVER_IP" "grep -q 'MaxAuthTries 3' /etc/ssh/sshd_config.d/99-hardening.conf 2>/dev/null && echo OK || echo FAIL")
[ "$SSH_HARDENING" = "OK" ] && echo "[PASS] SSH hardening" || echo "[WARN] SSH hardening: $SSH_HARDENING"

# Database — table count
TBL_COUNT=$(ssh ubuntu@"$SERVER_IP" "mysql \"$DB_NAME\" -N -e 'SELECT COUNT(*) FROM information_schema.tables WHERE table_schema=\"$DB_NAME\"'" 2>/dev/null || echo 0)
[ "${TBL_COUNT:-0}" -ge 50 ] && echo "[PASS] DB tables: $TBL_COUNT" || echo "[WARN] DB tables: ${TBL_COUNT:-0} (expected 50+)"

# Monitoring — check_site timer (every minute)
CS_TIMER=$(ssh ubuntu@"$SERVER_IP" "systemctl is-active check-site.timer" 2>/dev/null || echo "inactive")
[ "$CS_TIMER" = "active" ] && echo "[PASS] check_site.timer" || echo "[FAIL] check_site.timer: $CS_TIMER"

# Monitoring — check_services timer (every 5 min, updated database_tables & dreamseed_health_overall)
CSRV_TIMER=$(ssh ubuntu@"$SERVER_IP" "systemctl is-active check-services.timer" 2>/dev/null || echo "inactive")
[ "$CSRV_TIMER" = "active" ] && echo "[PASS] check-services.timer" || echo "[FAIL] check-services.timer: $CSRV_TIMER"

# Monitoring — Grafana
ssh ubuntu@"$SERVER_IP" "systemctl is-active grafana-server" 2>/dev/null \
  && echo "[PASS] Grafana running" || echo "[WARN] Grafana not running"

# Monitoring — vmagent
VMAGENT=$(ssh ubuntu@"$SERVER_IP" "systemctl is-active vmagent" 2>/dev/null || echo "inactive")
[ "$VMAGENT" = "active" ] && echo "[PASS] vmagent running" || echo "[WARN] vmagent: $VMAGENT"

# Monitoring — mysqld_exporter
ssh ubuntu@"$SERVER_IP" "systemctl is-active mysqld_exporter" 2>/dev/null \
  && echo "[PASS] MySQLd Exporter running" || echo "[WARN] MySQLd Exporter not running"

# Monitoring — vmagent remote write errors (0 = data reaching Grafana Cloud)
VMA_ERRS=$(ssh ubuntu@"$SERVER_IP" "curl -sf http://127.0.0.1:8429/metrics 2>/dev/null | grep 'vmagent_remotewrite_errors_total' | grep -o '[0-9]*$'" 2>/dev/null || echo "NO_DATA")
[ "$VMA_ERRS" = "0" ] && echo "[PASS] vmagent remote write: 0 errors" || echo "[FAIL] vmagent remote write errors: $VMA_ERRS"

# Monitoring — nginx_exporter (or apache_exporter for Apache)
NE2=$(ssh ubuntu@"$SERVER_IP" "systemctl is-active nginx-prometheus-exporter 2>/dev/null || systemctl is-active apache_exporter 2>/dev/null || echo inactive")
[ "$NE2" = "active" ] && echo "[PASS] Web exporter running" || echo "[WARN] Web exporter: $NE2"

# Backup — cron job installed
CRON_OK=$(ssh ubuntu@"$SERVER_IP" "crontab -l 2>/dev/null | grep -q smart_backup && echo OK || echo MISSING" 2>/dev/null || echo "MISSING")
[ "$CRON_OK" = "OK" ] && echo "[PASS] Backup cron installed" || echo "[WARN] Backup cron: $CRON_OK"

# Backup — cloud sync reachable (GDrive has backups for restore)
GDRIVE_OK=$(ssh ubuntu@"$SERVER_IP" "rclone lsf gdrive:DreamSeed/backups/project/ --max-depth 1 2>/dev/null | sort -r | head -1 || echo NO_BACKUPS")
[ "$GDRIVE_OK" != "NO_BACKUPS" ] && echo "[PASS] GDrive backups: $(echo $GDRIVE_OK | tr -d '\n')" || echo "[FAIL] GDrive backups: not found — disaster recovery broken"

# Backup — telegram-bot service
ssh ubuntu@"$SERVER_IP" "systemctl is-active telegram-bot" 2>/dev/null \
  && echo "[PASS] Telegram bot running" || echo "[WARN] Telegram bot not running"

# Security — fail2ban custom jails (use sudo — ubuntu needs root)
F2B_ADMIN=$(ssh ubuntu@"$SERVER_IP" "sudo fail2ban-client status modx-admin 2>/dev/null | grep -q 'Total banned' && echo OK || echo MISSING" 2>/dev/null || echo "MISSING")
[ "$F2B_ADMIN" = "OK" ] && echo "[PASS] fail2ban modx-admin jail" || echo "[FAIL] fail2ban modx-admin: $F2B_ADMIN"
F2B_GRAFANA=$(ssh ubuntu@"$SERVER_IP" "sudo fail2ban-client status grafana 2>/dev/null | grep -q 'Total banned' && echo OK || echo MISSING" 2>/dev/null || echo "MISSING")
[ "$F2B_GRAFANA" = "OK" ] && echo "[PASS] fail2ban grafana jail" || echo "[FAIL] fail2ban grafana: $F2B_GRAFANA"

# Monitoring — Grafana admin password set (flag file created by grafana role)
GRAFANA_FLAG=$(ssh ubuntu@"$SERVER_IP" "test -f /etc/grafana/.admin_password_set && echo OK || echo MISSING" 2>/dev/null || echo "MISSING")
[ "$GRAFANA_FLAG" = "OK" ] && echo "[PASS] Grafana admin password set" || echo "[WARN] Grafana password: $GRAFANA_FLAG"

# ====== Checks end ======
} 2>&1
P=0 F=0 W=0
FAIL_ITEMS=""
while IFS= read -r line; do
  echo "$line"
  case "$line" in
    *'[PASS]'*) ((P++));;
    *'[FAIL]'*)
      ((F++))
      item="${line#*[FAIL] }"
      item="${item%% *}"
      [ -n "$FAIL_ITEMS" ] && FAIL_ITEMS="$FAIL_ITEMS, " || true
      FAIL_ITEMS="${FAIL_ITEMS}${item}"
      ;;
    *'[WARN]'*) ((W++));;
  esac
done
echo "test_summary=P:${P} F:${F} W:${W}"
echo "test_fails=${FAIL_ITEMS:-none}"
[ "$F" -eq 0 ]
