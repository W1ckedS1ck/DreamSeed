#!/bin/bash

# ====== Load shared functions ======
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common_functions.sh
source "$SCRIPT_DIR/common_functions.sh"
load_env "$SCRIPT_DIR/.env"

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

# Detect environment from hostname
HOSTNAME=$(hostname)
case "$HOSTNAME" in
    *-prod|*prod-*)  ENV="" ;;
    *)               ENV="-preprod" ;;
esac
ENV_DISPLAY="${ENV:--preprod}"

START_TIME=$(date +%s)

SERVICES_STOPPED=0
cleanup_trap() {
    if [ "$SERVICES_STOPPED" -eq 1 ]; then
        echo ""
        echo -e "${RED}Interrupted! Restarting services...${NC}"
        sudo systemctl start "$PHP_FPM" "$WEB_SERVICE" 2>/dev/null
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
    echo -e "${YELLOW}🎯 Что восстановить?${NC}"
    echo ""
    echo -e "  ${GREEN}1${NC}) Только проект"
    echo -e "  ${GREEN}2${NC}) Только базу данных"
    echo -e "  ${GREEN}3${NC}) Проект + базу данных"
    echo -e "  ${GREEN}4${NC}) Выйти"
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
        echo -e "${RED}Нет резервных копий в $dir${NC}"
        return 1
    fi

    echo -e "${YELLOW}Доступные резервные копии:${NC}"
    echo ""
    for i in "${!files[@]}"; do
        SIZE=$(du -h "${files[$i]}" | cut -f1)
        echo -e "  ${GREEN}$((i+1))${NC}. $(basename "${files[$i]}")  ${CYAN}[$SIZE]${NC}"
    done
    echo ""

    local choice
    read -r -p "Выберите номер (Enter = пропустить): " choice
    echo ""

    if [ -z "$choice" ]; then
        echo -e "${YELLOW}Пропущено.${NC}"
        return 0
    fi

    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#files[@]}" ]; then
        local selected="${files[$((choice-1))]}"
        echo -e "${GREEN}Выбрано:${NC} $(basename "$selected")"
        eval "$result_var=$selected"
        return 0
    else
        echo -e "${RED}Неверный номер!${NC}"
        return 1
    fi
}

# ====== Header ======
print_header "Restore DreamSeed"

# ================================================
# STEP 1: Что восстановить?
# ================================================
show_menu
read -r -p "Ваш выбор: " MENU_CHOICE
echo ""

case "$MENU_CHOICE" in
    1) RESTORE_PROJECT=1; RESTORE_DB=0 ;;
    2) RESTORE_PROJECT=0; RESTORE_DB=1 ;;
    3) RESTORE_PROJECT=1; RESTORE_DB=1 ;;
    4) echo -e "${YELLOW}Выход.${NC}"; exit 0 ;;
    *) echo -e "${RED}Неверный выбор!${NC}"; exit 1 ;;
esac

# ================================================
# STEP 2: Выбор backup файлов
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
    echo -e "${RED}Ничего не выбрано. Выход.${NC}"
    exit 0
fi

# ================================================
# STEP 3: Confirmation
# ================================================
echo ""
echo -e "${RED}⚠️  ВНИМАНИЕ! Будет выполнено:${NC}"
[ -n "$SELECTED_PROJECT" ] && echo -e "  - Заменить файлы проекта: ${CYAN}$(basename "$SELECTED_PROJECT")${NC}"
[ -n "$SELECTED_DB" ]      && echo -e "  - Перезаписать БД: ${CYAN}$(basename "$SELECTED_DB")${NC}"
echo -e "  - Остановить $WEB_SERVICE и PHP-FPM"
echo -e "  - Очистить MODX cache"
echo ""
read -r -p "Продолжить? (yes/no): " CONFIRM

if [ "$CONFIRM" != "yes" ]; then
    echo -e "${RED}Отменено.${NC}"
    exit 0
fi

echo ""

# ================================================
# STEP 4: Validate archives
# ================================================
echo -e "${YELLOW}[0] Проверка целостности архивов...${NC}"
if [ -n "$SELECTED_PROJECT" ]; then
    if ! sudo tar -tzf "$SELECTED_PROJECT" >/dev/null 2>&1; then
        echo -e "${RED}✗ Архив проекта повреждён: $(basename "$SELECTED_PROJECT")${NC}"
        exit 1
    fi
    echo -e "${GREEN}✓ Архив проекта: OK${NC}"
fi
if [ -n "$SELECTED_DB" ]; then
    if ! gunzip -t "$SELECTED_DB" 2>/dev/null; then
        echo -e "${RED}✗ Архив БД повреждён: $(basename "$SELECTED_DB")${NC}"
        exit 1
    fi
    echo -e "${GREEN}✓ Архив БД: OK${NC}"
fi
echo ""

# ================================================
# STEP 5: Stop services
# ================================================
echo -e "${YELLOW}[1] Остановка сервисов...${NC}"
if ! sudo systemctl stop "$PHP_FPM" "$WEB_SERVICE" 2>/dev/null; then
    echo -e "${RED}✗ Не удалось остановить сервисы!${NC}"
    exit 1
fi
SERVICES_STOPPED=1
echo -e "${GREEN}✓ Сервисы остановлены${NC}"
echo ""

# ================================================
# STEP 6: Restore project
# ================================================
PROJECT_STATUS="⏭️ Пропущен"

if [ -n "$SELECTED_PROJECT" ]; then
    echo -e "${YELLOW}[2] Восстановление проекта...${NC}"

    TEMP_EXTRACT=$(sudo mktemp -d "$(dirname "$PROJECT_DIR")/restore_XXXXXX")
    sudo tar -xzf "$SELECTED_PROJECT" -C "$TEMP_EXTRACT"

    if [ $? -eq 0 ]; then
        sudo rm -rf "$PROJECT_DIR"
        sudo mv "$TEMP_EXTRACT/$(basename "$PROJECT_DIR")" "$PROJECT_DIR"
        sudo rm -rf "$TEMP_EXTRACT"
        sudo mkdir -p "$PROJECT_DIR/core/xpdo/cache"
        sudo chown -R www-data:www-data "$PROJECT_DIR"
        PROJECT_STATUS="✅ $(basename "$SELECTED_PROJECT")"
        echo -e "${GREEN}✓ Проект восстановлен${NC}"
    else
        sudo rm -rf "$TEMP_EXTRACT"
        PROJECT_STATUS="❌ Ошибка"
        echo -e "${RED}✗ Ошибка восстановления проекта!${NC}"
    fi
else
    echo -e "${YELLOW}[2] Пропуск восстановления проекта.${NC}"
fi
echo ""

# ================================================
# STEP 7: Restore database
# ================================================
DB_STATUS="⏭️ Пропущен"

if [ -n "$SELECTED_DB" ]; then
    echo -e "${YELLOW}[3] Восстановление базы данных...${NC}"

    COUNT_BEFORE=$(mysql "$DB_NAME" -se "SELECT COUNT(*) FROM modx_site_content;" 2>/dev/null || echo "0")
    LAST_EDIT_BEFORE=$(mysql "$DB_NAME" -se "SELECT FROM_UNIXTIME(MAX(editedon)) FROM modx_site_content;" 2>/dev/null)

    TEMP_SQL=$(mktemp /tmp/restore_XXXXXX.sql)
    gunzip -c "$SELECTED_DB" > "$TEMP_SQL"

    if [ $? -ne 0 ]; then
        rm -f "$TEMP_SQL"
        DB_STATUS="❌ Ошибка распаковки"
        echo -e "${RED}✗ Ошибка распаковки архива!${NC}"
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

            # Rollback detection
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
                            ROLLBACK_STR=" ⚠️ Откат ${DAYS}д ${HOURS}ч"
                        elif [ $HOURS -gt 0 ]; then
                            ROLLBACK_STR=" ⚠️ Откат ${HOURS}ч"
                        else
                            ROLLBACK_STR=" ⚠️ Откат"
                        fi
                        echo -e "${YELLOW}⚠️  Внимание: восстановленные данные старше текущих!${NC}"
                    fi
                fi
            fi

            DB_STATUS="✅ $(basename "$SELECTED_DB")$DIFF_STR$ROLLBACK_STR"
            echo -e "${GREEN}✓ БД восстановлена, сессии очищены${NC}"
        else
            DB_STATUS="❌ Ошибка"
            echo -e "${RED}✗ Ошибка восстановления БД!${NC}"
        fi

        rm -f "$TEMP_SQL"
    fi
else
    echo -e "${YELLOW}[3] Пропуск восстановления БД.${NC}"
fi
echo ""

# ================================================
# STEP 8: Clear cache and permissions
# ================================================
echo -e "${YELLOW}[4] Очистка cache и установка прав...${NC}"
sudo mkdir -p "$PROJECT_DIR/core/cache/logs"
sudo rm -rf "$PROJECT_DIR/core/cache"/*
sudo chown -R www-data:www-data "$PROJECT_DIR/core/cache"
sudo chmod -R 755 "$PROJECT_DIR/core/cache"
echo -e "${GREEN}✓ Cache очищен${NC}"
echo ""

# ================================================
# STEP 9: Start services
# ================================================
echo -e "${YELLOW}[5] Запуск сервисов...${NC}"
SERVICES_STOPPED=0
sudo systemctl start "$PHP_FPM" "$WEB_SERVICE" 2>/dev/null
sleep 3

HTTP_CODE=$(curl -sk "$SITE_URL" -o /dev/null -w "%{http_code}")
if [ "$HTTP_CODE" = "200" ]; then
    SITE_STATUS="✅ HTTP $HTTP_CODE"
    echo -e "${GREEN}✓ Сайт работает (HTTP $HTTP_CODE)${NC}"
else
    SITE_STATUS="⚠️ HTTP $HTTP_CODE"
    echo -e "${YELLOW}⚠️ Сайт вернул HTTP $HTTP_CODE${NC}"
fi
echo ""

# ================================================
# Summary
# ================================================
ELAPSED=$(( $(date +%s) - START_TIME ))

print_header "Восстановление завершено (${ELAPSED} сек)"

echo -e "  Проект: $PROJECT_STATUS"
echo -e "  БД:     $DB_STATUS"
echo -e "  Сайт:   $SITE_STATUS"
echo ""

# Telegram
MSG="🔄 *[$ENV_DISPLAY] DreamSeed Restore*

📝 *Проект:* $(escape_md2 "$PROJECT_STATUS")
🗄️ *БД:* $(escape_md2 "$DB_STATUS")
🌐 *Сайт:* $(escape_md2 "$SITE_STATUS")
⏱️ *Время:* \`${ELAPSED}\` сек"

if [[ "$DB_STATUS" == *"Откат"* ]]; then
    MSG="$MSG

⚠️ *Откат данных - проверьте осторожно!*"
fi

send_tg "$MSG"