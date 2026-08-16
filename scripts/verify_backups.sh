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

echo "[$(date '+%Y-%m-%d %H:%M:%S')] ⏱ Backup verification started" >>"$LOG_FILE"

LOCAL_PROJ_OK=0
LOCAL_DB_OK=0
CLOUD_OK=0
ALERTS=""

# ==== Verify local project backup ====
PROJ_BACKUP=$(list_backups "$BACKUP_DIR/project" 'DreamSeed_*.tar.gz' | head -1)
PROJ_MISSING=0

if [[ -n "$PROJ_BACKUP" && -f "$PROJ_BACKUP" ]]; then
    if timeout 300 tar -tzf "$PROJ_BACKUP" >/dev/null 2>&1; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✓ Project backup OK: $(basename "$PROJ_BACKUP")" >>"$LOG_FILE"
        LOCAL_PROJ_OK=1
    else
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✗ Project backup CORRUPTED: $(basename "$PROJ_BACKUP")" >>"$LOG_FILE"
        ALERTS+="❌ Project backup corrupted: $(basename "$PROJ_BACKUP")
"
    fi
else
    # Project archives are only created when site files change (smart_backup.sh),
    # so absence is EXPECTED on low-churn sites. Don't hard-fail here — resolve
    # against DB freshness below (a fresh DB dump proves the pipeline runs).
    PROJ_MISSING=1
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ⚠ No project backup found (expected when site files unchanged)" >>"$LOG_FILE"
fi

# ==== Verify local DB backup ====
DB_BACKUP=$(list_backups "$BACKUP_DIR/db" 'db_*.sql.gz' | head -1)

if [[ -n "$DB_BACKUP" && -f "$DB_BACKUP" ]]; then
    if gunzip -t "$DB_BACKUP" >/dev/null 2>&1; then
        sql_head=$(zcat "$DB_BACKUP" 2>/dev/null | head -1000) || true
        if grep -q "CREATE TABLE\|INSERT INTO" <<<"$sql_head" 2>/dev/null; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✓ DB backup OK: $(basename "$DB_BACKUP")" >>"$LOG_FILE"
            LOCAL_DB_OK=1
        else
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✗ DB backup INVALID SQL: $(basename "$DB_BACKUP")" >>"$LOG_FILE"
            ALERTS+="❌ DB backup invalid SQL: $(basename "$DB_BACKUP")
"
        fi
    else
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✗ DB backup CORRUPTED: $(basename "$DB_BACKUP")" >>"$LOG_FILE"
        ALERTS+="❌ DB backup corrupted: $(basename "$DB_BACKUP")
"
    fi
else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✗ No DB backup found" >>"$LOG_FILE"
    ALERTS+="❌ No DB backup found in $BACKUP_DIR/db
"
fi

# Freshness: DB dumps run hourly — an archive older than 12h means the backup
# pipeline is broken even if the file itself is valid (project backup is exempt:
# it's only created when site files change).
if [[ -n "$DB_BACKUP" && "$LOCAL_DB_OK" -eq 1 ]]; then
    DB_AGE_H=$((($(date +%s) - $(stat -c %Y "$DB_BACKUP")) / 3600))
    if [[ "$DB_AGE_H" -ge 12 ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✗ DB backup STALE (${DB_AGE_H}h): $(basename "$DB_BACKUP")" >>"$LOG_FILE"
        ALERTS+="❌ DB backup stale (${DB_AGE_H}h): $(basename "$DB_BACKUP")
"
        LOCAL_DB_OK=0
    fi
fi

# A missing project backup is only a failure when the pipeline is actually
# broken — i.e. the DB backup is stale/missing too (DB dumps run every hour,
# project archives only on change).
if [[ "$PROJ_MISSING" -eq 1 ]]; then
    if [[ "$LOCAL_DB_OK" -eq 1 ]]; then
        LOCAL_PROJ_OK=1
    else
        ALERTS+="❌ No project backup found in $BACKUP_DIR/project
"
    fi
fi

export_metric "backup_verification_ok{type=\"local\",instance=\"$DOMAIN\"} $((LOCAL_PROJ_OK && LOCAL_DB_OK))"

# ==== Verify cloud backups (if rclone configured) ====
if [[ -f ~/.config/rclone/rclone.conf ]]; then
    ENV=$(detect_env)
    PROJ_CLOUD_PATH="${RCLONE_REMOTE:-gdrive-crypt}:DreamSeed/backups/project${ENV}"
    DB_CLOUD_PATH="${RCLONE_REMOTE:-gdrive-crypt}:DreamSeed/backups/db${ENV}"

    # rclone exit code is captured so a failed listing is reported as an
    # error, not silently mistaken for "genuinely zero cloud backups"
    # (same pattern as send_report.sh — M9).
    _rclone_err=0
    PROJ_CLOUD_COUNT=$(rclone lsf "$PROJ_CLOUD_PATH" 2>/dev/null | wc -l) || _rclone_err=1
    DB_CLOUD_COUNT=$(rclone lsf "$DB_CLOUD_PATH" 2>/dev/null | wc -l) || _rclone_err=1

    # Fallback to plain gdrive if crypt remote has no files (transition period)
    if [[ "$_rclone_err" -eq 0 && "$PROJ_CLOUD_COUNT" -eq 0 && "$DB_CLOUD_COUNT" -eq 0 ]]; then
        PROJ_CLOUD_COUNT=$(rclone lsf "gdrive:DreamSeed/backups/project${ENV}" 2>/dev/null | wc -l) || _rclone_err=1
        DB_CLOUD_COUNT=$(rclone lsf "gdrive:DreamSeed/backups/db${ENV}" 2>/dev/null | wc -l) || _rclone_err=1
    fi

    if [[ "$_rclone_err" -eq 1 ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✗ Cloud backup listing failed (rclone error)" >>"$LOG_FILE"
        ALERTS+="❌ Cloud backup listing failed (rclone error)
"
        CLOUD_OK=0
    elif [[ "$PROJ_CLOUD_COUNT" -gt 0 && "$DB_CLOUD_COUNT" -gt 0 ]]; then
        # Cloud-side freshness: count > 0 can hide a stalled upload pipeline,
        # mirroring the local DB 12h check above.
        DB_CLOUD_NEWEST=$(rclone lsf "$DB_CLOUD_PATH" --format t 2>/dev/null | sort | tail -1)
        [[ -z "$DB_CLOUD_NEWEST" ]] && DB_CLOUD_NEWEST=$(rclone lsf "gdrive:DreamSeed/backups/db${ENV}" --format t 2>/dev/null | sort | tail -1)
        DB_CLOUD_AGE=0
        if [ -n "$DB_CLOUD_NEWEST" ]; then
            _ts=$(date -d "$DB_CLOUD_NEWEST" +%s 2>/dev/null || echo "$(date +%s)")
            DB_CLOUD_AGE=$((($(date +%s) - _ts) / 3600))
        fi
        if [[ "$DB_CLOUD_AGE" -ge 12 ]]; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✗ Cloud DB backup STALE (${DB_CLOUD_AGE}h): $DB_CLOUD_NEWEST" >>"$LOG_FILE"
            ALERTS+="❌ Cloud DB backup stale (${DB_CLOUD_AGE}h): $DB_CLOUD_NEWEST
"
            CLOUD_OK=0
        else
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✓ Cloud backups OK: $PROJ_CLOUD_COUNT project, $DB_CLOUD_COUNT DB (newest ${DB_CLOUD_AGE}h)" >>"$LOG_FILE"
            CLOUD_OK=1
        fi
    else
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✗ Cloud backups MISSING: project=$PROJ_CLOUD_COUNT, db=$DB_CLOUD_COUNT" >>"$LOG_FILE"
        ALERTS+="❌ Cloud backups missing or empty
"
        CLOUD_OK=0
    fi

    export_metric "backup_verification_ok{type=\"cloud\",instance=\"$DOMAIN\"} $CLOUD_OK"
else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ⏭ Cloud verification skipped (rclone not configured)" >>"$LOG_FILE"
fi

# ==== Send alerts if verification failed ====
if [[ -n "$ALERTS" ]]; then
    MSG="====== ALERT ======
🔴 <b>BACKUP VERIFICATION FAILED</b> — $DOMAIN

$ALERTS
⏰ $(date '+%d.%m.%Y %H:%M')
=========================="
    send_tg "$MSG" || true
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Alert sent to Telegram" >>"$LOG_FILE"
else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✅ All verifications passed" >>"$LOG_FILE"
    if [[ -n "${BETTERUPTIME_VERIFY_KEY:-}" ]]; then
        if ping_heartbeat "$BETTERUPTIME_VERIFY_KEY"; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] Heartbeat: ✅ sent" >>"$LOG_FILE"
        fi
    fi
fi

rotate_files "$BACKUP_DIR/logs/verify_*.log" 30

# Honest exit code: cron/Better Stack must see a failed verification, not just
# a Telegram message (matches smart_backup.sh / upload_backups_to_gdrive.sh).
if [[ -n "$ALERTS" ]]; then
    exit 1
fi
exit 0
