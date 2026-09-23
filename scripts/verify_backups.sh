#!/bin/bash
# Usage: verify_backups.sh [--no-alert]   (or VERIFY_NO_ALERT=1)
#   --no-alert  diagnostic run: suppress Telegram alert + heartbeat ping
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common_functions.sh"
load_env "$SCRIPT_DIR/.env"

BACKUP_DIR="${BACKUP_DIR:-/home/ubuntu/backups}"
DB_NAME="${DB_NAME:-modx_db}"
PROJECT_DIR="${PROJECT_DIR:-/var/www/html}"
DOMAIN="${DOMAIN:-unknown}"

# Diagnostic mode: --no-alert (or VERIFY_NO_ALERT=1) suppresses the Telegram
# alert AND the Better Stack heartbeat ping, so manual/audit runs neither page
# nor disturb the dead-man switch. The exit code still reflects the real result.
NO_ALERT="${VERIFY_NO_ALERT:-false}"
for arg in "$@"; do
    case "$arg" in
    --no-alert) NO_ALERT=true ;;
    *)
        echo "Unknown option: $arg" >&2
        exit 2
        ;;
    esac
done

LOG_FILE="$BACKUP_DIR/logs/verify_$(date +%Y-%m-%d).log"
mkdir -p "$BACKUP_DIR/logs"

log_ts "⏱ Backup verification started"

LOCAL_PROJ_OK=0
LOCAL_DB_OK=0
TILES_MISSING=0
CLOUD_OK=0
ALERTS=""

# ==== Verify local project backup ====
PROJ_BACKUP=$(list_backups "$BACKUP_DIR/project" 'DreamSeed_*.tar.gz' | head -1)
PROJ_MISSING=0

if [[ -n "$PROJ_BACKUP" && -f "$PROJ_BACKUP" ]]; then
    if timeout 300 tar -tzf "$PROJ_BACKUP" >/dev/null 2>&1; then
        log_ts "✓ Project backup OK: $(basename "$PROJ_BACKUP")"
        LOCAL_PROJ_OK=1
    else
        log_ts "✗ Project backup CORRUPTED: $(basename "$PROJ_BACKUP")"
        ALERTS+="❌ Project backup corrupted: $(basename "$PROJ_BACKUP")
"
    fi
else
    # Project archives are only created when site files change (smart_backup.sh),
    # so absence is EXPECTED on low-churn sites. Don't hard-fail here — resolve
    # against DB freshness below (a fresh DB dump proves the pipeline runs).
    PROJ_MISSING=1
    log_ts "⚠ No project backup found (expected when site files unchanged)"
fi

# ==== Verify local map tiles backup (separate artifact) ====
# Only when the site has tiles; absence with no tiles dir is expected.
if [[ -d "$PROJECT_DIR/tiles" ]]; then
    TILES_BACKUP=$(list_backups "$BACKUP_DIR/tiles" 'DreamSeed_tiles_*.tar.gz' | head -1)
    if [[ -n "$TILES_BACKUP" && -f "$TILES_BACKUP" ]]; then
        if timeout 300 tar -tzf "$TILES_BACKUP" >/dev/null 2>&1; then
            log_ts "✓ Tiles backup OK: $(basename "$TILES_BACKUP")"
        else
            log_ts "✗ Tiles backup CORRUPTED: $(basename "$TILES_BACKUP")"
            ALERTS+="❌ Tiles backup corrupted: $(basename "$TILES_BACKUP")
"
        fi
    else
        # The archive appears at the first smart_backup run after deploy, so
        # absence right after a deploy must not alert — resolve like the project
        # backup: a fresh DB dump proves the pipeline runs (see below).
        TILES_MISSING=1
        log_ts "⚠ No tiles backup yet (expected until the next smart_backup run)"
    fi
fi

# ==== Verify local DB backup ====
DB_BACKUP=$(list_backups "$BACKUP_DIR/db" 'db_*.sql.gz' | head -1)

if [[ -n "$DB_BACKUP" && -f "$DB_BACKUP" ]]; then
    if gunzip -t "$DB_BACKUP" >/dev/null 2>&1; then
        sql_head=$(zcat "$DB_BACKUP" 2>/dev/null | head -1000) || true
        if grep -q "CREATE TABLE\|INSERT INTO" <<<"$sql_head" 2>/dev/null; then
            log_ts "✓ DB backup OK: $(basename "$DB_BACKUP")"
            LOCAL_DB_OK=1
        else
            log_ts "✗ DB backup INVALID SQL: $(basename "$DB_BACKUP")"
            ALERTS+="❌ DB backup invalid SQL: $(basename "$DB_BACKUP")
"
        fi
    else
        log_ts "✗ DB backup CORRUPTED: $(basename "$DB_BACKUP")"
        ALERTS+="❌ DB backup corrupted: $(basename "$DB_BACKUP")
"
    fi
else
    log_ts "✗ No DB backup found"
    ALERTS+="❌ No DB backup found in $BACKUP_DIR/db
"
fi

# Freshness: DB dumps run hourly — an archive older than 12h means the backup
# pipeline is broken even if the file itself is valid (project backup is exempt:
# it's only created when site files change).
if [[ -n "$DB_BACKUP" && "$LOCAL_DB_OK" -eq 1 ]]; then
    DB_AGE_H=$((($(date +%s) - $(stat -c %Y "$DB_BACKUP")) / 3600))
    if [[ "$DB_AGE_H" -ge 12 ]]; then
        log_ts "✗ DB backup STALE (${DB_AGE_H}h): $(basename "$DB_BACKUP")"
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

if [[ "$TILES_MISSING" -eq 1 && "$LOCAL_DB_OK" -eq 0 ]]; then
    ALERTS+="❌ Tiles dir present but no tiles backup (and DB backup not fresh — pipeline down)
"
fi

export_metric "backup_verification_ok{type=\"local\",instance=\"$DOMAIN\"} $((LOCAL_PROJ_OK && LOCAL_DB_OK))"

# ==== Verify cloud backups (if rclone configured) ====
if [[ -f ~/.config/rclone/rclone.conf ]]; then
    ENV=$(detect_env)
    PROJ_CLOUD_PATH="${RCLONE_REMOTE:-gdrive-crypt}:DreamSeed/backups/project${ENV}"
    DB_CLOUD_PATH="${RCLONE_REMOTE:-gdrive-crypt}:DreamSeed/backups/db${ENV}"
    TILES_CLOUD_PATH="${RCLONE_REMOTE:-gdrive-crypt}:DreamSeed/backups/tiles${ENV}"

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
        log_ts "✗ Cloud backup listing failed (rclone error)"
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
            log_ts "✗ Cloud DB backup STALE (${DB_CLOUD_AGE}h): $DB_CLOUD_NEWEST"
            ALERTS+="❌ Cloud DB backup stale (${DB_CLOUD_AGE}h): $DB_CLOUD_NEWEST
"
            CLOUD_OK=0
        else
            log_ts "✓ Cloud backups OK: $PROJ_CLOUD_COUNT project, $DB_CLOUD_COUNT DB (newest ${DB_CLOUD_AGE}h)"
            CLOUD_OK=1
        fi
    else
        log_ts "✗ Cloud backups MISSING: project=$PROJ_CLOUD_COUNT, db=$DB_CLOUD_COUNT"
        ALERTS+="❌ Cloud backups missing or empty
"
        CLOUD_OK=0
    fi

    # Cloud tiles (prod-only upload): missing in cloud + mature local archive =
    # broken upload. The 2h guard skips the first-deploy window.
    if [[ -z "$ENV" && -d "$PROJECT_DIR/tiles" ]]; then
        _ltiles=$(list_backups "$BACKUP_DIR/tiles" 'DreamSeed_tiles_*.tar.gz' | head -1)
        _tc_err=0
        TILES_CLOUD_COUNT=$(rclone lsf "$TILES_CLOUD_PATH" --files-only 2>/dev/null | wc -l) || _tc_err=1
        if [[ "$_tc_err" -eq 1 ]]; then
            log_ts "✗ Cloud tiles listing failed (rclone error)"
            ALERTS+="❌ Cloud tiles listing failed (rclone error)
"
            CLOUD_OK=0
        elif [[ -n "$_ltiles" && "${TILES_CLOUD_COUNT:-0}" -eq 0 ]]; then
            _lage=$((($(date +%s) - $(stat -c %Y "$_ltiles")) / 3600))
            if [[ "$_lage" -ge 2 ]]; then
                log_ts "✗ Cloud tiles missing while local archive is ${_lage}h old"
                ALERTS+="❌ Cloud tiles backup missing in the cloud (local archive ${_lage}h old)
"
                CLOUD_OK=0
            else
                log_ts "⚠ Cloud tiles not uploaded yet (local archive ${_lage}h old)"
            fi
        fi
    fi

    export_metric "backup_verification_ok{type=\"cloud\",instance=\"$DOMAIN\"} $CLOUD_OK"
else
    log_ts "⏭ Cloud verification skipped (rclone not configured)"
fi

# ==== Send alerts if verification failed ====
if [[ -n "$ALERTS" ]]; then
    MSG="====== ALERT ======
🔴 <b>BACKUP VERIFICATION FAILED</b> — $DOMAIN

$ALERTS
⏰ $(date '+%d.%m.%Y %H:%M')
=========================="
    if [[ "$NO_ALERT" == "true" ]]; then
        log_ts "⚠ Alerts suppressed (--no-alert) — not paging Telegram"
    else
        send_tg "$MSG" || true
        log_ts "Alert sent to Telegram"
    fi
else
    log_ts "✅ All verifications passed"
    if [[ "$NO_ALERT" != "true" && -n "${BETTERUPTIME_VERIFY_KEY:-}" ]]; then
        if ping_heartbeat "$BETTERUPTIME_VERIFY_KEY"; then
            log_ts "Heartbeat: ✅ sent"
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
