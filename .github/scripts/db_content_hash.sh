#!/bin/bash
# Content hash of the local modx_db: table names + exact row counts, in
# table_name order. [B] Restore Test records it as the pre-disaster reference
# and recomputes it after a local restore — a schema-only comparison (table
# list) would pass a stale dump with identical structure, which is exactly the
# wrong-bucket restore a DR drill must catch.
# modx_session is excluded (skipped by smart_backup.sh, truncated by
# RESTORE_ALL.sh after import).
# Usage: db_content_hash.sh <server_ip>
set -euo pipefail

IP="${1:?Usage: $0 <server_ip>}"
SSH_KEY="${SSH_KEY:-${HOME}/.ssh/deploy_key}"

ssh -q -o LogLevel=ERROR -o ServerAliveInterval=30 -o ServerAliveCountMax=10 \
  -i "$SSH_KEY" ubuntu@"$IP" bash -s <<'REMOTE'
set -euo pipefail
mysql modx_db -N -e "SELECT table_name FROM information_schema.tables WHERE table_schema='modx_db' AND table_name != 'modx_session' ORDER BY table_name" |
while IFS= read -r t; do
  printf '%s:%s\n' "$t" "$(mysql modx_db -N -e "SELECT COUNT(*) FROM \`$t\`")"
done | md5sum | cut -d' ' -f1
REMOTE
