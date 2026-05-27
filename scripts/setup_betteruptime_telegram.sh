#!/bin/bash
# Creates a Better Stack outgoing webhook that forwards monitor alerts to Telegram.
# Portfolio script — requires BETTERUPTIME_API_TOKEN, TG_TOKEN, TG_CHAT_ID in secrets/.env

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/common_functions.sh
source "$SCRIPT_DIR/scripts/common_functions.sh"
load_env "$SCRIPT_DIR/secrets/.env"

[[ -z "${BETTERUPTIME_API_TOKEN:-}" ]] && { echo "Error: BETTERUPTIME_API_TOKEN not set"; exit 1; }
[[ -z "${TG_TOKEN:-}" ]] && { echo "Error: TG_TOKEN not set"; exit 1; }
[[ -z "${TG_CHAT_ID:-}" ]] && { echo "Error: TG_CHAT_ID not set"; exit 1; }

API="https://uptime.betterstack.com/api/v2"
AUTH="Authorization: Bearer $BETTERUPTIME_API_TOKEN"
TELEGRAM_URL="https://api.telegram.org/bot${TG_TOKEN}/sendMessage"

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
      "text": "\u26A0\uFE0F Better Stack Alert\n\nMonitor: \$NAME\nURL: \$URL\nCause: \$CAUSE\nStarted: \$STARTED_AT\nResolved: \$RESOLVED_AT"
    }
  }
}
ENDJSON

echo -e "\n${CYAN}Setting up Better Stack → Telegram webhook...${NC}\n"

resp=$(curl -s -X POST "$API/outgoing-webhooks" -H "$AUTH" -H "Content-Type: application/json" -d "@$tmp")

id=$(echo "$resp" | grep -o '"id": *"[^"]*"' | head -1 | cut -d'"' -f4)
if [[ -n "$id" ]]; then
    echo -e "${GREEN}Webhook created:${NC} ID $id"
else
    err=$(echo "$resp" | grep -o '"error": "[^"]*"' | head -1)
    echo -e "${RED}Failed:${NC} ${err:-unknown}" >&2
    exit 1
fi

rm -f "$tmp"
echo -e "\n${GREEN}Done${NC} — Better Stack alerts will now appear in Telegram"
