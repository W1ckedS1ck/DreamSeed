#!/bin/bash

# ====== Load shared functions ======
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common_functions.sh
source "$SCRIPT_DIR/common_functions.sh"
load_env "$SCRIPT_DIR/.env"

# ====== Settings ======
PROJECT_DIR="/var/www/html"
BACKUP_DIR="/home/ubuntu/backups"
HASH_FILE="$BACKUP_DIR/.project_hash"

PROJECT_KEEP=5
DB_KEEP=15

DATE=$(date +%F_%H-%M)
PROJECT_BACKUP="$BACKUP_DIR/project/DreamSeed_$DATE.tar.gz"
DB_BACKUP="$BACKUP_DIR/db/db_${DB_NAME}_$DATE.sql.gz"
START_TIME=$(date +%s)

rotate_files() {
    local pattern="$1"
    local keep="$2"
    mapfile -t files < <(ls -1dt $pattern 2>/dev/null)
    if [ "${#files[@]}" -gt "$keep" ]; then
        for ((i=keep; i<${#files[@]}; i++)); do
            rm -f "${files[i]}"
        done
    fi
}

mkdir -p "$BACKUP_DIR/project" "$BACKUP_DIR/db"

ENV=$(detect_env)
ENV_DISPLAY=$(format_env_display "$ENV")
ENV_DISPLAY_ESCAPED=$(format_env_escaped "$ENV")

# ====== Lock against parallel runs ======
LOCK_FILE="/tmp/smart_backup.lock"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    echo "Backup already running (lock: $LOCK_FILE)" >&2
    exit 1
fi

# ====== Project backup (only if changed) ======
PROJECT_STATUS=""
PROJECT_PATH=""

CURRENT_HASH=$(sudo find "$PROJECT_DIR" -type f \
    ! -path "*/core/cache/*" \
    ! -path "*/core/backup/*" \
    -print0 | xargs -0 sudo md5sum | sort | md5sum | awk '{print $1}')

PREVIOUS_HASH=$(cat "$HASH_FILE" 2>/dev/null || echo "")

if [ "$CURRENT_HASH" = "$PREVIOUS_HASH" ] && [ -n "$PREVIOUS_HASH" ]; then
    PROJECT_STATUS="ℹ️ Project unchanged, backup skipped"
else
    sudo tar -czf "$PROJECT_BACKUP" \
        --exclude="html/core/cache" \
        --exclude="html/core/backup" \
        -C "$(dirname "$PROJECT_DIR")" "$(basename "$PROJECT_DIR")" 2>/dev/null

    if [ $? -eq 0 ] && sudo tar -tzf "$PROJECT_BACKUP" >/dev/null 2>&1; then
        sudo chown ubuntu:ubuntu "$PROJECT_BACKUP"
        echo "$CURRENT_HASH" > "$HASH_FILE"
        PROJECT_STATUS="✅ Project backed up"
        PROJECT_PATH="$PROJECT_BACKUP"
        rotate_files "$BACKUP_DIR/project/DreamSeed_*.tar.gz" "$PROJECT_KEEP"
    else
        rm -f "$PROJECT_BACKUP"
        PROJECT_STATUS="❌ Project backup failed"
    fi
fi

LAST_PROJECT_FILE=$(ls -1t "$BACKUP_DIR/project/DreamSeed_"*.tar.gz 2>/dev/null | head -n1)
LAST_PROJECT_DATE=$([ -n "$LAST_PROJECT_FILE" ] && basename "$LAST_PROJECT_FILE" | sed 's/DreamSeed_\(.*\)\.tar\.gz/\1/' || echo "")

# ====== Database backup (always) ======
# Using .my.cnf — credentials not passed as arguments
DB_STATUS=""
DB_PATH=""

mysqldump "$DB_NAME" | gzip > "$DB_BACKUP"

if [ "${PIPESTATUS[0]}" -eq 0 ] && [ -s "$DB_BACKUP" ]; then
    DB_STATUS="✅ Database backed up"
    DB_PATH="$DB_BACKUP"
    rotate_files "$BACKUP_DIR/db/db_${DB_NAME}_*.sql.gz" "$DB_KEEP"
else
    rm -f "$DB_BACKUP"
    DB_STATUS="❌ Database dump failed"
fi

# ====== Telegram notification only on failure ======
if [[ "$PROJECT_STATUS" == "❌"* || "$DB_STATUS" == "❌"* ]]; then
    MSG="====== ALERT ======
🔴 *BACKUP FAILED* — $ENV_DISPLAY_ESCAPED
"
    [[ "$PROJECT_STATUS" == "❌"* ]] && MSG+="$(escape_md2 "$PROJECT_STATUS")
"
    [[ "$DB_STATUS" == "❌"* ]] && MSG+="
$(escape_md2 "$DB_STATUS")"
    MSG+="
⏰ $(date '+%d.%m.%Y %H:%M')
=========================="
    send_tg "$MSG"
fi

if [[ "$PROJECT_STATUS" != "❌"* && "$DB_STATUS" != "❌"* ]]; then
    echo "backup_last_success_timestamp $(date +%s)" | \
        curl -s --data-binary @- "http://127.0.0.1:8428/api/v1/import/prometheus" > /dev/null 2>&1
fi
