#!/bin/bash
# Test restored server services. Run from CI workflow.
# Usage: test-restored-server.sh <SERVER_IP>
set -euo pipefail

SERVER_IP="${1:?Usage: $0 <SERVER_IP>}"
ALL_OK=true

# Database
ssh ubuntu@"$SERVER_IP" "systemctl is-active mariadb" && echo "[PASS] MariaDB running" || { echo "[FAIL] MariaDB"; ALL_OK=false; }
ssh ubuntu@"$SERVER_IP" "mysql modx_db -N -e 'SELECT 1'" && echo "[PASS] DB connect" || { echo "[FAIL] DB connect"; ALL_OK=false; }
ROWS=$(ssh ubuntu@"$SERVER_IP" "mysql modx_db -N -e 'SELECT COUNT(*) FROM modx_site_content'")
echo "content_rows=$ROWS"
[ "${ROWS:-0}" -gt 0 ] && echo "[PASS] Content rows: $ROWS" || { echo "[FAIL] No content rows"; ALL_OK=false; }

# Web server
ssh ubuntu@"$SERVER_IP" "systemctl is-active nginx" && echo "[PASS] Nginx running" || { echo "[FAIL] Nginx"; ALL_OK=false; }
ssh ubuntu@"$SERVER_IP" "systemctl is-active php8.3-fpm" && echo "[PASS] PHP-FPM running" || { echo "[FAIL] PHP-FPM"; ALL_OK=false; }
curl -sk -o /dev/null -w "%{http_code}" "https://localhost/" | grep -q 200 \
  && echo "[PASS] HTTPS 200" || { echo "[FAIL] HTTPS not 200"; ALL_OK=false; }

# MODX core
ssh ubuntu@"$SERVER_IP" "test -f /var/www/html/core/config/config.inc.php" && echo "[PASS] Config exists" || { echo "[FAIL] Config missing"; ALL_OK=false; }
ssh ubuntu@"$SERVER_IP" "test -d /var/www/html/assets" && echo "[PASS] Assets exists" || { echo "[FAIL] Assets missing"; ALL_OK=false; }

# Keyword check
KEYWORDS=$(ssh ubuntu@"$SERVER_IP" "curl -sk --max-time 10 https://localhost/ 2>/dev/null | grep -coi 'Lucky Bamboo\|bonsai\|sakura\|maple\|oak\|pine\|willow\|cypress\|Dreamers\|Wheel of Life'" 2>/dev/null || echo 0)
[ "${KEYWORDS:-0}" -ge 3 ] && echo "[PASS] Site keywords ($KEYWORDS matches)" || echo "[WARN] Keywords low ($KEYWORDS)"

# Cart test (add product via miniShop2, then clean)
CART_RESULT=$(ssh ubuntu@"$SERVER_IP" '
    ID=$(mysql modx_db -N -e "SELECT id FROM modx_site_content WHERE class_key=\"msProduct\" AND published=1 AND deleted=0 LIMIT 1")
    [ -z "$ID" ] && echo "NO_PRODUCT" && exit 0
    RESP=$(curl -sk --max-time 10 -X POST -H "X-Requested-With: XMLHttpRequest" \
        -d "ms2_action=cart/add&id=$ID&count=1&options=[]" \
        "https://localhost/assets/components/minishop2/action.php" 2>/dev/null)
    echo "$RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print('OK' if d.get('success') else 'PARSE_FAIL')" 2>/dev/null || echo "PARSE_FAIL"
    curl -sk --max-time 10 -X POST -H "X-Requested-With: XMLHttpRequest" \
        -d "ms2_action=cart/clean" \
        "https://localhost/assets/components/minishop2/action.php" > /dev/null 2>&1
')
case "$CART_RESULT" in
    OK) echo "[PASS] Cart add + clean OK" ;;
    NO_PRODUCT) echo "[WARN] No products in DB" ;;
    *) echo "[FAIL] Cart: $CART_RESULT"; ALL_OK=false ;;
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
TBL_COUNT=$(ssh ubuntu@"$SERVER_IP" "mysql modx_db -N -e 'SELECT COUNT(*) FROM information_schema.tables WHERE table_schema=\"modx_db\"'" 2>/dev/null || echo 0)
[ "${TBL_COUNT:-0}" -ge 50 ] && echo "[PASS] DB tables: $TBL_COUNT" || echo "[WARN] DB tables: ${TBL_COUNT:-0} (expected 50+)"

# Monitoring — check_site timer
CS_TIMER=$(ssh ubuntu@"$SERVER_IP" "systemctl is-active check-site.timer" 2>/dev/null || echo "inactive")
[ "$CS_TIMER" = "active" ] && echo "[PASS] check_site.timer" || echo "[WARN] check_site.timer: $CS_TIMER"

$ALL_OK || exit 1
