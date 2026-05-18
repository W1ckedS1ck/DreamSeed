#!/bin/bash
set -euo pipefail

# Automated restore for GitHub Actions rollback workflow
# Restores latest project + database backup without interaction

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common_functions.sh"
load_env "$SCRIPT_DIR/.env"

# Detect web server
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
        echo "Restarting services..."
        sudo systemctl start "$PHP_FPM" "$WEB_SERVICE" 2>/dev/null || true
    fi
}
trap cleanup_trap EXIT INT TERM

# Get latest backups
LATEST_PROJECT=$(ls -1t "$BACKUP_DIR/project/DreamSeed_"*.tar.gz 2>/dev/null | head -n1)
LATEST_DB=$(ls -1t "$BACKUP_DIR/db/db_"*.sql.gz 2>/dev/null | head -n1)

if [ -z "$LATEST_PROJECT" ] || [ -z "$LATEST_DB" ]; then
    echo "ERROR: Latest backups not found"
    echo "Project: $LATEST_PROJECT"
    echo "DB: $LATEST_DB"
    exit 1
fi

echo "Restoring from latest backups..."
echo "Project: $(basename "$LATEST_PROJECT")"
echo "DB: $(basename "$LATEST_DB")"
echo ""

# Stop services
echo "Stopping services..."
sudo systemctl stop "$PHP_FPM" "$WEB_SERVICE"
SERVICES_STOPPED=1

# Restore project
echo "Extracting project files..."
if [[ "$PROJECT_DIR" == /var/www/* ]]; then
    sudo rm -rf "$PROJECT_DIR"
else
    echo "ERROR: safety check failed — refused to delete \$PROJECT_DIR: $PROJECT_DIR" >&2
    exit 1
fi
sudo mkdir -p "$PROJECT_DIR"
sudo tar -xzf "$LATEST_PROJECT" -C "$(dirname "$PROJECT_DIR")"

# Restore database
echo "Restoring database..."
gunzip -c "$LATEST_DB" | mysql "$DB_NAME" 2>/dev/null || {
    echo "ERROR: Database restore failed"
    exit 1
}

echo "Clearing MODX session table..."
mysql "$DB_NAME" -e "TRUNCATE TABLE modx_session;" 2>/dev/null || true

# Start services
echo "Starting services..."
sudo systemctl start "$PHP_FPM" "$WEB_SERVICE"
SERVICES_STOPPED=0

# Health check
echo "Waiting for services to be ready..."
sleep 2

HEALTH_CHECK=$(curl -s -o /dev/null -w "%{http_code}" "$SITE_URL/" || echo "000")
if [ "$HEALTH_CHECK" = "200" ] || [ "$HEALTH_CHECK" = "301" ]; then
    END_TIME=$(date +%s)
    DURATION=$((END_TIME - START_TIME))
    MSG="✅ *RESTORE COMPLETE* — $ENV_DISPLAY_ESCAPED
📦 Project: $(basename "$LATEST_PROJECT")
📊 Database: $(basename "$LATEST_DB")
⏱ Duration: ${DURATION}s
🌐 Site: $SITE_URL"
    send_tg "$MSG"
    echo "Restore completed successfully in ${DURATION}s"
else
    END_TIME=$(date +%s)
    DURATION=$((END_TIME - START_TIME))
    MSG="⚠️ *RESTORE COMPLETED BUT HEALTH CHECK FAILED* — $ENV_DISPLAY_ESCAPED
📦 Project: $(basename "$LATEST_PROJECT")
📊 Database: $(basename "$LATEST_DB")
⏱ Duration: ${DURATION}s
🌐 Site returned HTTP $HEALTH_CHECK
⚠️ Check manually at: $SITE_URL"
    send_tg "$MSG"
    echo "WARNING: Restore completed but health check returned HTTP $HEALTH_CHECK"
fi
