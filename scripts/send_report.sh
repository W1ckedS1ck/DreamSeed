#!/bin/bash
set -euo pipefail

# Validate required commands
for cmd in find rclone du cut date grep printf; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: '$cmd' not found in PATH"; exit 1; }
done

# Path for cron
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# ====== Load shared functions ======
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common_functions.sh
source "$SCRIPT_DIR/common_functions.sh"
load_env "$SCRIPT_DIR/.env"

# Parse report type
REPORT_TYPE="${1:-daily}"  # daily or weekly

# ====== Settings ======
BACKUP_DIR="${BACKUP_DIR:-/home/ubuntu/backups}"
RCLONE_REMOTE="gdrive"
LOCAL_PROJ_KEEP="${BACKUP_PROJECT_KEEP:-5}"
LOCAL_DB_KEEP="${BACKUP_DB_KEEP:-15}"

ENV=$(detect_env)
ENV_DISPLAY=$(format_env_display "$ENV")
REMOTE_BASE="DreamSeed/backups"

# Get counts and files
PROJ_FILES=$(find "$BACKUP_DIR/project" -maxdepth 1 -name 'DreamSeed_*.tar.gz' -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -24 | cut -d' ' -f2-)
DB_FILES=$(find "$BACKUP_DIR/db" -maxdepth 1 -name 'db_*.sql.gz' -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -24 | cut -d' ' -f2-)

PROJ_COUNT=$(find "$BACKUP_DIR/project" -maxdepth 1 -name 'DreamSeed_*.tar.gz' 2>/dev/null | wc -l)
DB_COUNT=$(find "$BACKUP_DIR/db" -maxdepth 1 -name 'db_*.sql.gz' 2>/dev/null | wc -l)

_proj_list=$(rclone lsf "$RCLONE_REMOTE:$REMOTE_BASE/project${ENV}/" --files-only 2>/dev/null | sort)
_db_list=$(rclone lsf "$RCLONE_REMOTE:$REMOTE_BASE/db${ENV}/" --files-only 2>/dev/null | sort)
CLOUD_PROJ=$(printf '%s' "$_proj_list" | grep -c '.' || true)
CLOUD_DB=$(printf '%s' "$_db_list" | grep -c '.' || true)
LAST_GDRIVE_PROJ=$(format_name "$(printf '%s' "$_proj_list" | tail -1)")
LAST_GDRIVE_DB=$(format_name "$(printf '%s' "$_db_list" | tail -1)")

# ====== DAILY REPORT ======
if [ "$REPORT_TYPE" = "daily" ]; then
    _du_out=$(du -h "$(echo "$PROJ_FILES" | head -1)" 2>/dev/null) && PROJ_1_SIZE=$(echo "$_du_out" | cut -f1) || PROJ_1_SIZE="ERROR"
    _du_out=$(du -h "$(echo "$DB_FILES" | head -1)" 2>/dev/null) && DB_1_SIZE=$(echo "$_du_out" | cut -f1) || DB_1_SIZE="ERROR"
    _du_out=$(du -h "$(echo "$DB_FILES" | sed -n '2p')" 2>/dev/null) && DB_2_SIZE=$(echo "$_du_out" | cut -f1) || DB_2_SIZE="ERROR"

    PROJ_1=$(format_name "$(echo "$PROJ_FILES" | head -1)")
    DB_1=$(format_name "$(echo "$DB_FILES" | head -1)")
    DB_2=$(format_name "$(echo "$DB_FILES" | sed -n '2p')")

    MSG="<b>DAILY REPORT</b>
$(date +%d.%m) - $ENV_DISPLAY"

    if [ "$PROJ_COUNT" -ge 1 ]; then
        MSG+="

✅ Project: $PROJ_COUNT / $LOCAL_PROJ_KEEP"
    else
        MSG+="

⚠️ Project: $PROJ_COUNT / $LOCAL_PROJ_KEEP"
    fi
    [ -n "$PROJ_1" ] && MSG+="
- Last: $PROJ_1 ($PROJ_1_SIZE)"

    if [ "$DB_COUNT" -ge 12 ]; then
        MSG+="

✅ DB: $DB_COUNT / $LOCAL_DB_KEEP"
    else
        MSG+="

⚠️ DB: $DB_COUNT / $LOCAL_DB_KEEP"
    fi
    [ -n "$DB_1" ] && MSG+="
- Last: $DB_1 ($DB_1_SIZE)"
    [ -n "$DB_2" ] && MSG+="
- Prev: $DB_2 ($DB_2_SIZE)"

    MSG+="

☁️ GDrive: $CLOUD_PROJ project, $CLOUD_DB db"
    [ -n "$LAST_GDRIVE_PROJ" ] && MSG+="
- Last project: $LAST_GDRIVE_PROJ"
    [ -n "$LAST_GDRIVE_DB" ] && MSG+="
- Last db: $LAST_GDRIVE_DB"

    MSG+="

$(date '+%d.%m.%Y %H:%M')"

    send_tg "$MSG"

# ====== WEEKLY REPORT ======
elif [ "$REPORT_TYPE" = "weekly" ]; then
    MSG="<b>WEEKLY REPORT</b>
$(date -d '-7 days' +%d.%m)-$(date +%d.%m) - $ENV_DISPLAY"

    if [ "$PROJ_COUNT" -ge 1 ]; then
        MSG+="

✅ Local: $PROJ_COUNT project, $DB_COUNT db"
    else
        MSG+="

⚠️ Local: $PROJ_COUNT project, $DB_COUNT db"
    fi

    MSG+="
☁️ GDrive: $CLOUD_PROJ project, $CLOUD_DB db"

    [ -n "$LAST_GDRIVE_PROJ" ] && MSG+="
- Last project: $LAST_GDRIVE_PROJ"
    [ -n "$LAST_GDRIVE_DB" ] && MSG+="
- Last db: $LAST_GDRIVE_DB"

    MSG+="

$(date '+%d.%m.%Y %H:%M')"

    send_tg "$MSG"

else
    echo "Usage: $0 {daily|weekly}"
    exit 1
fi

    _bs_key=""
if [[ "$REPORT_TYPE" == "daily" ]]; then
    _bs_key="${BETTERUPTIME_REPORT_DAILY_KEY:-}"
elif [[ "$REPORT_TYPE" == "weekly" ]]; then
    _bs_key="${BETTERUPTIME_REPORT_WEEKLY_KEY:-}"
fi
ping_heartbeat "$_bs_key" || true
