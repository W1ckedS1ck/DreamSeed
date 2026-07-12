#!/bin/bash
set -euo pipefail

for cmd in curl tar gzip find mysqldump; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: '$cmd' not found in PATH"; exit 1; }
done

# ====== Load shared functions ======
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common_functions.sh
source "$SCRIPT_DIR/common_functions.sh"
load_env "$SCRIPT_DIR/.env"

# ====== Settings ======
PROJECT_DIR="${PROJECT_DIR:-/var/www/html}"
BACKUP_DIR="${BACKUP_DIR:-/home/ubuntu/backups}"
MARKER_FILE="$BACKUP_DIR/.project_marker"

PROJECT_KEEP="${BACKUP_PROJECT_KEEP:-${PROJECT_KEEP:-5}}"
DB_KEEP="${BACKUP_DB_KEEP:-${DB_KEEP:-15}}"

DOMAIN="${DOMAIN:-unknown}"

DATE=$(date +%F_%H-%M)
PROJECT_BACKUP="$BACKUP_DIR/project/DreamSeed_$DATE.tar.gz"
DB_BACKUP="$BACKUP_DIR/db/db_${DB_NAME}_$DATE.sql.gz"

mkdir -p "$BACKUP_DIR/project" "$BACKUP_DIR/db" "$BACKUP_DIR/logs"
LOG_FILE="$BACKUP_DIR/logs/backup_$(date +%Y-%m-%d).log"

ENV=$(detect_env)
ENV_DISPLAY_ESCAPED=$(format_env_escaped "$ENV")

echo "[$(date '+%Y-%m-%d %H:%M:%S')] ⏱ Backup started — $ENV" >> "$LOG_FILE"

# ====== Lock against parallel runs ======
trap 'exec 9>&-' EXIT
LOCK_DIR="${HOME:-/tmp}/.locks"
mkdir -p "$LOCK_DIR" && chmod 700 "$LOCK_DIR"
LOCK_FILE="$LOCK_DIR/smart_backup.lock"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    echo "Backup already running (lock: $LOCK_FILE)" >&2
    exit 1
fi

# Cron heartbeat — always fires, even if backup fails
echo "cron_last_run_backup{instance=\"$DOMAIN\"} $(date +%s)" | \
    curl -s --data-binary @- "http://127.0.0.1:8428/api/v1/import/prometheus" > /dev/null 2>&1 || true

# ====== Validate MODX_TABLE_PREFIX ======
MODX_TABLE_PREFIX="${MODX_TABLE_PREFIX:-modx_}"
if ! [[ "$MODX_TABLE_PREFIX" =~ ^[a-z0-9_]+$ ]]; then
    echo "ERROR: MODX_TABLE_PREFIX contains invalid characters: '$MODX_TABLE_PREFIX'" >&2
    exit 1
fi

# ====== Pre-flight: disk space check ======
AVAILABLE_MB=$(df "$BACKUP_DIR" | tail -1 | awk '{printf "%.0f", $4/1024}')
if [ "$AVAILABLE_MB" -lt 500 ]; then
    MSG="🔴 <b>BACKUP BLOCKED</b> — $ENV_DISPLAY_ESCAPED
Disk space critical: ${AVAILABLE_MB}MB available (need ≥500MB)
Cleanup old backups or expand disk."
    send_tg "$MSG"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ❌ Disk space critical: ${AVAILABLE_MB}MB" >> "$LOG_FILE"
    exit 1
fi

# ====== Project backup (only if changed) ======
PROJECT_STATUS=""

if [[ -f "$MARKER_FILE" ]]; then
    CHANGED=$(sudo find "$PROJECT_DIR" -type f \
        ! -path "*/core/cache/*" \
        ! -path "*/core/backup/*" \
        -newer "$MARKER_FILE" -print -quit 2>/dev/null)
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Change check: $([ -z "$CHANGED" ] && echo 'unchanged' || echo 'modified')" >> "$LOG_FILE"
else
    CHANGED="initial"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Change check: first run" >> "$LOG_FILE"
fi

if [[ -z "$CHANGED" ]]; then
    PROJECT_STATUS="ℹ️ Project unchanged, backup skipped"
else
    if timeout 1800 sudo tar -czf "$PROJECT_BACKUP" \
        --exclude="$(basename "$PROJECT_DIR")/core/cache" \
        --exclude="$(basename "$PROJECT_DIR")/core/backup" \
        -C "$(dirname "$PROJECT_DIR")" "$(basename "$PROJECT_DIR")" 2>/dev/null && \
       timeout 300 sudo tar -tzf "$PROJECT_BACKUP" > /dev/null 2>&1; then
        sudo chown ubuntu:ubuntu "$PROJECT_BACKUP" 2>/dev/null || true
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Project backup OK: $PROJECT_BACKUP" >> "$LOG_FILE"
        PROJECT_STATUS="✅ Project backed up"
        rotate_files "$BACKUP_DIR/project/DreamSeed_*.tar.gz" "$PROJECT_KEEP"
        touch "$MARKER_FILE"
    else
        rm -f "$PROJECT_BACKUP"
        PROJECT_STATUS="❌ Project backup failed"
    fi
fi

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Project: $PROJECT_STATUS" >> "$LOG_FILE"

# ====== Database backup (always) ======
# Using .my.cnf — credentials not passed as arguments
DB_STATUS=""

TMP_DB_BACKUP="${DB_BACKUP}.tmp"
set +o pipefail
timeout 1800 mysqldump --single-transaction --routines --events --triggers \
    --ignore-table="${DB_NAME}.${MODX_TABLE_PREFIX:-modx_}session" \
    "$DB_NAME" | gzip > "$TMP_DB_BACKUP"
DUMP_RC=("${PIPESTATUS[@]}")
set -o pipefail

if [ "${DUMP_RC[0]}" -eq 0 ] && [ "${DUMP_RC[1]}" -eq 0 ] && [ -s "$TMP_DB_BACKUP" ]; then
    mv "$TMP_DB_BACKUP" "$DB_BACKUP"
    DB_STATUS="✅ Database backed up"
    rotate_files "$BACKUP_DIR/db/db_${DB_NAME}_*.sql.gz" "$DB_KEEP"
else
    rm -f "$TMP_DB_BACKUP"
    DB_STATUS="❌ Database dump failed"
fi
echo "[$(date '+%Y-%m-%d %H:%M:%S')] DB: $DB_STATUS" >> "$LOG_FILE"

# ====== Redis backup (if available) ======
REDIS_STATUS=""
REDIS_KEEP="${BACKUP_REDIS_KEEP:-${REDIS_KEEP:-5}}"

if sudo test -f /var/lib/redis/dump.rdb; then
    mkdir -p "$BACKUP_DIR/redis"
    REDIS_BACKUP="$BACKUP_DIR/redis/redis_dump_$DATE.rdb"
    if sudo cp /var/lib/redis/dump.rdb "$REDIS_BACKUP" 2>/dev/null && \
       sudo chown ubuntu:ubuntu "$REDIS_BACKUP" 2>/dev/null; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Redis backup OK: $REDIS_BACKUP" >> "$LOG_FILE"
        REDIS_STATUS="✅ Redis backed up"
        rotate_files "$BACKUP_DIR/redis/redis_dump_*.rdb" "$REDIS_KEEP"
    else
        REDIS_STATUS="❌ Redis backup failed"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Redis: $REDIS_STATUS" >> "$LOG_FILE"
    fi
else
    REDIS_STATUS="ℹ️ Redis not available"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Redis: $REDIS_STATUS" >> "$LOG_FILE"
fi

# ====== Telegram notification only on failure ======
if [[ "$PROJECT_STATUS" == "❌"* || "$DB_STATUS" == "❌"* || "$REDIS_STATUS" == "❌"* ]]; then
    MSG="====== ALERT ======
🔴 <b>BACKUP FAILED</b> — $ENV_DISPLAY_ESCAPED
"
    [[ "$PROJECT_STATUS" == "❌"* ]] && MSG+="$PROJECT_STATUS
"
    [[ "$DB_STATUS" == "❌"* ]] && MSG+="
$DB_STATUS"
    [[ "$REDIS_STATUS" == "❌"* ]] && MSG+="
$REDIS_STATUS"
    MSG+="
⏰ $(date '+%d.%m.%Y %H:%M')
=========================="
    send_tg "$MSG"
fi

if [[ "$PROJECT_STATUS" != "❌"* && "$DB_STATUS" != "❌"* && "$REDIS_STATUS" != "❌"* ]]; then
    echo "backup_last_success_timestamp{instance=\"$DOMAIN\"} $(date +%s)" | \
        curl -s --data-binary @- "http://127.0.0.1:8428/api/v1/import/prometheus" > /dev/null 2>&1 || true
    # Ping external watchdog on success
    if [[ -n "${BETTERUPTIME_BACKUP_KEY:-}" ]]; then
        if ping_heartbeat "$BETTERUPTIME_BACKUP_KEY"; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] Heartbeat: ✅ sent" >> "$LOG_FILE"
        else
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] Heartbeat: ❌ failed" >> "$LOG_FILE"
        fi
    else
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Heartbeat: ⏭ skipped (no BETTERUPTIME_BACKUP_KEY)" >> "$LOG_FILE"
    fi
else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Heartbeat: ⏭ skipped (backup failed)" >> "$LOG_FILE"
fi

rotate_files "$BACKUP_DIR/logs/backup_*.log" 30
