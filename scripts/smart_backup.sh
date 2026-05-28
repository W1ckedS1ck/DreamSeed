#!/bin/bash

# ====== Load shared functions ======
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common_functions.sh
source "$SCRIPT_DIR/common_functions.sh"
load_env "$SCRIPT_DIR/.env"

# ====== Settings ======
PROJECT_DIR="${PROJECT_DIR:-/var/www/html}"
BACKUP_DIR="${BACKUP_DIR:-/home/ubuntu/backups}"
HASH_FILE="$BACKUP_DIR/.project_hash"

PROJECT_KEEP="${PROJECT_KEEP:-5}"
DB_KEEP="${DB_KEEP:-15}"

DATE=$(date +%F_%H-%M)
PROJECT_BACKUP="$BACKUP_DIR/project/DreamSeed_$DATE.tar.gz"
DB_BACKUP="$BACKUP_DIR/db/db_${DB_NAME}_$DATE.sql.gz"

rotate_files() {
    local pattern="$1"
    local keep="$2"
    local dir
    dir=$(dirname "$pattern")
    local glob
    glob=$(basename "$pattern")
    mapfile -t files < <(find "$dir" -maxdepth 1 -name "$glob" -printf '%T@ %p\n' 2>/dev/null | sort -rn | cut -d' ' -f2-)
    if [ "${#files[@]}" -gt "$keep" ]; then
        for ((i=keep; i<${#files[@]}; i++)); do
            rm -f "${files[i]}"
        done
    fi
}

mkdir -p "$BACKUP_DIR/project" "$BACKUP_DIR/db" "$BACKUP_DIR/logs"
LOG_FILE="$BACKUP_DIR/logs/backup_$(date +%Y-%m-%d).log"

ENV=$(detect_env)
ENV_DISPLAY_ESCAPED=$(format_env_escaped "$ENV")

echo "[$(date '+%Y-%m-%d %H:%M:%S')] ⏱ Backup started — $ENV" >> "$LOG_FILE"

# ====== Lock against parallel runs ======
LOCK_FILE="/tmp/smart_backup.lock"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    echo "Backup already running (lock: $LOCK_FILE)" >&2
    exit 1
fi
trap 'exec 9>&-' EXIT

# Cron heartbeat — always fires, even if backup fails
echo "cron_last_run_backup{instance=\"$DOMAIN\"} $(date +%s)" | \
    curl -s --data-binary @- "http://127.0.0.1:8428/api/v1/import/prometheus" > /dev/null 2>&1

# ====== Project backup (only if changed) ======
PROJECT_STATUS=""

CURRENT_HASH=$(set -o pipefail; sudo find "$PROJECT_DIR" -type f \
    ! -path "*/core/cache/*" \
    ! -path "*/core/backup/*" \
    -print0 | xargs -0 sudo md5sum 2>/dev/null | sort | md5sum | awk '{print $1}') || CURRENT_HASH=""
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Hash: $(echo "${CURRENT_HASH:-empty}" | head -c 12)..." >> "$LOG_FILE"

PREVIOUS_HASH=$(cat "$HASH_FILE" 2>/dev/null || echo "")

if [ "$CURRENT_HASH" = "$PREVIOUS_HASH" ] && [ -n "$PREVIOUS_HASH" ]; then
    PROJECT_STATUS="ℹ️ Project unchanged, backup skipped"
else
    if sudo tar -czf "$PROJECT_BACKUP" \
        --exclude="html/core/cache" \
        --exclude="html/core/backup" \
        -C "$(dirname "$PROJECT_DIR")" "$(basename "$PROJECT_DIR")" >> "$LOG_FILE" 2>&1 && \
       sudo tar -tzf "$PROJECT_BACKUP" >> "$LOG_FILE" 2>&1; then
        sudo chown ubuntu:ubuntu "$PROJECT_BACKUP"
        echo "$CURRENT_HASH" > "$HASH_FILE"
        PROJECT_STATUS="✅ Project backed up"
        rotate_files "$BACKUP_DIR/project/DreamSeed_*.tar.gz" "$PROJECT_KEEP"
    else
        rm -f "$PROJECT_BACKUP"
        PROJECT_STATUS="❌ Project backup failed"
    fi
fi

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Project: $PROJECT_STATUS" >> "$LOG_FILE"

# ====== Database backup (always) ======
# Using .my.cnf — credentials not passed as arguments
DB_STATUS=""

mysqldump "$DB_NAME" | gzip > "$DB_BACKUP"

if [ "${PIPESTATUS[0]}" -eq 0 ] && [ -s "$DB_BACKUP" ]; then
    DB_STATUS="✅ Database backed up"
    rotate_files "$BACKUP_DIR/db/db_${DB_NAME}_*.sql.gz" "$DB_KEEP"
else
    rm -f "$DB_BACKUP"
    DB_STATUS="❌ Database dump failed"
fi
echo "[$(date '+%Y-%m-%d %H:%M:%S')] DB: $DB_STATUS" >> "$LOG_FILE"

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
    echo "backup_last_success_timestamp{instance=\"$DOMAIN\"} $(date +%s)" | \
        curl -s --data-binary @- "http://127.0.0.1:8428/api/v1/import/prometheus" > /dev/null 2>&1
    # Ping external watchdog on success
    if [[ -n "${BETTERUPTIME_BACKUP_KEY:-}" ]]; then
        if curl -fsS -m 10 --retry 3 "https://uptime.betterstack.com/api/v1/heartbeat/${BETTERUPTIME_BACKUP_KEY}" > /dev/null 2>&1; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] Heartbeat: ✅ sent" >> "$LOG_FILE"
        else
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] Heartbeat: ❌ curl failed" >> "$LOG_FILE"
        fi
    else
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Heartbeat: ⏭ skipped (no BETTERUPTIME_BACKUP_KEY)" >> "$LOG_FILE"
    fi
else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Heartbeat: ⏭ skipped (backup failed)" >> "$LOG_FILE"
fi

rotate_files "$BACKUP_DIR/logs/backup_*.log" 30
