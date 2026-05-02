#!/bin/bash

# Path for cron
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# ====== Load shared functions ======
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common_functions.sh"
load_env "$SCRIPT_DIR/.env"

# ====== Settings ======
BACKUP_DIR="/home/ubuntu/backups"
RCLONE_REMOTE="gdrive"

HOSTNAME=$(hostname)
case "$HOSTNAME" in
    *-prod|*prod-*)  ENV="" ;;
    *)               ENV="-preprod" ;;
esac
ENV_DISPLAY="${ENV:--preprod}"
REMOTE_BASE="DreamSeed/backups"

HOURS_168=168

PROJ_COUNT=$(ls -1 "$BACKUP_DIR"/project/DreamSeed_*.tar.gz 2>/dev/null | wc -l)
DB_COUNT=$(ls -1 "$BACKUP_DIR"/db/db_*.sql.gz 2>/dev/null | wc -l)

CLOUD_PROJ=$(rclone lsf "$RCLONE_REMOTE:$REMOTE_BASE/project${ENV}/" --files-only 2>/dev/null | wc -l | tr -d ' ')
CLOUD_DB=$(rclone lsf "$RCLONE_REMOTE:$REMOTE_BASE/db${ENV}/" --files-only 2>/dev/null | wc -l | tr -d ' ')

TOTAL_EXPECTED=$((HOURS_168 * 2))
TOTAL_ACTUAL=$((PROJ_COUNT + DB_COUNT))
if [ "$TOTAL_ACTUAL" -ge "$TOTAL_EXPECTED" ]; then
    SUCCESS_RATE="100%"
else
    SUCCESS_RATE="$((TOTAL_ACTUAL * 100 / TOTAL_EXPECTED))%"
fi

format_name() {
    basename "$1" | sed 's/DreamSeed_//; s/db_modx_db_//; s/.tar.gz//; s/.sql.gz//; s/_/ /'
}

LAST_PROJ=$(format_name "$(ls -1t "$BACKUP_DIR"/project/DreamSeed_*.tar.gz 2>/dev/null | head -1)")
LAST_DB=$(format_name "$(ls -1t "$BACKUP_DIR"/db/db_*.sql.gz 2>/dev/null | head -1)")
LAST_GDRIVE_PROJ=$(format_name "$(rclone lsf "$RCLONE_REMOTE:$REMOTE_BASE/project${ENV}/" 2>/dev/null | head -1)")
LAST_GDRIVE_DB=$(format_name "$(rclone lsf "$RCLONE_REMOTE:$REMOTE_BASE/db${ENV}/" 2>/dev/null | head -1)")

WEEK_START=$(date -d "-7 days" +%d.%m)
WEEK_END=$(date +%d.%m)

MSG="====== WEEKLY REPORT =======
📊 ***$(date -d '-7 days' +%d.%m)-$(date +%d.%m)*** — $ENV_DISPLAY"

if [ "$PROJ_COUNT" -ge "$HOURS_168" ]; then
    MSG+="

✅ Project: $PROJ_COUNT/$HOURS_168"
else
    MSG+="

⚠️ Project: $PROJ_COUNT/$HOURS_168"
fi
[ -n "$LAST_PROJ" ] && MSG+="
🖥 Last: $LAST_PROJ"

if [ "$DB_COUNT" -ge "$HOURS_168" ]; then
    MSG+="

✅ DB: $DB_COUNT/$HOURS_168"
else
    MSG+="

⚠️ DB: $DB_COUNT/$HOURS_168"
fi
[ -n "$LAST_DB" ] && MSG+="
🗄 Last: $LAST_DB"

MSG+="

☁️ GDrive: $CLOUD_PROJ project, $CLOUD_DB db"
[ -n "$LAST_GDRIVE_PROJ" ] && MSG+="
🖥 Last: $LAST_GDRIVE_PROJ"
[ -n "$LAST_GDRIVE_DB" ] && MSG+="
🗄 Last: $LAST_GDRIVE_DB"

MSG+="

🎯 Success: $SUCCESS_RATE
📅 $(date '+%d.%m.%Y %H:%M')
============================"

send_tg "$(escape_md2 "$MSG")"