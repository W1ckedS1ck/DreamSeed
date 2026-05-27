#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/common_functions.sh
source "$SCRIPT_DIR/scripts/common_functions.sh"
load_env "$SCRIPT_DIR/secrets/.env"

[[ -z "${BETTERUPTIME_API_TOKEN:-}" ]] && { echo "Error: BETTERUPTIME_API_TOKEN not set in secrets/.env"; exit 1; }

API="https://uptime.betterstack.com/api/v2/heartbeats"
AUTH="Authorization: Bearer $BETTERUPTIME_API_TOKEN"

create_heartbeat() {
    local n="$1" t="$2" g="$3" d="$4"
    local json
    json=$(printf '{"name":"%s","period":%s,"grace":%s,"desc":"%s","email":true,"push":true}' "$n" "$t" "$g" "$d")
    curl -s "$API" -H "$AUTH" -H "Content-Type: application/json" -d "$json"
}

echo -e "\n${CYAN}Creating/updating Better Stack heartbeats...${NC}\n"

echo "# Paste these into secrets/.env:"
echo "# ─────────────────────────────────────"

for spec in \
    "backup|BETTERUPTIME_BACKUP_KEY|3600|300|smart_backup.sh - hourly project+DB backup" \
    "gdrive-upload|BETTERUPTIME_GDRIVE_KEY|86400|1800|upload_backups_to_gdrive.sh - daily upload to GDrive" \
    "report-daily|BETTERUPTIME_REPORT_DAILY_KEY|86400|1800|send_report.sh daily" \
    "report-weekly|BETTERUPTIME_REPORT_WEEKLY_KEY|604800|3600|send_report.sh weekly"; do

    IFS='|' read -r name var_name timeout grace desc <<< "$spec"
    resp=$(create_heartbeat "$name" "$timeout" "$grace" "$desc")
    url=$(echo "$resp" | grep -o '"url": "[^"]*"' | cut -d'"' -f4)
    key=$(echo "$url" | awk -F/ '{print $NF}')

    if [[ -n "$key" ]]; then
        echo "$var_name=\"$key\""
    else
        err=$(echo "$resp" | grep -o '"error": "[^"]*"' | head -1)
        echo "# $name — FAILED: ${err:-unknown}" >&2
    fi
done

echo "# ─────────────────────────────────────"
echo -e "\n${GREEN}Done${NC}"
