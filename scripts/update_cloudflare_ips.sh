#!/bin/bash
set -euo pipefail

# ====== Usage ======
# Periodically updates nginx Cloudflare real IP config.
# Runs automatically via systemd timer (weekly).
# Safe to run manually at any time.

CONF="/etc/nginx/conf.d/cloudflare-realip.conf"

V4=$(curl -sL --max-time 10 https://www.cloudflare.com/ips-v4 2>/dev/null) || { echo "Failed to fetch IPv4 ranges"; exit 0; }
V6=$(curl -sL --max-time 10 https://www.cloudflare.com/ips-v6 2>/dev/null) || { echo "Failed to fetch IPv6 ranges"; exit 0; }

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

mv "$NEW" "$CONF"
chmod 644 "$CONF"

if nginx -t 2>/dev/null; then
  systemctl reload nginx
  echo "Cloudflare IP ranges updated"
else
  echo "nginx config test failed — keeping old ranges"
  exit 1
fi
