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
BACKUP_DIR="${BACKUP_DIR:-/home/ubuntu/backups}"
RCLONE_REMOTE="gdrive"
LOCAL_PROJ_KEEP=5
LOCAL_DB_KEEP=15

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

LAST_GDRIVE_PROJ=$(format_name "$(rclone lsf "$RCLONE_REMOTE:$REMOTE_BASE/project${ENV}/" 2>/dev/null | head -1)")
LAST_GDRIVE_DB=$(format_name "$(rclone lsf "$RCLONE_REMOTE:$REMOTE_BASE/db${ENV}/" 2>/dev/null | head -1)")

send_html() {
    local msg="$1"
    local thread_arg=()
    [[ -n "$TG_THREAD_ID" ]] && thread_arg=(-d "message_thread_id=$TG_THREAD_ID")
    curl -s -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
         -d chat_id="$TG_CHAT_ID" \
         "${thread_arg[@]}" \
         -d parse_mode="HTML" \
         -d text="$msg"
}

# ====== DAILY REPORT ======
if [ "$REPORT_TYPE" = "daily" ]; then
    PROJ_1_SIZE=$(du -h "$(echo "$PROJ_FILES" | head -1)" 2>/dev/null | cut -f1)
    DB_1_SIZE=$(du -h "$(echo "$DB_FILES" | head -1)" 2>/dev/null | cut -f1)
    DB_2_SIZE=$(du -h "$(echo "$DB_FILES" | sed -n '2p')" 2>/dev/null | cut -f1)

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

    send_html "$MSG"

# ====== WEEKLY REPORT ======
elif [ "$REPORT_TYPE" = "weekly" ]; then
    # Expected GDrive uploads in a week: 7 days x 2 types = 14
    WEEKLY_EXPECTED=14
    TOTAL_CLOUD=$((CLOUD_PROJ + CLOUD_DB))

    if [ "$TOTAL_CLOUD" -ge "$WEEKLY_EXPECTED" ]; then
        SUCCESS_RATE="100%"
    else
        SUCCESS_RATE="$((TOTAL_CLOUD * 100 / WEEKLY_EXPECTED))%"
    fi

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

🎯 Cloud upload rate: $SUCCESS_RATE
$(date '+%d.%m.%Y %H:%M')"

    send_html "$MSG"

else
    echo "Usage: $0 {daily|weekly}"
    exit 1
fi
