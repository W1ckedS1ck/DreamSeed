#!/bin/bash
# Better Stack setup — heartbeats + Telegram alerts.
# Portfolio script. Requires BETTERUPTIME_API_TOKEN in secrets/.env.
# TG_TOKEN, TG_CHAT_ID are optional — if set, also creates Telegram webhook.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/common_functions.sh
source "$SCRIPT_DIR/scripts/common_functions.sh"
load_env "$SCRIPT_DIR/secrets/.env"

[[ -z "${BETTERUPTIME_API_TOKEN:-}" ]] && { echo "Error: BETTERUPTIME_API_TOKEN not set in secrets/.env"; exit 1; }

API="https://uptime.betterstack.com/api/v2"
HEARTBEAT_API="$API/heartbeats"
AUTH="Authorization: Bearer $BETTERUPTIME_API_TOKEN"

echo -e "\n${CYAN}Creating/updating Better Stack heartbeats...${NC}\n"

echo "# Paste these into secrets/.env:"
echo "# ─────────────────────────────────────"

create_heartbeat() {
    local n="$1" t="$2" g="$3"
    local json
    json=$(printf '{"name":"%s","period":%s,"grace":%s,"email":true,"push":true}' "$n" "$t" "$g")
    curl -s "$HEARTBEAT_API" -H "$AUTH" -H "Content-Type: application/json" -d "$json"
}

for spec in \
    "backup|BETTERUPTIME_BACKUP_KEY|3600|300" \
    "gdrive-upload|BETTERUPTIME_GDRIVE_KEY|86400|1800" \
    "report-daily|BETTERUPTIME_REPORT_DAILY_KEY|86400|1800" \
    "report-weekly|BETTERUPTIME_REPORT_WEEKLY_KEY|604800|3600"; do

    IFS='|' read -r name var_name timeout grace <<< "$spec"
    resp=$(create_heartbeat "$name" "$timeout" "$grace")
    url=$(echo "$resp" | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['attributes']['url'])" 2>/dev/null || echo "")
    key=$(echo "$url" | awk -F/ '{print $NF}')

    if [[ -n "$key" ]]; then
        echo "$var_name=\"$key\""
    else
        err=$(echo "$resp" | grep -o '"error": "[^"]*"' | head -1)
        echo "# $name — FAILED: ${err:-unknown}" >&2
    fi
done

echo "# ─────────────────────────────────────"
echo -e "\n${GREEN}Heartbeats done${NC}"

# ═══════════════════════════════════════════════════════════
# Telegram webhook (optional — only if TG vars are set)
# ═══════════════════════════════════════════════════════════
if [[ -z "${TG_TOKEN:-}" || -z "${TG_CHAT_ID:-}" ]]; then
    echo -e "\n${YELLOW}Skipping Telegram webhook — set TG_TOKEN and TG_CHAT_ID in secrets/.env${NC}"
else
    echo -e "\n${CYAN}Setting up Better Stack → Telegram webhook...${NC}"

    TELEGRAM_URL="https://api.telegram.org/bot${TG_TOKEN}/sendMessage"
    THREAD="${TG_THREAD_ID:-}"

    tmp=$(mktemp)
    cat > "$tmp" << ENDJSON
{
  "name": "Better Stack → Telegram",
  "url": "$TELEGRAM_URL",
  "trigger_type": "incident_change",
  "on_incident_started": true,
  "on_incident_resolved": true,
  "on_incident_acknowledged": false,
  "on_incident_reopened": false,
  "on_incident_comment": false,
  "custom_webhook_template_attributes": {
    "http_method": "post",
    "headers_template": [
      {"name": "Content-Type", "value": "application/json"}
    ],
    "body_template": {
      "chat_id": "$TG_CHAT_ID",
      "message_thread_id": $THREAD,
      "text": "\u26A0\uFE0F Better Stack Alert\n\nMonitor: \$NAME\nURL: \$URL\nCause: \$CAUSE\nStarted: \$STARTED_AT\nResolved: \$RESOLVED_AT"
    }
  }
}
ENDJSON

    resp=$(curl -s -X POST "$API/outgoing-webhooks" -H "$AUTH" -H "Content-Type: application/json" -d "@$tmp")
    id=$(echo "$resp" | grep -o '"id": *"[^"]*"' | head -1 | cut -d'"' -f4)

    if [[ -n "$id" ]]; then
        echo -e "${GREEN}Webhook created:${NC} ID $id"
    else
        err=$(echo "$resp" | grep -o '"error": "[^"]*"' | head -1)
        echo -e "${RED}Webhook failed:${NC} ${err:-unknown}" >&2
    fi

    rm -f "$tmp"
    echo -e "\n${GREEN}Telegram webhook done${NC}"
fi

echo -e "\n${GREEN}All done${NC}"
