#!/bin/bash
set -euo pipefail

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# ====== Load shared functions ======
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common_functions.sh
source "$SCRIPT_DIR/common_functions.sh"
load_env "$SCRIPT_DIR/.env"

# ====== Start time ======
START_TIME=$(date +%s)
DOMAIN="${DOMAIN:-$(hostname -f 2>/dev/null || echo "unknown")}"

# NOTE: Dev = Prod. Everything prod does, dev does too — same monitoring,
# same backups, same alerting. Even though restore always pulls from prod
# paths, dev must mirror prod behavior exactly (including cloud uploads).
# Do NOT skip dev uploads or introduce dev-vs-prod logic.

# ====== Settings ======
LOCAL_BACKUP_DIR="${BACKUP_DIR:-/home/ubuntu/backups}"
PROJECT_DIR="$LOCAL_BACKUP_DIR/project"
DB_DIR="$LOCAL_BACKUP_DIR/db"
REDIS_DIR="$LOCAL_BACKUP_DIR/redis"

RCLONE_REMOTE="gdrive"

# Validate rclone remote name
if ! [[ "$RCLONE_REMOTE" =~ ^[a-zA-Z0-9_]+$ ]]; then
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

# ====== 1. Upload project ======
LAST_PROJECT=$(find "$PROJECT_DIR" -maxdepth 1 -name 'DreamSeed_*.tar.gz' -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
if [ -n "$LAST_PROJECT" ]; then
    export RCLONE_CMD_TIMEOUT=1800
    if ! rclone_retry copy "$LAST_PROJECT" "$RCLONE_REMOTE:$REMOTE_BASE/project${ENV_SUFFIX}/" --no-check-dest; then
        UPLOAD_MSG+="❌ Project upload error
"
        HAS_ERROR=1
    fi
else
    UPLOAD_MSG+="⚠️ Project backup not found
"
    HAS_ERROR=1
fi

# ====== 2. Upload database ======
LAST_DB=$(find "$DB_DIR" -maxdepth 1 -name 'db_*.sql.gz' -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
if [ -n "$LAST_DB" ]; then
    export RCLONE_CMD_TIMEOUT=1800
    if ! rclone_retry copy "$LAST_DB" "$RCLONE_REMOTE:$REMOTE_BASE/db${ENV_SUFFIX}/" --no-check-dest; then
        UPLOAD_MSG+="❌ DB upload error
"
        HAS_ERROR=1
    fi
else
    UPLOAD_MSG+="⚠️ DB backup not found
"
    HAS_ERROR=1
fi

# ====== 3. Upload Redis ======
if [[ -d "$REDIS_DIR" ]]; then
    LAST_REDIS=$(find "$REDIS_DIR" -maxdepth 1 -name 'redis_dump_*.rdb' -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
    if [ -n "$LAST_REDIS" ]; then
        export RCLONE_CMD_TIMEOUT=600
        if ! rclone_retry copy "$LAST_REDIS" "$RCLONE_REMOTE:$REMOTE_BASE/redis${ENV_SUFFIX}/" --no-check-dest; then
            UPLOAD_MSG+="❌ Redis upload error
"
            HAS_ERROR=1
        fi
    fi
fi

# ====== 4. Clean old backups in cloud ======

prune_cloud_backups "project" "$MAX_PROJECT_BACKUPS" || UPLOAD_MSG+="⚠️ Project listing failed, cleanup skipped
"
prune_cloud_backups "db" "$MAX_DB_BACKUPS" || UPLOAD_MSG+="⚠️ DB listing failed, cleanup skipped
"
prune_cloud_backups "redis" "$MAX_REDIS_BACKUPS" || UPLOAD_MSG+="⚠️ Redis listing failed, cleanup skipped
"

timeout 60 rclone cleanup "$RCLONE_REMOTE:$REMOTE_BASE" 2>/dev/null

if [[ "$HAS_ERROR" -eq 0 ]]; then
    echo "upload_last_success_timestamp{instance=\"$DOMAIN\"} $(date +%s)" | \
        curl -s --data-binary @- "http://127.0.0.1:8428/api/v1/import/prometheus" > /dev/null 2>&1 || true
    [[ -n "${BETTERUPTIME_GDRIVE_KEY:-}" ]] && ping_heartbeat "$BETTERUPTIME_GDRIVE_KEY"
fi

# ====== Suppress alert on fresh servers (<1h uptime — backup cron races with manual steps) ======
UPTIME=$(awk '{print int($1)}' /proc/uptime 2>/dev/null || echo 999999)
if [ "$HAS_ERROR" -eq 1 ] && [ "$UPTIME" -lt 3600 ]; then
    exit 0
fi

# ====== Send alert only on failure ======
if [ "$HAS_ERROR" -eq 1 ]; then
    END_TIME=$(date +%s)
    DURATION=$((END_TIME - START_TIME))
    MSG="====== ALERT ======
🔴 <b>UPLOAD FAILED</b> — $ENV_DISPLAY_ESCAPED

${UPLOAD_MSG}⏰ $(date '+%d.%m.%Y %H:%M')  ⏱ ${DURATION}s
=========================="
    send_tg "$MSG"
fi
