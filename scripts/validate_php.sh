#!/usr/bin/env bash
# Read-only PHP-FPM validation for DreamSeed.
# Creates one temporary PHP file in the webroot, queries it through FPM,
# then removes it. It does not change any PHP/nginx settings.
#
# Usage:
#   DOMAIN=dreamseed.online bash scripts/validate_php.sh
#   DOMAIN=hetz.vitalikuts.online bash scripts/validate_php.sh
#
# Optional env: WEB_ROOT, PHP_VERSION.

set -euo pipefail

DOMAIN="${DOMAIN:-dreamseed.online}"
WEB_ROOT="${WEB_ROOT:-/var/www/html}"
PHP_VERSION="${PHP_VERSION:-$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')}"
FPM_DIR="/etc/php/${PHP_VERSION}/fpm"
VHOST="/etc/nginx/sites-available/${DOMAIN}-ssl.conf"
SLOWLOG="/var/log/php${PHP_VERSION}-fpm-slow.log"

tmp_php="$(mktemp --suffix=.php "${WEB_ROOT}/_fpm_check_XXXXXX")"
json="$(mktemp /tmp/fpm-check-XXXXXX.json)"
cleanup() {
    sudo rm -f "$tmp_php"
    rm -f "$json"
}
trap cleanup EXIT

sudo tee "$tmp_php" >/dev/null <<'PHP'
<?php
$o = [];
foreach ([
    'max_input_vars', 'memory_limit', 'post_max_size', 'upload_max_filesize',
    'max_execution_time', 'max_input_time', 'session.cookie_secure',
    'session.cookie_httponly', 'session.cookie_samesite', 'session.use_strict_mode',
    'opcache.enable', 'opcache.memory_consumption', 'opcache.max_accelerated_files',
    'opcache.validate_timestamps', 'realpath_cache_size', 'realpath_cache_ttl'
] as $k) {
    $o[$k] = ini_get($k);
}
$o['exec'] = function_exists('exec') ? 'yes' : 'no';
$o['shell_exec'] = function_exists('shell_exec') ? 'yes' : 'no';
if (function_exists('opcache_get_status')) {
    $s = @opcache_get_status(false);
    if ($s) {
        $o['opcache_used_mb'] = round($s['memory_usage']['used_memory'] / 1048576, 1);
        $o['opcache_free_mb'] = round($s['memory_usage']['free_memory'] / 1048576, 1);
        $o['opcache_wasted_mb'] = round($s['memory_usage']['wasted_memory'] / 1048576, 1);
        $o['opcache_cached_scripts'] = $s['opcache_statistics']['num_cached_scripts'];
        $o['opcache_hit_rate'] = round($s['opcache_statistics']['opcache_hit_rate'], 1);
    }
}
if (function_exists('session_start')) {
    @session_start();
    $p = session_get_cookie_params();
    $o['cookie_secure'] = $p['secure'] ? '1' : '0';
    $o['cookie_httponly'] = $p['httponly'] ? '1' : '0';
    $o['cookie_samesite'] = $p['samesite'];
}
header('Content-Type: application/json');
echo json_encode($o);
PHP
sudo chown www-data:www-data "$tmp_php"

curl -sk --resolve "${DOMAIN}:443:127.0.0.1" "https://${DOMAIN}/$(basename "$tmp_php")" -o "$json"

BODY=$(sudo grep -h "client_max_body_size" "$VHOST" 2>/dev/null | head -1 | awk '{print $2}' | tr -d ';' || true)
READ=$(sudo grep -h "fastcgi_read_timeout" "$VHOST" 2>/dev/null | head -1 | awk '{print $2}' | tr -d ';' || true)
FPM_TIMEOUT=$(sudo grep -h "request_terminate_timeout" "$FPM_DIR/pool.d/www.conf" 2>/dev/null | head -1 | awk '{print $3}' | tr -d ';' || true)
SLOW_TIMEOUT=$(sudo grep -h "request_slowlog_timeout" "$FPM_DIR/pool.d/www.conf" 2>/dev/null | head -1 | awk '{print $3}' | tr -d ';' || true)
MAX_CHILDREN=$(sudo grep -h "^pm.max_children" "$FPM_DIR/pool.d/www.conf" 2>/dev/null | head -1 | awk '{print $3}' | tr -d ';' || true)
WORKERS_RSS=$(ps -C "php-fpm${PHP_VERSION}" -o rss= 2>/dev/null | awk '{s+=$1;n++} END {print n+0" "int(s/1024)}' || true)
MEM_TOTAL=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)

echo "== PHP-FPM ${PHP_VERSION} @ ${DOMAIN}"
if sudo "php-fpm${PHP_VERSION}" -t >/dev/null 2>&1; then
    echo "PASS  config test"
else
    echo "FAIL  config test"
    exit 1
fi
if systemctl is-active --quiet "php${PHP_VERSION}-fpm"; then
    echo "PASS  service active"
else
    echo "FAIL  service not active"
    exit 1
fi

echo
echo "== Effective values"
python3 -m json.tool "$json"
echo
echo "== Chain / checks"
python3 - "$json" "$BODY" "$READ" "$FPM_TIMEOUT" "$SLOW_TIMEOUT" "$MAX_CHILDREN" "$WORKERS_RSS" "$MEM_TOTAL" "$SLOWLOG" <<'PY'
import json
import os
import re
import sys


def size(v):
    if not v:
        return None
    m = re.match(r'^(\d+)\s*([kmg]?)$', str(v).strip().lower())
    if not m:
        return None
    n = int(m.group(1))
    return n * {'': 1, 'k': 1024, 'm': 1024 ** 2, 'g': 1024 ** 3}[m.group(2)]


def secs(v):
    if not v:
        return None
    m = re.match(r'^(\d+)\s*([smhd]?)$', str(v).strip().lower())
    if not m:
        return None
    n = int(m.group(1))
    return n * {'': 1, 's': 1, 'm': 60, 'h': 3600, 'd': 86400}[m.group(2)]


def show(label, ok, detail=''):
    print(('PASS  ' if ok else 'WARN  ') + label + (('  ' + detail) if detail else ''))


d = json.load(open(sys.argv[1]))
body, read, fpm_to, slow_to, max_children, workers_rss, mem_total, slowlog = sys.argv[2:10]
fails = []

b, p, u = size(body), size(d.get('post_max_size')), size(d.get('upload_max_filesize'))
if b and p and u:
    ok = b >= p >= u
    show('body chain nginx >= post >= upload', ok,
         f'{body} >= {d.get("post_max_size")} >= {d.get("upload_max_filesize")}')
    if not ok:
        fails.append('body chain')
else:
    show('body chain', False, 'missing values')

r, t, e = secs(read), secs(fpm_to), secs(d.get('max_execution_time'))
if r and t and e:
    ok = r >= t >= e
    show('time chain nginx >= request_terminate >= max_execution', ok,
         f'{read} >= {fpm_to} >= {d.get("max_execution_time")}s')
    if not ok:
        fails.append('time chain')
else:
    show('time chain', False, 'missing values')

miv = int(d.get('max_input_vars') or 0)
show('max_input_vars >= 3000', miv >= 3000, str(miv))
if miv < 3000:
    fails.append('max_input_vars')

show('session Secure/HttpOnly/SameSite',
     d.get('cookie_secure') == '1' and d.get('cookie_httponly') == '1' and d.get('cookie_samesite') == 'Lax',
     f'{d.get("cookie_secure")}/{d.get("cookie_httponly")}/{d.get("cookie_samesite")}')
show('session.use_strict_mode', d.get('session.use_strict_mode') == '1', str(d.get('session.use_strict_mode')))
show('exec/shell_exec disabled', d.get('exec') == 'no' and d.get('shell_exec') == 'no',
     f'exec={d.get("exec")} shell_exec={d.get("shell_exec")}')

show('opcache enabled', d.get('opcache.enable') == '1',
     f'memory={d.get("opcache.memory_consumption")}M scripts={d.get("opcache_cached_scripts")} hit={d.get("opcache_hit_rate")}%')
used, free = d.get('opcache_used_mb'), d.get('opcache_free_mb')
if used is not None and free is not None:
    show('opcache free > 10 MB', free > 10,
         f'used={used}M free={free}M wasted={d.get("opcache_wasted_mb")}M')

show('FPM slowlog configured', bool(slow_to) and os.path.exists(slowlog), f'{slow_to} {slowlog}')
if not slow_to:
    fails.append('slowlog')

try:
    n, mb = workers_rss.split()
    n, mb = int(n), int(mb)
    if n and max_children:
        avg = mb / n
        ok = avg * int(max_children) < 0.8 * int(mem_total)
        show('max_children x avg RSS < 80% RAM', ok,
             f'{max_children} x {avg:.1f}MB = {avg * int(max_children):.0f}MB / {mem_total}MB')
        if not ok:
            fails.append('pool sizing')
except ValueError:
    pass

if fails:
    print('FAILED:', ', '.join(fails))
    sys.exit(1)
print('OK: no hard failures')
PY
