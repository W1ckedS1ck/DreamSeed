#!/bin/bash

# Path for cron
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# ====== Load shared functions ======
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common_functions.sh
source "$SCRIPT_DIR/common_functions.sh"
load_env "$SCRIPT_DIR/.env"

# ====== Start time ======
START_TIME=$(date +%s)

# ====== Settings ======
LOCAL_BACKUP_DIR="/home/ubuntu/backups"
PROJECT_DIR="$LOCAL_BACKUP_DIR/project"
DB_DIR="$LOCAL_BACKUP_DIR/db"

RCLONE_REMOTE="gdrive"

ENV=$(detect_env)
ENV_DISPLAY=$(format_env_display "$ENV")
ENV_DISPLAY_ESCAPED=$(format_env_escaped "$ENV")
REMOTE_BASE="DreamSeed/backups"

MAX_PROJECT_BACKUPS=5
MAX_DB_BACKUPS=10

LOCAL_PROJECT_KEEP=10
LOCAL_DB_KEEP=15


HAS_ERROR=0
UPLOAD_MSG=""

# ====== 1. Upload project ======
LAST_PROJECT=$(ls -1t "$PROJECT_DIR"/DreamSeed_*.tar.gz 2>/dev/null | head -n1)
LOCAL_PROJECT_COUNT=$(ls -1 "$PROJECT_DIR"/DreamSeed_*.tar.gz 2>/dev/null | wc -l | tr -d ' ')
if [ -n "$LAST_PROJECT" ]; then
    if rclone copy "$LAST_PROJECT" "$RCLONE_REMOTE:$REMOTE_BASE/project${ENV}/" --ignore-existing; then
        PROJ_BASENAME=$(basename "$LAST_PROJECT" | sed 's/DreamSeed_//' | sed 's/\.tar\.gz//')
    else
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
LAST_DB=$(ls -1t "$DB_DIR"/db_*.sql.gz 2>/dev/null | head -n1)
LOCAL_DB_COUNT=$(ls -1 "$DB_DIR"/db_*.sql.gz 2>/dev/null | wc -l | tr -d ' ')
if [ -n "$LAST_DB" ]; then
    if rclone copy "$LAST_DB" "$RCLONE_REMOTE:$REMOTE_BASE/db${ENV}/" --ignore-existing; then
        DB_BASENAME=$(basename "$LAST_DB" | sed 's/db_modx_db_//' | sed 's/\.sql\.gz//')
    else
        UPLOAD_MSG+="❌ DB upload error
"
        HAS_ERROR=1
    fi
else
    UPLOAD_MSG+="⚠️ DB backup not found
"
    HAS_ERROR=1
fi

# ====== 3. Clean old backups in cloud ======

# Old projects
CLOUD_PROJ_ALL=$(rclone lsf "$RCLONE_REMOTE:$REMOTE_BASE/project${ENV}/" --files-only | sort -r)
PROJ_COUNT=$(echo "$CLOUD_PROJ_ALL" | grep -c '[^[:space:]]')
if [ "$PROJ_COUNT" -gt "$MAX_PROJECT_BACKUPS" ]; then
    while read -r file; do
        [ -n "$file" ] && rclone delete "$RCLONE_REMOTE:$REMOTE_BASE/project${ENV}/$file"
    done <<< "$(echo "$CLOUD_PROJ_ALL" | tail -n +$((MAX_PROJECT_BACKUPS + 1)))"
    CLOUD_PROJ=$(echo "$CLOUD_PROJ_ALL" | head -n "$MAX_PROJECT_BACKUPS")
else
    CLOUD_PROJ="$CLOUD_PROJ_ALL"
fi

# Old databases
CLOUD_DB_ALL=$(rclone lsf "$RCLONE_REMOTE:$REMOTE_BASE/db${ENV}/" --files-only | sort -r)
DB_COUNT=$(echo "$CLOUD_DB_ALL" | grep -c '[^[:space:]]')
if [ "$DB_COUNT" -gt "$MAX_DB_BACKUPS" ]; then
    while read -r file; do
        [ -n "$file" ] && rclone delete "$RCLONE_REMOTE:$REMOTE_BASE/db${ENV}/$file"
    done <<< "$(echo "$CLOUD_DB_ALL" | tail -n +$((MAX_DB_BACKUPS + 1)))"
    CLOUD_DB=$(echo "$CLOUD_DB_ALL" | head -n "$MAX_DB_BACKUPS")
else
    CLOUD_DB="$CLOUD_DB_ALL"
fi

# Trash
rclone cleanup "$RCLONE_REMOTE:" 2>/dev/null

# ====== Send alert only on failure ======
if [ "$HAS_ERROR" -eq 1 ]; then
    END_TIME=$(date +%s)
    DURATION=$((END_TIME - START_TIME))
    MSG="====== ALERT ======
🔴 *UPLOAD FAILED* — $ENV_DISPLAY_ESCAPED

❌ Upload to GDrive failed
⏰ $(date '+%d.%m.%Y %H:%M')  ⏱ ${DURATION}s
=========================="
    send_tg "$MSG"
fi
