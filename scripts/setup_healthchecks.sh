#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/common_functions.sh
source "$SCRIPT_DIR/scripts/common_functions.sh"
load_env "$SCRIPT_DIR/secrets/.env"

[[ -z "${HEALTHCHECKS_API_KEY:-}" ]] && { echo "Error: HEALTHCHECKS_API_KEY not set in secrets/.env"; exit 1; }

API="https://healthchecks.io/api/v3/checks/"
AUTH="X-Api-Key: $HEALTHCHECKS_API_KEY"

create_or_update() {
    local n="$1" t="$2" g="$3" d="$4"
    local json
    json=$(printf '{"name":"%s","tags":"dreamseed","desc":"%s","timeout":%s,"grace":%s,"channels":"*","unique":["name"]}' "$n" "$d" "$t" "$g")
    curl -s "$API" -H "$AUTH" -H "Content-Type: application/json" -d "$json"
}

echo -e "\n${CYAN}Creating/updating healthchecks...${NC}\n"

echo "# Paste these into secrets/.env:"
echo "# ─────────────────────────────────────"

for spec in \
    "backup|HEALTHCHECK_BACKUP_UUID|3600|300|smart_backup.sh - hourly project+DB backup" \
    "gdrive-upload|HEALTHCHECK_GDRIVE_UUID|86400|1800|upload_backups_to_gdrive.sh - daily upload to GDrive" \
    "report-daily|HEALTHCHECK_REPORT_DAILY_UUID|86400|1800|send_report.sh daily" \
    "report-weekly|HEALTHCHECK_REPORT_WEEKLY_UUID|604800|3600|send_report.sh weekly"; do

    IFS='|' read -r name var_name timeout grace desc <<< "$spec"
    resp=$(create_or_update "$name" "$timeout" "$grace" "$desc")
    uuid=$(echo "$resp" | grep -o '"uuid": "[^"]*"' | cut -d'"' -f4)

    if [[ -n "$uuid" ]]; then
        echo "$var_name=\"$uuid\""
    else
        err=$(echo "$resp" | grep -o '"error": "[^"]*"' | cut -d'"' -f4)
        echo "# $name — FAILED: ${err:-unknown}" >&2
    fi
done

echo "# ─────────────────────────────────────"
echo -e "\n${GREEN}Done${NC}"
