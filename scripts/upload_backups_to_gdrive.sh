#!/bin/bash
set -euo pipefail

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# ==== Load shared functions ====
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common_functions.sh
source "$SCRIPT_DIR/common_functions.sh"
load_env "$SCRIPT_DIR/.env"

# ==== Logging ====
LOG_DIR="${BACKUP_DIR:-/home/ubuntu/backups}/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/upload_$(date +%Y-%m-%d).log"
touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/dev/null"
exec >> "$LOG_FILE" 2>&1

# ==== Start time ====
START_TIME=$(date +%s)
DOMAIN="${DOMAIN:-$(hostname -f 2>/dev/null || echo "unknown")}"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] ⏱ Upload started — environment suffix: $(detect_env)"

# Dev mirrors prod exactly (monitoring/backups/alerting); restore pulls prod paths.
# Do NOT add dev-vs-prod logic.

# ==== Settings ====
LOCAL_BACKUP_DIR="${BACKUP_DIR:-/home/ubuntu/backups}"
PROJECT_DIR="$LOCAL_BACKUP_DIR/project"
DB_DIR="$LOCAL_BACKUP_DIR/db"
REDIS_DIR="$LOCAL_BACKUP_DIR/redis"

RCLONE_REMOTE="${RCLONE_REMOTE:-gdrive-crypt}"

# Fail if crypt remote is not configured — plaintext fallback is a security risk
if ! rclone listremotes 2>/dev/null | grep -qF "${RCLONE_REMOTE}:"; then
    echo "ERROR: $RCLONE_REMOTE remote not found — backup encryption disabled"
    echo "ERROR: Set RCLONE_CRYPT_PASSWORD and redeploy to create crypt remote"
    exit 1
fi

# Validate rclone remote name
if ! [[ "$RCLONE_REMOTE" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo "ERROR: Invalid rclone remote name: $RCLONE_REMOTE (must be alphanumeric + underscore)"
    exit 1
fi

ENV_SUFFIX=$(detect_env)
ENV_DISPLAY_ESCAPED=$(format_env_escaped "$ENV_SUFFIX")
REMOTE_BASE="DreamSeed/backups"

MAX_PROJECT_BACKUPS="${CLOUD_PROJECT_KEEP:-10}"
MAX_DB_BACKUPS="${CLOUD_DB_KEEP:-100}"
MAX_REDIS_BACKUPS="${CLOUD_REDIS_KEEP:-10}"


HAS_ERROR=0
UPLOAD_MSG=""

# Upload every local backup that is not yet present in the cloud. Previously
# only the newest file per type was uploaded — a failed upload of an older
# file was never retried and got pruned locally, leaving a permanent gap in
# cloud history (M16).
upload_new_files() {
    local local_dir="$1" glob="$2" remote_dir="$3" timeout="$4" label="$5"
    local files base existing_present
    files=$(find "$local_dir" -maxdepth 1 -type f -name "$glob" -printf '%f\n' 2>/dev/null | sort -r || true)
    [ -z "$files" ] && { echo "  $label: ⚠️ no backups found"; return 0; }

    existing_present=$(rclone lsf "$RCLONE_REMOTE:$remote_dir/" --files-only 2>/dev/null | sort || true)
    export RCLONE_CMD_TIMEOUT="$timeout"

    while IFS= read -r base; do
        if printf '%s\n' "$existing_present" | grep -qxF "$base"; then
            continue
        fi
        local full="$local_dir/$base"
        echo "  $label: ⏫ $base ($(du -h "$full" | cut -f1))"
        if rclone_retry copy "$full" "$RCLONE_REMOTE:$remote_dir/" >/dev/null; then
            echo "  $label: ✅ uploaded"
        else
            echo "  $label: ❌ upload failed"
            UPLOAD_MSG+="❌ $label upload error: $base
"
            HAS_ERROR=1
        fi
    done <<< "$files"
}

# ==== 1. Upload project ====
upload_new_files "$PROJECT_DIR" "DreamSeed_*.tar.gz" "$REMOTE_BASE/project${ENV_SUFFIX}/" 1800 "Project"

# ==== 2. Upload database ====
upload_new_files "$DB_DIR" "db_*.sql.gz" "$REMOTE_BASE/db${ENV_SUFFIX}/" 1800 "DB"

# ==== 3. Upload Redis ====
if [[ -d "$REDIS_DIR" ]]; then
    upload_new_files "$REDIS_DIR" "redis_dump_*.rdb" "$REMOTE_BASE/redis${ENV_SUFFIX}/" 600 "Redis"
fi

# ==== 4. Clean old backups in cloud ====
prune_cloud_backups "project" "$MAX_PROJECT_BACKUPS" || UPLOAD_MSG+="⚠️ Project listing failed, cleanup skipped
"
prune_cloud_backups "db" "$MAX_DB_BACKUPS" || UPLOAD_MSG+="⚠️ DB listing failed, cleanup skipped
"
prune_cloud_backups "redis" "$MAX_REDIS_BACKUPS" || UPLOAD_MSG+="⚠️ Redis listing failed, cleanup skipped
"

if timeout 60 rclone cleanup "$RCLONE_REMOTE:$REMOTE_BASE" 2>/dev/null; then
    echo "  Cleanup: ✅ trash emptied"
else
    echo "  Cleanup: ⚠️ skipped (timeout or error)"
fi

# ==== 5. Rotate old logs (keep 30 days) ====
find "$LOG_DIR" -name 'upload_*.log' -mtime +30 -delete 2>/dev/null || true

if [[ "$HAS_ERROR" -eq 0 ]]; then
    echo "upload_last_success_timestamp{instance=\"$DOMAIN\"} $(date +%s)" | \
        curl -s --data-binary @- "http://127.0.0.1:8428/api/v1/import/prometheus" > /dev/null 2>&1 || true
    [[ -n "${BETTERUPTIME_GDRIVE_KEY:-}" ]] && { ping_heartbeat "$BETTERUPTIME_GDRIVE_KEY" || true; }
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✅ All uploads successful"
else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ⚠️ Upload completed with errors"
fi

# ==== Suppress alert on fresh servers (<1h uptime — backup cron races with manual steps) ====
UPTIME=$(awk '{print int($1)}' /proc/uptime 2>/dev/null || echo 999999)
if [ "$HAS_ERROR" -eq 1 ] && [ "$UPTIME" -lt 3600 ]; then
    exit 0
fi

# ==== Send alert only on failure ====
if [ "$HAS_ERROR" -eq 1 ]; then
    END_TIME=$(date +%s)
    DURATION=$((END_TIME - START_TIME))
    MSG="====== ALERT ======
🔴 <b>UPLOAD FAILED</b> — $ENV_DISPLAY_ESCAPED

${UPLOAD_MSG}⏰ $(date '+%d.%m.%Y %H:%M')  ⏱ ${DURATION}s
=========================="
    send_tg "$MSG" || true
    # Honest exit code — cron/systemd must see the failure, not only TG/Better Stack.
    exit 1
fi
exit 0
