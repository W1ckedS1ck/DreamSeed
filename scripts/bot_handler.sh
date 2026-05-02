#!/bin/bash

# Bot command handler for Telegram
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common_functions.sh"
load_env "$SCRIPT_DIR/.env"

BACKUP_DIR="/home/ubuntu/backups"
RCLONE_REMOTE="gdrive"

HOSTNAME=$(hostname)
case "$HOSTNAME" in
    *-prod|*prod-*)  ENV="" ;;
    *)               ENV="-preprod" ;;
esac
ENV_DISPLAY="${ENV:--preprod}"
REMOTE_BASE="DreamSeed/backups"

get_size() {
    local file="$1"
    [ -z "$file" ] && echo "-"
    local size=$(stat -c %s "$file" 2>/dev/null)
    if [ -n "$size" ] && [ "$size" -gt 0 ]; then
        if [ "$size" -gt 1048576 ]; then
            echo "$((size / 1048576))MB"
        else
            echo "$((size / 1024))KB"
        fi
    else
        echo "-"
    fi
}

case "$1" in
    status)
        # Last backups
        LAST_PROJ=$(ls -1t "$BACKUP_DIR"/project/DreamSeed_*.tar.gz 2>/dev/null | head -1)
        LAST_DB=$(ls -1t "$BACKUP_DIR"/db/db_*.sql.gz 2>/dev/null | head -1)

        PROJ_COUNT=$(ls -1 "$BACKUP_DIR"/project/DreamSeed_*.tar.gz 2>/dev/null | wc -l)
        DB_COUNT=$(ls -1 "$BACKUP_DIR"/db/db_*.sql.gz 2>/dev/null | wc -l)

        CLOUD_PROJ=$(rclone lsf "$RCLONE_REMOTE:$REMOTE_BASE/project${ENV}/" --files-only 2>/dev/null | grep -c '[^[:space:]]' || echo 0)
        CLOUD_DB=$(rclone lsf "$RCLONE_REMOTE:$REMOTE_BASE/db${ENV}/" --files-only 2>/dev/null | grep -c '[^[:space:]]' || echo 0)

        MSG="🖥 *Backup Status* — $ENV_DISPLAY

📁 Local: $PROJ_COUNT project, $DB_COUNT db
☁️ GDrive: $CLOUD_PROJ project, $CLOUD_DB db"

        [ -n "$LAST_PROJ" ] && MSG+="
🖥 Last: $(basename "$LAST_PROJ") ($(get_size "$LAST_PROJ"))"
        [ -n "$LAST_DB" ] && MSG+="
🗄 Last: $(basename "$LAST_DB") ($(get_size "$LAST_DB"))"

        MSG+="
⏰ Last check: $(date '+%d.%m %H:%M')"

        echo "$MSG"
        ;;
    backups)
        MSG="🖥 *Last 5 Projects* — $ENV_DISPLAY

"
        ls -1t "$BACKUP_DIR"/project/DreamSeed_*.tar.gz 2>/dev/null | head -5 | while read f; do
            MSG+="$(basename "$f") ($(get_size "$f"))
"
        done

        MSG+="

🗄 *Last 5 DB* — $ENV_DISPLAY

"
        ls -1t "$BACKUP_DIR"/db/db_*.sql.gz 2>/dev/null | head -5 | while read f; do
            MSG+="$(basename "$f") ($(get_size "$f"))
"
        done

        echo "$MSG"
        ;;
    *)
        echo "Unknown command. Use /status or /backups"
        ;;
esac