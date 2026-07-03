#!/bin/bash
set -euo pipefail

# Ensure HOME is set for temp directories
export HOME="${HOME:?ERROR: HOME environment variable not set}"

# ====== Prevent concurrent executions ======
LOCK_DIR="${HOME:-/tmp}/.locks"
mkdir -p "$LOCK_DIR" && chmod 700 "$LOCK_DIR"
LOCK_FILE="$LOCK_DIR/restore_all.lock"
exec 9>"$LOCK_FILE"
if ! flock -n -x 9; then
    echo "ERROR: Restore already in progress ($LOCK_FILE)"
    exit 1
fi

# ====== Load shared functions ======
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common_functions.sh
source "$SCRIPT_DIR/common_functions.sh"
load_env "$SCRIPT_DIR/.env"
MODX_TABLE_PREFIX="${MODX_TABLE_PREFIX:-modx_}"
MODX_TABLE_PREFIX="${MODX_TABLE_PREFIX,,}"

if ! [[ "$MODX_TABLE_PREFIX" =~ ^[a-z0-9_]+$ ]]; then
    echo "ERROR: MODX_TABLE_PREFIX contains invalid characters or uppercase letters: '$MODX_TABLE_PREFIX'"
    exit 1
fi

# ====== Validate required env vars ======
: "${DB_NAME:?ERROR: DB_NAME not set in .env or environment}"
if ! [[ "$DB_NAME" =~ ^[A-Za-z0-9_]+$ ]]; then
    echo "ERROR: DB_NAME contains invalid characters: '$DB_NAME'"
    exit 1
fi
: "${DOMAIN:?ERROR: DOMAIN not set in .env or environment}"

# Setup restore log
RESTORE_LOG="/home/ubuntu/backups/restore_$(date +%Y%m%d_%H%M%S).log"
mkdir -p "$(dirname "$RESTORE_LOG")"
{
    echo "=== RESTORE STARTED ==="
    echo "Time: $(date)"
    echo "Mode: $1"
    echo "User: $USER"
    echo "Host: $(hostname)"
} >> "$RESTORE_LOG"

# Parse mode
MODE="${1:-interactive}"  # interactive or --auto-latest

# ====== Settings ======
: "${RCLONE_REMOTE:=gdrive}"
: "${REMOTE_BASE:=DreamSeed/backups}"

if systemctl is-active --quiet nginx 2>/dev/null; then
    WEB_SERVICE="nginx"
else
    WEB_SERVICE="apache2"
fi

PHP_FPM=$(systemctl list-units --type=service --state=running 2>/dev/null \
    | grep -oP 'php[\d.]+-fpm' | head -1 || echo "php-fpm")

if [ "$WEB_SERVICE" = "nginx" ]; then
    SITE_DOMAIN=$(grep -rh "server_name" /etc/nginx/sites-enabled/ 2>/dev/null \
        | grep -v "server_name _" | awk '{print $2}' | tr -d ';' | head -1 || true)
else
    SITE_DOMAIN=$(grep -rh "ServerName" /etc/apache2/sites-enabled/ 2>/dev/null \
        | awk '{print $2}' | head -1 || true)
fi
SITE_URL="https://${SITE_DOMAIN:-localhost}"

PROJECT_DIR="${PROJECT_DIR:-/var/www/html}"
PROJECT_DIR="$(realpath "$PROJECT_DIR" 2>/dev/null || echo "$PROJECT_DIR")"
BACKUP_DIR="${BACKUP_DIR:-/home/ubuntu/backups}"

ENV=$(detect_env)
ENV_DISPLAY=$(format_env_display "$ENV")

START_TIME=$(date +%s)

SERVICES_STOPPED=0
RESTORE_TEMP_DIRS=()

cleanup_trap() {
    rm -f "$LOCK_FILE"
    exec 9>&-
    for _d in "${RESTORE_TEMP_DIRS[@]:-}"; do
        rm -rf "$_d" 2>/dev/null || true
    done
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
    local dir="$1"
    local pattern="$2"

    local files=()
    while IFS= read -r f; do files+=("$f"); done < <(find "$dir" -maxdepth 1 -name "$pattern" -printf '%T@ %p\n' 2>/dev/null | sort -rn | cut -d' ' -f2-)

    if [ ${#files[@]} -eq 0 ]; then
        echo -e "${RED}No backups found in $dir${NC}" >&2
        return 1
    fi

    echo -e "${YELLOW}Available backups:${NC}" >&2
    echo "" >&2
    for i in "${!files[@]}"; do
        SIZE=$(du -h "${files[$i]}" | cut -f1)
        echo -e "  ${GREEN}$((i+1))${NC}. $(basename "${files[$i]}")  ${CYAN}[$SIZE]${NC}" >&2
    done
    echo "" >&2

    local choice
    read -r -p "Select number (Enter = skip): " choice >&2
    echo "" >&2

    if [ -z "$choice" ]; then
        echo -e "${YELLOW}Skipped.${NC}" >&2
        return 0
    fi

    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#files[@]}" ]; then
        local selected="${files[$((choice-1))]}"
        echo -e "${GREEN}Selected:${NC} $(basename "$selected")" >&2
        echo "$selected"
        return 0
    else
        echo -e "${RED}Invalid selection!${NC}" >&2
        return 1
    fi
}

select_backup_cloud() {
    local remote_path="$1"
    local pattern="$2"

    local files=()
    while IFS= read -r f; do files+=("$f"); done < <(rclone lsf "$RCLONE_REMOTE:$REMOTE_BASE/$remote_path/" --files-only --format tps 2>/dev/null | grep "$pattern" | sort -t';' -k1 -r || true)

    if [ ${#files[@]} -eq 0 ]; then
        echo -e "${RED}No backups found on GDrive ($remote_path)${NC}" >&2
        return 1
    fi

    echo -e "${YELLOW}Available backups (GDrive):${NC}" >&2
    echo "" >&2
    for i in "${!files[@]}"; do
        local line="${files[$i]}"
        local name="${line#*;}"
        name="${name%;*}"
        local size="${line##*;}"
        local size_str=""
        if [ "$size" -gt 1048576 ]; then
            size_str="$((size / 1048576))MB"
        else
            size_str="$((size / 1024))KB"
        fi
        echo -e "  ${GREEN}$((i+1))${NC}. $(basename "$name")  ${CYAN}[$size_str]${NC}" >&2
    done
    echo "" >&2

    local choice
    read -r -p "Select number (Enter = skip): " choice >&2
    echo "" >&2

    if [ -z "$choice" ]; then
        echo -e "${YELLOW}Skipped.${NC}" >&2
        return 0
    fi

    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#files[@]}" ]; then
        local line="${files[$((choice-1))]}"
        local selected_name="${line#*;}"
        selected_name="${selected_name%;*}"
        echo -e "${GREEN}Selected:${NC} $(basename "$selected_name")" >&2
        echo -e "${YELLOW}Downloading...${NC}" >&2
        local temp_dir; temp_dir=$(mktemp -d "${HOME:?}/.tmp_restore_XXXXXX")
        rclone copy "$RCLONE_REMOTE:$REMOTE_BASE/$remote_path/$(basename "$selected_name")" "$temp_dir/" 2>&1
        local temp_file="$temp_dir/$(basename "$selected_name")"
        if [ -f "$temp_file" ]; then
            echo -e "${GREEN}✓ Downloaded to $temp_file${NC}" >&2
            echo "$temp_file"
            return 0
        else
            echo -e "${RED}✗ Download failed!${NC}" >&2
            return 1
        fi
    else
        echo -e "${RED}Invalid selection!${NC}" >&2
        return 1
    fi
}

# ====== INTERACTIVE MODE ======
if [ "$MODE" != "--auto-latest" ]; then
    # ====== Header ======
    print_header "Restore DreamSeed"

    # ================================================
    # STEP 0: Choose source (local or cloud)
    # ================================================
    echo -e "${YELLOW}Source:${NC}"
    echo ""
    echo -e "  ${GREEN}1${NC}) Local backups"
    echo -e "  ${GREEN}2${NC}) GDrive (cloud)"
    echo ""
    read -r -p "Your choice: " SOURCE_CHOICE
    echo ""
    case "$SOURCE_CHOICE" in
        1) SOURCE="local" ;;
        2) SOURCE="cloud" ;;
        *) echo -e "${YELLOW}Default: local${NC}"; SOURCE="local"; echo "" ;;
    esac

    # DESIGN: ENV_SUFFIX is intentionally empty — interactive restore always
    # browses prod cloud paths (DreamSeed/backups/project/ and db/).
    # Dev environments have no independent backup pipeline; they are ephemeral
    # copies of prod. Dev cloud uploads go to *-dev/ paths but are never
    # consumed by any restore flow. See detect_env() in common_functions.sh.
    ENV_SUFFIX=""

    # ================================================
    # STEP 1: What to restore?
    # ================================================
    show_menu
    read -r -p "Your choice: " MENU_CHOICE
    echo ""

    SELECTED_PROJECT=""
    SELECTED_DB=""
    SELECTED_REDIS=""

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
        if [ "$SOURCE" = "cloud" ]; then
            SELECTED_PROJECT=$(select_backup_cloud "project${ENV_SUFFIX}" "DreamSeed_") || exit 1
        else
            SELECTED_PROJECT=$(select_backup "$BACKUP_DIR/project" "*.tar.gz") || exit 1
        fi
    fi

    if [ "$RESTORE_DB" -eq 1 ]; then
        if [ "$SOURCE" = "cloud" ]; then
            SELECTED_DB=$(select_backup_cloud "db${ENV_SUFFIX}" "db_") || exit 1
        else
            SELECTED_DB=$(select_backup "$BACKUP_DIR/db" "*.sql.gz") || exit 1
        fi
    fi

    # Try to select Redis backup if "all" was chosen (optional — doesn't fail if not found)
    if [[ "$RESTORE_PROJECT" -eq 1 && "$RESTORE_DB" -eq 1 ]]; then
        if [ "$SOURCE" = "cloud" ]; then
            SELECTED_REDIS=$(select_backup_cloud "redis${ENV_SUFFIX}" "redis_dump_" 2>/dev/null) || SELECTED_REDIS=""
        else
            SELECTED_REDIS=$(select_backup "$BACKUP_DIR/redis" "*.rdb" 2>/dev/null) || SELECTED_REDIS=""
        fi
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
    [ -n "$SELECTED_REDIS" ]   && echo -e "  - Restore Redis sessions: ${CYAN}$(basename "$SELECTED_REDIS")${NC}"
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

    SELECTED_PROJECT=$(find "$BACKUP_DIR/project" -maxdepth 1 -name 'DreamSeed_*.tar.gz' -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
    SELECTED_DB=$(find "$BACKUP_DIR/db" -maxdepth 1 -name 'db_*.sql.gz' -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
    SELECTED_REDIS=$(find "$BACKUP_DIR/redis" -maxdepth 1 -name 'redis_dump_*.rdb' -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)

    if [ -z "$SELECTED_PROJECT" ] || [ -z "$SELECTED_DB" ]; then
        echo "Local backups not found, trying Google Drive..."
        mkdir -p "$BACKUP_DIR/project" "$BACKUP_DIR/db"

        # IMPORTANT: Auto-latest mode ALWAYS restores from PROD backups, regardless of environment.
        # Dev servers MUST use prod data. This is intentional — dev has no separate backup pipeline.
        # Interactive mode keeps ENV_SUFFIX="" for the same reason (line 222).
        # Do not add ENV_SUFFIX here. See detect_env() in common_functions.sh for design rationale.
        rclone copy "$RCLONE_REMOTE:$REMOTE_BASE/project/" "$BACKUP_DIR/project/" \
            --include "DreamSeed_*.tar.gz" --ignore-existing -v 2>&1 | tail -3
        rclone copy "$RCLONE_REMOTE:$REMOTE_BASE/db/" "$BACKUP_DIR/db/" \
            --include "db_*.sql.gz" --ignore-existing -v 2>&1 | tail -3
        rclone copy "$RCLONE_REMOTE:$REMOTE_BASE/redis/" "$BACKUP_DIR/redis/" \
            --include "redis_dump_*.rdb" --ignore-existing -v 2>&1 | tail -3

        SELECTED_PROJECT=$(find "$BACKUP_DIR/project" -maxdepth 1 -name 'DreamSeed_*.tar.gz' -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
        SELECTED_DB=$(find "$BACKUP_DIR/db" -maxdepth 1 -name 'db_*.sql.gz' -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
        SELECTED_REDIS=$(find "$BACKUP_DIR/redis" -maxdepth 1 -name 'redis_dump_*.rdb' -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
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
    [ -n "$SELECTED_REDIS" ] && echo "Redis: $(basename "$SELECTED_REDIS")"
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
    if ! timeout 300 sudo tar -tzf "$SELECTED_PROJECT" >/dev/null 2>&1; then
        echo -e "${RED}✗ Project archive corrupted: $(basename "$SELECTED_PROJECT")${NC}"
        exit 1
    fi
    echo -e "${GREEN}✓ Project archive: OK${NC}"
fi
if [ -n "$SELECTED_DB" ]; then
    if ! timeout 300 gunzip -t "$SELECTED_DB" 2>/dev/null; then
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
# STEP 5.5: Backup current state (emergency snapshot)
# ================================================
if [ "$MODE" = "interactive" ]; then
    echo -e "${YELLOW}[1.5] Backing up current state...${NC}"
else
    echo "Backing up current state..."
fi

PRE_RESTORE_BACKUP_DIR=$(mktemp -d "${HOME:?}/.tmp_pre_restore_XXXXXX")
RESTORE_TEMP_DIRS+=("$PRE_RESTORE_BACKUP_DIR")

if [ -n "$SELECTED_DB" ]; then
    BACKUP_DB_FILE="$PRE_RESTORE_BACKUP_DIR/db_snapshot.sql.gz"
    if mysqldump --single-transaction "$DB_NAME" 2>/dev/null | gzip > "$BACKUP_DB_FILE"; then
        echo -e "${GREEN}✓ Database snapshot: $(du -h "$BACKUP_DB_FILE" | cut -f1)${NC}"
    else
        rm -f "$BACKUP_DB_FILE"
        echo -e "${YELLOW}⚠️  Database snapshot failed (continuing)${NC}"
    fi
fi

if [ -n "$SELECTED_PROJECT" ]; then
    BACKUP_PROJ_FILE="$PRE_RESTORE_BACKUP_DIR/project_snapshot.tar.gz"
    if sudo tar -czf "$BACKUP_PROJ_FILE" -C /var/www . 2>/dev/null; then
        echo -e "${GREEN}✓ Project snapshot: $(du -h "$BACKUP_PROJ_FILE" | cut -f1)${NC}"
    else
        echo -e "${YELLOW}⚠️  Project snapshot failed (continuing)${NC}"
    fi
fi

echo -e "${CYAN}Emergency snapshot saved to: $PRE_RESTORE_BACKUP_DIR${NC}"
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

    TEMP_EXTRACT=$(mktemp -d "${HOME:?}/.tmp_restore_XXXXXX")
    if timeout 1800 sudo tar -xzf "$SELECTED_PROJECT" -C "$TEMP_EXTRACT"; then
        [[ "$PROJECT_DIR" =~ ^/var/www/.+$ ]] || { echo "ERROR: PROJECT_DIR must be under /var/www/, got: $PROJECT_DIR"; exit 1; }
        extracted_dir="$TEMP_EXTRACT/$(basename "$PROJECT_DIR")"
        if [[ ! -d "$extracted_dir" ]]; then
            echo -e "${RED}✗ Archive structure mismatch: expected '$extracted_dir' not found${NC}"
            sudo rm -rf "$TEMP_EXTRACT"
            PROJECT_STATUS="❌ Archive structure error"
            echo -e "${RED}✗ Project restore failed!${NC}"
        else
            sudo mv "$PROJECT_DIR" "${PROJECT_DIR}.bak.$$" 2>/dev/null || true
            sudo mv "$extracted_dir" "$PROJECT_DIR" || {
                sudo mv "${PROJECT_DIR}.bak.$$" "$PROJECT_DIR" 2>/dev/null || true
                sudo rm -rf "$TEMP_EXTRACT"
                PROJECT_STATUS="❌ Move failed"
                echo "ERROR: Failed to move restored project"
                exit 1
            }
            sudo rm -rf "${PROJECT_DIR}.bak.$$" 2>/dev/null || true
            sudo rm -rf "$TEMP_EXTRACT"
            sudo mkdir -p "$PROJECT_DIR/core/xpdo/cache"
            sudo chown -R www-data:www-data "$PROJECT_DIR"
            PROJECT_STATUS="✅ $(basename "$SELECTED_PROJECT")"
            echo -e "${GREEN}✓ Project restored${NC}"
        fi
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

    COUNT_BEFORE=$(mysql "$DB_NAME" -se "SELECT COUNT(*) FROM ${MODX_TABLE_PREFIX}site_content;" 2>/dev/null || echo "0")
    LAST_EDIT_BEFORE=$(mysql "$DB_NAME" -se "SELECT FROM_UNIXTIME(MAX(editedon)) FROM ${MODX_TABLE_PREFIX}site_content;" 2>/dev/null || true)

    TEMP_SQL=$(mktemp "${HOME:?}/.tmp_restore_XXXXXX")
    if ! timeout 300 gunzip -c "$SELECTED_DB" > "$TEMP_SQL"; then
        rm -f "$TEMP_SQL"
        DB_STATUS="❌ Decompression error"
        echo -e "${RED}✗ Failed to decompress archive!${NC}"
    else
        if timeout 1800 mysql "$DB_NAME" < "$TEMP_SQL"; then
            mysql "$DB_NAME" -e "TRUNCATE TABLE ${MODX_TABLE_PREFIX}session;" 2>/dev/null

            COUNT_AFTER=$(mysql "$DB_NAME" -se "SELECT COUNT(*) FROM ${MODX_TABLE_PREFIX}site_content;" 2>/dev/null || echo "0")
            LAST_EDIT_AFTER=$(mysql "$DB_NAME" -se "SELECT FROM_UNIXTIME(MAX(editedon)) FROM ${MODX_TABLE_PREFIX}site_content;" 2>/dev/null)

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
# STEP 7: Restore Redis (if available)
# ================================================
REDIS_STATUS="⏭️ Skipped"

if [[ "$RESTORE_PROJECT" -eq 1 && "$RESTORE_DB" -eq 1 ]] && [[ -f "$SELECTED_REDIS" ]]; then
    if [ "$MODE" = "interactive" ]; then
        echo -e "${YELLOW}[4] Restoring Redis sessions...${NC}"
    else
        echo "Restoring Redis..."
    fi

    if sudo cp "$SELECTED_REDIS" /var/lib/redis/dump.rdb 2>/dev/null && \
       sudo chown redis:redis /var/lib/redis/dump.rdb 2>/dev/null && \
       sudo systemctl restart redis-server 2>/dev/null; then
        REDIS_STATUS="✅ $(basename "$SELECTED_REDIS")"
        echo -e "${GREEN}✓ Redis restored${NC}"
    else
        REDIS_STATUS="❌ Error"
        echo -e "${RED}✗ Redis restore failed!${NC}"
    fi
fi
echo ""

# ================================================
# STEP 8: Clear cache and permissions
# ================================================
if [ "$MODE" = "interactive" ]; then
    echo -e "${YELLOW}[5] Clearing cache and setting permissions...${NC}"
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
    echo -e "${YELLOW}[6] Starting services...${NC}"
else
    echo "Starting services..."
fi

SITE_STATUS="⏭️ Not checked"
RESTORE_RESULT=${RESTORE_RESULT:-0}

if sudo systemctl start "$PHP_FPM" "$WEB_SERVICE" 2>&1; then
    SERVICES_STOPPED=0
    echo -e "${GREEN}✓ Services started${NC}"
else
    echo -e "${RED}✗ Failed to start services${NC}"
    SITE_STATUS="❌ Services failed to start"
    RESTORE_RESULT=1
fi
sleep 3

HTTP_CODE=$(curl -sk "$SITE_URL" -o /dev/null -w "%{http_code}") || HTTP_CODE="000"
if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "301" ]; then
    SITE_STATUS="✅ HTTP $HTTP_CODE"
    echo -e "${GREEN}✓ Site is up (HTTP $HTTP_CODE)${NC}"
else
    SITE_STATUS="❌ HTTP $HTTP_CODE"
    echo -e "${RED}✗ Site returned HTTP $HTTP_CODE${NC}"
    RESTORE_RESULT=1
fi
echo ""

# ================================================
# Summary
# ================================================
ELAPSED=$(( $(date +%s) - START_TIME ))

ELAPSED_DISPLAY="Time: ${ELAPSED}s"
echo ""
echo "Project: $PROJECT_STATUS"
echo "DB: $DB_STATUS"
echo "Redis: $REDIS_STATUS"
echo "Site: $SITE_STATUS"
echo "$ELAPSED_DISPLAY"

if [ "$MODE" = "interactive" ]; then
    print_header "Restore complete (${ELAPSED}s)"
fi

if [ "${RESTORE_RESULT:-0}" -eq 1 ]; then
    MSG="❌ <b>[$ENV_DISPLAY] DreamSeed Restore FAILED</b>"
else
    MSG="✅ <b>[$ENV_DISPLAY] DreamSeed Restore</b>"
fi

MSG="$MSG

📝 <b>Project:</b> $PROJECT_STATUS
🗄️ <b>DB:</b> $DB_STATUS
🌐 <b>Site:</b> $SITE_STATUS
⏱️ <b>Time:</b> <code>${ELAPSED}</code>s"

if [[ "$DB_STATUS" == *"Rollback"* ]]; then
    MSG="$MSG

⚠️ <b>Data rollback — verify carefully!</b>"
fi

send_tg "$MSG"
exit "${RESTORE_RESULT:-0}"
