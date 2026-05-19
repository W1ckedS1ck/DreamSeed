#!/bin/bash

# ====== Load shared functions ======
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common_functions.sh
source "$SCRIPT_DIR/common_functions.sh"
load_env "$SCRIPT_DIR/.env"

# Parse mode
MODE="${1:-interactive}"  # interactive or --auto-latest

# ====== Settings ======
if systemctl is-active --quiet nginx 2>/dev/null; then
    WEB_SERVICE="nginx"
else
    WEB_SERVICE="apache2"
fi

PHP_FPM=$(systemctl list-units --type=service --state=running 2>/dev/null \
    | grep -oP 'php[\d.]+-fpm' | head -1 || echo "php-fpm")

if [ "$WEB_SERVICE" = "nginx" ]; then
    SITE_DOMAIN=$(grep -rh "server_name" /etc/nginx/sites-enabled/ 2>/dev/null \
        | grep -v "server_name _" | awk '{print $2}' | tr -d ';' | head -1)
else
    SITE_DOMAIN=$(grep -rh "ServerName" /etc/apache2/sites-enabled/ 2>/dev/null \
        | awk '{print $2}' | head -1)
fi
SITE_URL="https://${SITE_DOMAIN:-localhost}"

PROJECT_DIR="/var/www/html"
BACKUP_DIR="/home/ubuntu/backups"

ENV=$(detect_env)
ENV_DISPLAY=$(format_env_display "$ENV")
ENV_DISPLAY_ESCAPED=$(format_env_escaped "$ENV")

START_TIME=$(date +%s)

SERVICES_STOPPED=0
cleanup_trap() {
    if [ "$SERVICES_STOPPED" -eq 1 ]; then
        if [ "$MODE" = "interactive" ]; then
            echo ""
            echo -e "${RED}Interrupted! Restarting services...${NC}"
        else
            echo "Restarting services..."
        fi
        sudo systemctl start "$PHP_FPM" "$WEB_SERVICE" 2>/dev/null || true
    fi
}
trap cleanup_trap EXIT INT TERM

print_header() {
    echo ""
    echo -e "${CYAN}======================================${NC}"
    echo -e "${CYAN}  $1${NC}"
    echo -e "${CYAN}======================================${NC}"
    echo ""
}

show_menu() {
    echo -e "${YELLOW}🎯 What to restore?${NC}"
    echo ""
    echo -e "  ${GREEN}1${NC}) Project files only"
    echo -e "  ${GREEN}2${NC}) Database only"
    echo -e "  ${GREEN}3${NC}) Project + database"
    echo -e "  ${GREEN}4${NC}) Exit"
    echo ""
}

select_backup() {
    local type="$1"
    local dir="$2"
    local pattern="$3"
    local result_var="$4"

    local files=()
    mapfile -t files < <(ls -1t "$dir"/$pattern 2>/dev/null)

    if [ ${#files[@]} -eq 0 ]; then
        echo -e "${RED}No backups found in $dir${NC}"
        return 1
    fi

    echo -e "${YELLOW}Available backups:${NC}"
    echo ""
    for i in "${!files[@]}"; do
        SIZE=$(du -h "${files[$i]}" | cut -f1)
        echo -e "  ${GREEN}$((i+1))${NC}. $(basename "${files[$i]}")  ${CYAN}[$SIZE]${NC}"
    done
    echo ""

    local choice
    read -r -p "Select number (Enter = skip): " choice
    echo ""

    if [ -z "$choice" ]; then
        echo -e "${YELLOW}Skipped.${NC}"
        return 0
    fi

    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#files[@]}" ]; then
        local selected="${files[$((choice-1))]}"
        echo -e "${GREEN}Selected:${NC} $(basename "$selected")"
        declare -g "$result_var"="$selected"
        return 0
    else
        echo -e "${RED}Invalid selection!${NC}"
        return 1
    fi
}

# ====== INTERACTIVE MODE ======
if [ "$MODE" != "--auto-latest" ]; then
    # ====== Header ======
    print_header "Restore DreamSeed"

    # ================================================
    # STEP 1: What to restore?
    # ================================================
    show_menu
    read -r -p "Your choice: " MENU_CHOICE
    echo ""

    case "$MENU_CHOICE" in
        1) RESTORE_PROJECT=1; RESTORE_DB=0 ;;
        2) RESTORE_PROJECT=0; RESTORE_DB=1 ;;
        3) RESTORE_PROJECT=1; RESTORE_DB=1 ;;
        4) echo -e "${YELLOW}Exit.${NC}"; exit 0 ;;
        *) echo -e "${RED}Invalid choice!${NC}"; exit 1 ;;
    esac

    # ================================================
    # STEP 2: Select backup files
    # ================================================
    if [ "$RESTORE_PROJECT" -eq 1 ]; then
        select_backup "project" "$BACKUP_DIR/project" "*.tar.gz" "SELECTED_PROJECT" || exit 1
    fi

    if [ "$RESTORE_DB" -eq 1 ]; then
        select_backup "db" "$BACKUP_DIR/db" "*.sql.gz" "SELECTED_DB" || exit 1
    fi

    echo ""

    # Nothing to restore
    if [ -z "$SELECTED_PROJECT" ] && [ -z "$SELECTED_DB" ]; then
        echo -e "${RED}Nothing selected. Exiting.${NC}"
        exit 0
    fi

    # ================================================
    # STEP 3: Confirmation
    # ================================================
    echo ""
    echo -e "${RED}⚠️  WARNING! The following will be performed:${NC}"
    [ -n "$SELECTED_PROJECT" ] && echo -e "  - Replace project files: ${CYAN}$(basename "$SELECTED_PROJECT")${NC}"
    [ -n "$SELECTED_DB" ]      && echo -e "  - Overwrite database: ${CYAN}$(basename "$SELECTED_DB")${NC}"
    echo -e "  - Stop $WEB_SERVICE and PHP-FPM"
    echo -e "  - Clear MODX cache"
    echo ""
    read -r -p "Continue? (yes/no): " CONFIRM

    if [ "$CONFIRM" != "yes" ]; then
        echo -e "${RED}Aborted.${NC}"
        exit 0
    fi

    echo ""

# ====== AUTO MODE (--auto-latest) ======
else
    RESTORE_PROJECT=1
    RESTORE_DB=1

    SELECTED_PROJECT=$(ls -1t "$BACKUP_DIR/project/DreamSeed_"*.tar.gz 2>/dev/null | head -n1)
    SELECTED_DB=$(ls -1t "$BACKUP_DIR/db/db_"*.sql.gz 2>/dev/null | head -n1)

    if [ -z "$SELECTED_PROJECT" ] || [ -z "$SELECTED_DB" ]; then
        echo "Local backups not found, trying Google Drive..."
        mkdir -p "$BACKUP_DIR/project" "$BACKUP_DIR/db"

        rclone copy "gdrive:DreamSeed/backups/project/" "$BACKUP_DIR/project/" \
            --include "DreamSeed_*.tar.gz" --ignore-existing -v 2>&1 | tail -3
        rclone copy "gdrive:DreamSeed/backups/db/" "$BACKUP_DIR/db/" \
            --include "db_*.sql.gz" --ignore-existing -v 2>&1 | tail -3

        SELECTED_PROJECT=$(ls -1t "$BACKUP_DIR/project/DreamSeed_"*.tar.gz 2>/dev/null | head -n1)
        SELECTED_DB=$(ls -1t "$BACKUP_DIR/db/db_"*.sql.gz 2>/dev/null | head -n1)
    fi

    if [ -z "$SELECTED_PROJECT" ] || [ -z "$SELECTED_DB" ]; then
        echo "ERROR: Latest backups not found (local or GDrive)"
        echo "Project: $SELECTED_PROJECT"
        echo "DB: $SELECTED_DB"
        exit 1
    fi

    echo "Restoring from latest backups..."
    echo "Project: $(basename "$SELECTED_PROJECT")"
    echo "DB: $(basename "$SELECTED_DB")"
    echo ""
fi

# ================================================
# STEP 4: Validate archives
# ================================================
if [ "$MODE" = "interactive" ]; then
    echo -e "${YELLOW}[0] Validating archive integrity...${NC}"
else
    echo "Validating archive integrity..."
fi

if [ -n "$SELECTED_PROJECT" ]; then
    if ! sudo tar -tzf "$SELECTED_PROJECT" >/dev/null 2>&1; then
        echo -e "${RED}✗ Project archive corrupted: $(basename "$SELECTED_PROJECT")${NC}"
        exit 1
    fi
    echo -e "${GREEN}✓ Project archive: OK${NC}"
fi
if [ -n "$SELECTED_DB" ]; then
    if ! gunzip -t "$SELECTED_DB" 2>/dev/null; then
        echo -e "${RED}✗ DB archive corrupted: $(basename "$SELECTED_DB")${NC}"
        exit 1
    fi
    echo -e "${GREEN}✓ DB archive: OK${NC}"
fi
echo ""

# ================================================
# STEP 5: Stop services
# ================================================
if [ "$MODE" = "interactive" ]; then
    echo -e "${YELLOW}[1] Stopping services...${NC}"
else
    echo "Stopping services..."
fi

if ! sudo systemctl stop "$PHP_FPM" "$WEB_SERVICE" 2>/dev/null; then
    echo -e "${RED}✗ Failed to stop services!${NC}"
    exit 1
fi
SERVICES_STOPPED=1
echo -e "${GREEN}✓ Services stopped${NC}"
echo ""

# ================================================
# STEP 6: Restore project
# ================================================
PROJECT_STATUS="⏭️ Skipped"

if [ -n "$SELECTED_PROJECT" ]; then
    if [ "$MODE" = "interactive" ]; then
        echo -e "${YELLOW}[2] Restoring project...${NC}"
    else
        echo "Restoring project..."
    fi

    TEMP_EXTRACT=$(sudo mktemp -d "$(dirname "$PROJECT_DIR")/restore_XXXXXX")
    sudo tar -xzf "$SELECTED_PROJECT" -C "$TEMP_EXTRACT"

    if [ $? -eq 0 ]; then
        sudo rm -rf "$PROJECT_DIR"
        sudo mv "$TEMP_EXTRACT/$(basename "$PROJECT_DIR")" "$PROJECT_DIR"
        sudo rm -rf "$TEMP_EXTRACT"
        sudo mkdir -p "$PROJECT_DIR/core/xpdo/cache"
        sudo chown -R www-data:www-data "$PROJECT_DIR"
        PROJECT_STATUS="✅ $(basename "$SELECTED_PROJECT")"
        echo -e "${GREEN}✓ Project restored${NC}"
    else
        sudo rm -rf "$TEMP_EXTRACT"
        PROJECT_STATUS="❌ Error"
        echo -e "${RED}✗ Project restore failed!${NC}"
    fi
else
    if [ "$MODE" = "interactive" ]; then
        echo -e "${YELLOW}[2] Skipping project restore.${NC}"
    fi
fi
echo ""

# ================================================
# STEP 7: Restore database
# ================================================
DB_STATUS="⏭️ Skipped"

if [ -n "$SELECTED_DB" ]; then
    if [ "$MODE" = "interactive" ]; then
        echo -e "${YELLOW}[3] Restoring database...${NC}"
    else
        echo "Restoring database..."
    fi

    COUNT_BEFORE=$(mysql "$DB_NAME" -se "SELECT COUNT(*) FROM modx_site_content;" 2>/dev/null || echo "0")
    LAST_EDIT_BEFORE=$(mysql "$DB_NAME" -se "SELECT FROM_UNIXTIME(MAX(editedon)) FROM modx_site_content;" 2>/dev/null)

    TEMP_SQL=$(mktemp /tmp/restore_XXXXXX.sql)
    gunzip -c "$SELECTED_DB" > "$TEMP_SQL"

    if [ $? -ne 0 ]; then
        rm -f "$TEMP_SQL"
        DB_STATUS="❌ Decompression error"
        echo -e "${RED}✗ Failed to decompress archive!${NC}"
    else
        mysql "$DB_NAME" < "$TEMP_SQL"

        if [ $? -eq 0 ]; then
            mysql "$DB_NAME" -e "TRUNCATE TABLE modx_session;" 2>/dev/null

            COUNT_AFTER=$(mysql "$DB_NAME" -se "SELECT COUNT(*) FROM modx_site_content;" 2>/dev/null || echo "0")
            LAST_EDIT_AFTER=$(mysql "$DB_NAME" -se "SELECT FROM_UNIXTIME(MAX(editedon)) FROM modx_site_content;" 2>/dev/null)

            DIFF=$((COUNT_AFTER - COUNT_BEFORE))
            DIFF_STR=""
            [ $DIFF -gt 0 ] && DIFF_STR=" (+$DIFF)"
            [ $DIFF -lt 0 ] && DIFF_STR=" ($DIFF)"

            ROLLBACK_STR=""
            if [ -n "$LAST_EDIT_BEFORE" ] && [ "$LAST_EDIT_BEFORE" != "NULL" ] && \
               [ -n "$LAST_EDIT_AFTER" ] && [ "$LAST_EDIT_AFTER" != "NULL" ]; then
                TIMESTAMP_BEFORE=$(date -d "$LAST_EDIT_BEFORE" +%s 2>/dev/null)
                TIMESTAMP_AFTER=$(date -d "$LAST_EDIT_AFTER" +%s 2>/dev/null)
                if [ -n "$TIMESTAMP_BEFORE" ] && [ -n "$TIMESTAMP_AFTER" ]; then
                    TIME_DIFF=$((TIMESTAMP_BEFORE - TIMESTAMP_AFTER))
                    if [ $TIME_DIFF -gt 0 ]; then
                        DAYS=$((TIME_DIFF / 86400))
                        HOURS=$(((TIME_DIFF % 86400) / 3600))
                        if [ $DAYS -gt 0 ]; then
                            ROLLBACK_STR=" ⚠️ Rollback ${DAYS}d ${HOURS}h"
                        elif [ $HOURS -gt 0 ]; then
                            ROLLBACK_STR=" ⚠️ Rollback ${HOURS}h"
                        else
                            ROLLBACK_STR=" ⚠️ Rollback"
                        fi
                        if [ "$MODE" = "interactive" ]; then
                            echo -e "${YELLOW}⚠️  Warning: restored data is older than current!${NC}"
                        fi
                    fi
                fi
            fi

            DB_STATUS="✅ $(basename "$SELECTED_DB")$DIFF_STR$ROLLBACK_STR"
            echo -e "${GREEN}✓ Database restored, sessions cleared${NC}"
        else
            DB_STATUS="❌ Error"
            echo -e "${RED}✗ Database restore failed!${NC}"
        fi

        rm -f "$TEMP_SQL"
    fi
else
    if [ "$MODE" = "interactive" ]; then
        echo -e "${YELLOW}[3] Skipping database restore.${NC}"
    fi
fi
echo ""

# ================================================
# STEP 8: Clear cache and permissions
# ================================================
if [ "$MODE" = "interactive" ]; then
    echo -e "${YELLOW}[4] Clearing cache and setting permissions...${NC}"
else
    echo "Clearing cache..."
fi

sudo mkdir -p "$PROJECT_DIR/core/cache/logs"
sudo rm -rf "$PROJECT_DIR/core/cache"/*
sudo chown -R www-data:www-data "$PROJECT_DIR/core/cache"
sudo chmod -R 775 "$PROJECT_DIR/core/cache"
echo -e "${GREEN}✓ Cache cleared${NC}"
echo ""

# ================================================
# STEP 9: Start services
# ================================================
if [ "$MODE" = "interactive" ]; then
    echo -e "${YELLOW}[5] Starting services...${NC}"
else
    echo "Starting services..."
fi

SERVICES_STOPPED=0
sudo systemctl start "$PHP_FPM" "$WEB_SERVICE" 2>/dev/null
sleep 3

HTTP_CODE=$(curl -sk "$SITE_URL" -o /dev/null -w "%{http_code}")
if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "301" ]; then
    SITE_STATUS="✅ HTTP $HTTP_CODE"
    echo -e "${GREEN}✓ Site is up (HTTP $HTTP_CODE)${NC}"
else
    SITE_STATUS="⚠️ HTTP $HTTP_CODE"
    echo -e "${YELLOW}⚠️  Site returned HTTP $HTTP_CODE${NC}"
fi
echo ""

# ================================================
# Summary
# ================================================
ELAPSED=$(( $(date +%s) - START_TIME ))

if [ "$MODE" = "interactive" ]; then
    print_header "Restore complete (${ELAPSED}s)"
    echo -e "  Project: $PROJECT_STATUS"
    echo -e "  DB:      $DB_STATUS"
    echo -e "  Site:    $SITE_STATUS"
    echo ""
fi

MSG="🔄 *[$ENV_DISPLAY] DreamSeed Restore*

📝 *Project:* $(escape_md2 "$PROJECT_STATUS")
🗄️ *DB:* $(escape_md2 "$DB_STATUS")
🌐 *Site:* $(escape_md2 "$SITE_STATUS")
⏱️ *Time:* \`${ELAPSED}\`s"

if [[ "$DB_STATUS" == *"Rollback"* ]]; then
    MSG="$MSG

⚠️ *Data rollback — verify carefully!*"
fi

send_tg "$MSG"
