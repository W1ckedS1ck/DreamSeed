#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common_functions.sh"
load_env "$SCRIPT_DIR/.env"

BACKUP_DIR="${BACKUP_DIR:-/home/ubuntu/backups}"
DB_NAME="${DB_NAME:-modx_db}"
DOMAIN="${DOMAIN:-unknown}"

LOG_FILE="$BACKUP_DIR/logs/verify_$(date +%Y-%m-%d).log"
mkdir -p "$BACKUP_DIR/logs"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] ⏱ Backup verification started" >> "$LOG_FILE"

LOCAL_OK=0
CLOUD_OK=0
ALERTS=""

# ====== Verify local project backup ======
PROJ_BACKUP=$(find "$BACKUP_DIR/project" -maxdepth 1 -name "DreamSeed_*.tar.gz" -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)

if [[ -n "$PROJ_BACKUP" && -f "$PROJ_BACKUP" ]]; then
    if tar -tzf "$PROJ_BACKUP" > /dev/null 2>&1; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✓ Project backup OK: $(basename "$PROJ_BACKUP")" >> "$LOG_FILE"
        LOCAL_OK=1
    else
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✗ Project backup CORRUPTED: $(basename "$PROJ_BACKUP")" >> "$LOG_FILE"
        ALERTS+="❌ Project backup corrupted: $(basename "$PROJ_BACKUP")
"
    fi
else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✗ No project backup found" >> "$LOG_FILE"
    ALERTS+="❌ No project backup found in $BACKUP_DIR/project
"
fi

# ====== Verify local DB backup ======
DB_BACKUP=$(find "$BACKUP_DIR/db" -maxdepth 1 -name "db_${DB_NAME}_*.sql.gz" -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)

if [[ -n "$DB_BACKUP" && -f "$DB_BACKUP" ]]; then
    if gunzip -t "$DB_BACKUP" > /dev/null 2>&1; then
        sql_head=$(zcat "$DB_BACKUP" 2>/dev/null | head -1000) || true
        if grep -q "CREATE TABLE\|INSERT INTO" <<< "$sql_head" 2>/dev/null; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✓ DB backup OK: $(basename "$DB_BACKUP")" >> "$LOG_FILE"
            LOCAL_OK=$((LOCAL_OK == 1 ? 1 : 0))
        else
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✗ DB backup INVALID SQL: $(basename "$DB_BACKUP")" >> "$LOG_FILE"
            ALERTS+="❌ DB backup invalid SQL: $(basename "$DB_BACKUP")
"
            LOCAL_OK=0
        fi
    else
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✗ DB backup CORRUPTED: $(basename "$DB_BACKUP")" >> "$LOG_FILE"
        ALERTS+="❌ DB backup corrupted: $(basename "$DB_BACKUP")
"
        LOCAL_OK=0
    fi
else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✗ No DB backup found" >> "$LOG_FILE"
    ALERTS+="❌ No DB backup found in $BACKUP_DIR/db
"
    LOCAL_OK=0
fi

export_metric "backup_verification_ok{type=\"local\",instance=\"$DOMAIN\"} $LOCAL_OK"

# ====== Verify cloud backups (if rclone configured) ======
if [[ -f "$SCRIPT_DIR/rclone.conf" ]] || [[ -f ~/.config/rclone/rclone.conf ]]; then
    ENV=$(detect_env)
    PROJ_CLOUD_PATH="gdrive:DreamSeed/backups/project${ENV}"
    DB_CLOUD_PATH="gdrive:DreamSeed/backups/db${ENV}"

    PROJ_CLOUD_COUNT=$(rclone lsf "$PROJ_CLOUD_PATH" 2>/dev/null | wc -l || echo "0")
    DB_CLOUD_COUNT=$(rclone lsf "$DB_CLOUD_PATH" 2>/dev/null | wc -l || echo "0")

    if [[ "$PROJ_CLOUD_COUNT" -gt 0 && "$DB_CLOUD_COUNT" -gt 0 ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✓ Cloud backups OK: $PROJ_CLOUD_COUNT project, $DB_CLOUD_COUNT DB" >> "$LOG_FILE"
        CLOUD_OK=1
    else
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✗ Cloud backups MISSING: project=$PROJ_CLOUD_COUNT, db=$DB_CLOUD_COUNT" >> "$LOG_FILE"
        ALERTS+="❌ Cloud backups missing or empty
"
        CLOUD_OK=0
    fi

    export_metric "backup_verification_ok{type=\"cloud\",instance=\"$DOMAIN\"} $CLOUD_OK"
else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ⏭ Cloud verification skipped (rclone not configured)" >> "$LOG_FILE"
fi

# ====== Send alerts if verification failed ======
if [[ -n "$ALERTS" ]]; then
    MSG="====== ALERT ======
🔴 *BACKUP VERIFICATION FAILED* — $DOMAIN

$ALERTS
⏰ $(date '+%d.%m.%Y %H:%M')
=========================="
    send_tg "$MSG"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Alert sent to Telegram" >> "$LOG_FILE"
else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✅ All verifications passed" >> "$LOG_FILE"
fi

rotate_files "$BACKUP_DIR/logs/verify_*.log" 30
