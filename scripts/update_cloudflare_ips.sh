#!/bin/bash
set -euo pipefail

# ==== Usage ====
# Periodically updates nginx Cloudflare real IP config.
# Runs automatically via systemd timer (weekly).
# Safe to run manually at any time.
# Never overwrites the live config unless the fetched ranges are valid CIDRs.

CONF="/etc/nginx/conf.d/cloudflare-realip.conf"

# Validate ranges are real CIDRs before touching the live config. An HTML
# error page or empty body must never reach the nginx conf on disk.
validate_v4() {
    local line pfx o1 o2 o3 o4
    [[ -n "$1" ]] || { echo "ERROR: empty IPv4 ranges from Cloudflare" >&2; return 1; }
    while IFS= read -r line; do
        [[ "$line" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})/([0-9]{1,2})$ ]] || {
            echo "ERROR: invalid IPv4 CIDR: '$line'" >&2; return 1; }
        o1="${BASH_REMATCH[1]}" o2="${BASH_REMATCH[2]}" o3="${BASH_REMATCH[3]}"
        o4="${BASH_REMATCH[4]}" pfx="${BASH_REMATCH[5]}"
        (( o1<=255 && o2<=255 && o3<=255 && o4<=255 )) || {
            echo "ERROR: out-of-range IPv4 octet: '$line'" >&2; return 1; }
        (( pfx<=32 )) || { echo "ERROR: out-of-range IPv4 prefix: '$line'" >&2; return 1; }
    done <<< "$1"
    return 0
}

validate_v6() {
    local line pfx
    [[ -n "$1" ]] || { echo "ERROR: empty IPv6 ranges from Cloudflare" >&2; return 1; }
    while IFS= read -r line; do
        [[ "$line" =~ ^[0-9A-Fa-f:]+/[0-9]{1,3}$ ]] || {
            echo "ERROR: invalid IPv6 CIDR: '$line'" >&2; return 1; }
        pfx="${line##*/}"
        (( pfx<=128 )) || { echo "ERROR: out-of-range IPv6 prefix: '$line'" >&2; return 1; }
    done <<< "$1"
    return 0
}

# ==== Selftest (no network/fs access) — ./update_cloudflare_ips.sh --selftest ====
if [[ "${1:-}" == "--selftest" ]]; then
    pass=0; fail=0
    t() { local name="$1" want="$2"; shift 2; local got; if "$@" >/dev/null 2>&1; then got=PASS; else got=FAIL; fi; if [[ "$want" == "$got" ]]; then pass=$((pass+1)); else fail=$((fail+1)); printf '  \xe2\x9c\x97 %-22s want=%s got=%s\n' "$name" "$want" "$got"; fi; }
    t "v4 valid list"  PASS validate_v4 "$(printf '173.245.48.0/20\n1.1.1.0/24\n0.0.0.0/0')"
    t "v4 octet 256"   FAIL validate_v4 "173.245.48.256/20"
    t "v4 html garb"   FAIL validate_v4 "<!DOCTYPE html>"
    t "v4 prefix 33"   FAIL validate_v4 "1.1.1.1/33"
    t "v4 empty"       FAIL validate_v4 ""
    t "v4 no slash"    FAIL validate_v4 "1.2.3.4"
    t "v6 valid"       PASS validate_v6 "2400:cb00::/32"
    t "v6 garbage"     FAIL validate_v6 "2001:db8:zz::/32"
    t "v6 prefix 129"  FAIL validate_v6 "2001:db8::/129"
    t "v6 empty"       FAIL validate_v6 ""
    echo "selftest: $pass passed, $fail failed"
    exit $(( fail > 0 ))
fi

V4="$(curl -fsSL --max-time 10 https://www.cloudflare.com/ips-v4)" || { echo "Failed to fetch IPv4 ranges" >&2; exit 1; }
V6="$(curl -fsSL --max-time 10 https://www.cloudflare.com/ips-v6)" || { echo "Failed to fetch IPv6 ranges" >&2; exit 1; }

validate_v4 "$V4"
validate_v6 "$V6"

NEW=$(mktemp)
{
  printf '# Cloudflare real IP ranges — auto-updated\n'
  printf '# Source: https://www.cloudflare.com/ips-v4 / ips-v6\n'
  printf '%s\n' "$V4" | sed 's/^/set_real_ip_from /; s/$/;/'
  printf '%s\n' "$V6" | sed 's/^/set_real_ip_from /; s/$/;/'
  printf 'real_ip_header CF-Connecting-IP;\n'
} > "$NEW"

if diff -q "$NEW" "$CONF" 2>/dev/null; then
  rm -f "$NEW"
  exit 0
fi

# Keep a copy of the live config so a failed nginx -t can actually be
# rolled back — mv already replaced it on disk by that point.
CONF_BACKUP=""
if [[ -f "$CONF" ]]; then
  CONF_BACKUP=$(mktemp)
  cp -p "$CONF" "$CONF_BACKUP"
fi

mv "$NEW" "$CONF"
chmod 644 "$CONF"

if nginx -t 2>/dev/null; then
  systemctl reload nginx
  echo "Cloudflare IP ranges updated"
  [[ -n "$CONF_BACKUP" ]] && rm -f "$CONF_BACKUP"
else
  echo "nginx config test failed — restoring previous config"
  if [[ -n "$CONF_BACKUP" ]]; then
    mv "$CONF_BACKUP" "$CONF"
  else
    rm -f "$CONF"
  fi
  exit 1
fi
