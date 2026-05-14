#!/bin/bash

# Path for cron
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# ====== Load shared functions ======
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common_functions.sh"
load_env "$SCRIPT_DIR/.env"

# Parse report type
REPORT_TYPE="${1:-daily}"  # daily or weekly

# ====== Settings ======
BACKUP_DIR="/home/ubuntu/backups"
RCLONE_REMOTE="gdrive"

ENV=$(detect_env)
ENV_DISPLAY=$(format_env_display "$ENV")
REMOTE_BASE="DreamSeed/backups"

# Get counts and files
PROJ_FILES=$(ls -1t "$BACKUP_DIR"/project/DreamSeed_*.tar.gz 2>/dev/null | head -24)
DB_FILES=$(ls -1t "$BACKUP_DIR"/db/db_*.sql.gz 2>/dev/null | head -24)

PROJ_COUNT=$(ls -1 "$BACKUP_DIR"/project/DreamSeed_*.tar.gz 2>/dev/null | wc -l)
DB_COUNT=$(ls -1 "$BACKUP_DIR"/db/db_*.sql.gz 2>/dev/null | wc -l)

CLOUD_PROJ=$(rclone lsf "$RCLONE_REMOTE:$REMOTE_BASE/project${ENV}/" --files-only 2>/dev/null | wc -l | tr -d ' ')
CLOUD_DB=$(rclone lsf "$RCLONE_REMOTE:$REMOTE_BASE/db${ENV}/" --files-only 2>/dev/null | wc -l | tr -d ' ')

LAST_PROJ=$(format_name "$(ls -1t "$BACKUP_DIR"/project/DreamSeed_*.tar.gz 2>/dev/null | head -1)")
LAST_DB=$(format_name "$(ls -1t "$BACKUP_DIR"/db/db_*.sql.gz 2>/dev/null | head -1)")
LAST_GDRIVE_PROJ=$(format_name "$(rclone lsf "$RCLONE_REMOTE:$REMOTE_BASE/project${ENV}/" 2>/dev/null | head -1)")
LAST_GDRIVE_DB=$(format_name "$(rclone lsf "$RCLONE_REMOTE:$REMOTE_BASE/db${ENV}/" 2>/dev/null | head -1)")

# ====== DAILY REPORT ======
if [ "$REPORT_TYPE" = "daily" ]; then
    PROJ_1_SIZE=$(du -h "$(echo "$PROJ_FILES" | head -1)" 2>/dev/null | cut -f1)
    PROJ_2_SIZE=$(du -h "$(echo "$PROJ_FILES" | sed -n '2p')" 2>/dev/null | cut -f1)
    DB_1_SIZE=$(du -h "$(echo "$DB_FILES" | head -1)" 2>/dev/null | cut -f1)
    DB_2_SIZE=$(du -h "$(echo "$DB_FILES" | sed -n '2p')" 2>/dev/null | cut -f1)

    PROJ_1=$(format_name "$(echo "$PROJ_FILES" | head -1)")
    PROJ_2=$(format_name "$(echo "$PROJ_FILES" | sed -n '2p')")
    DB_1=$(format_name "$(echo "$DB_FILES" | head -1)")
    DB_2=$(format_name "$(echo "$DB_FILES" | sed -n '2p')")

    MSG="======= DAILY REPORT ========
📊 ***$(date +%d.%m)*** — $ENV_DISPLAY"

    if [ "$PROJ_COUNT" -ge 24 ]; then
        MSG+="

✅ Project: $PROJ_COUNT/24"
    else
        MSG+="

⚠️ Project: $PROJ_COUNT/24"
    fi
    [ -n "$PROJ_1" ] && MSG+="
🖥 Last: $PROJ_1 ($PROJ_1_SIZE)"

    if [ "$DB_COUNT" -ge 24 ]; then
        MSG+="

✅ DB: $DB_COUNT/24"
    else
        MSG+="

⚠️ DB: $DB_COUNT/24"
    fi
    [ -n "$DB_1" ] && MSG+="
🗄 Last: $DB_1 ($DB_1_SIZE)"
    [ -n "$DB_2" ] && MSG+="
🗄 Last: $DB_2 ($DB_2_SIZE)"

    MSG+="

☁️ GDrive: $CLOUD_PROJ project, $CLOUD_DB db"
    [ -n "$LAST_GDRIVE_PROJ" ] && MSG+="
🖥 Last: $LAST_GDRIVE_PROJ"
    [ -n "$LAST_GDRIVE_DB" ] && MSG+="
🗄 Last: $LAST_GDRIVE_DB"

    MSG+="

📅 $(date '+%d.%m.%Y %H:%M')
============================"

    send_tg "$MSG"

# ====== WEEKLY REPORT ======
elif [ "$REPORT_TYPE" = "weekly" ]; then
    HOURS_168=168

    TOTAL_EXPECTED=$((HOURS_168 * 2))
    TOTAL_ACTUAL=$((PROJ_COUNT + DB_COUNT))
    if [ "$TOTAL_ACTUAL" -ge "$TOTAL_EXPECTED" ]; then
        SUCCESS_RATE="100%"
    else
        SUCCESS_RATE="$((TOTAL_ACTUAL * 100 / TOTAL_EXPECTED))%"
    fi

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

    send_tg "$MSG"

else
    echo "Usage: $0 {daily|weekly}"
    exit 1
fi
