#!/bin/bash
# Better Stack setup — heartbeats + Telegram webhooks.
# Portfolio script. Idempotent: safe to run repeatedly.
#   --write-env    Write new keys to secrets/.env automatically
#
# Requires BETTERUPTIME_API_TOKEN in secrets/.env.
# TG_TOKEN, TG_CHAT_ID are optional — if set, also sets up webhooks.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/common_functions.sh
source "$SCRIPT_DIR/scripts/common_functions.sh"
load_env "$SCRIPT_DIR/secrets/.env"

[[ -z "${BETTERUPTIME_API_TOKEN:-}" ]] && { echo "Error: BETTERUPTIME_API_TOKEN not set in secrets/.env"; exit 1; }

WRITE_ENV=false
[[ "${1:-}" == "--write-env" ]] && WRITE_ENV=true

API="https://uptime.betterstack.com/api/v2"
AUTH="Authorization: Bearer $BETTERUPTIME_API_TOKEN"

ENV_FILE="$SCRIPT_DIR/secrets/.env"

# ─── Helpers ────────────────────────────────────────────────────────────────

get_existing_heartbeats() {
    curl -s -X GET "$API/heartbeats?page=1&per_page=50" -H "$AUTH" || echo '{"data":[]}'
}

get_existing_webhooks() {
    curl -s -X GET "$API/outgoing-webhooks" -H "$AUTH" || echo '{"data":[]}'
}

heartbeat_exists() {
    local name="$1"
    local data="$2"
    echo "$data" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for item in data.get('data', []):
    a = item['attributes']
    if a['name'] == '$name':
        print(a['url'])
        break
" 2>/dev/null
}

find_key_in_env() {
    local var_name="$1"
    local line
    line=$(grep "^${var_name}=" "$ENV_FILE" 2>/dev/null | tail -1)
    if [[ -n "$line" ]]; then
        echo "$line" | sed 's/^[^=]*="\(.*\)"$/\1/'
    fi
}

write_key_to_env() {
    local var_name="$1" value="$2"
    if grep -qP "^${var_name}=" "$ENV_FILE" 2>/dev/null; then
        sed -i.bak "s/^${var_name}=.*$/${var_name}=\"${value}\"/" "$ENV_FILE"
        rm -f "$ENV_FILE.bak"
    else
        echo "${var_name}=\"${value}\"" >> "$ENV_FILE"
    fi
}

# ─── Heartbeats ─────────────────────────────────────────────────────────────

echo -e "\n${CYAN}Better Stack — heartbeats${NC}\n"

existing_hb=$(get_existing_heartbeats)

for spec in \
    "backup|BETTERUPTIME_BACKUP_KEY|3600|300" \
    "gdrive-upload|BETTERUPTIME_GDRIVE_KEY|86400|1800" \
    "report-daily|BETTERUPTIME_REPORT_DAILY_KEY|86400|1800" \
    "report-weekly|BETTERUPTIME_REPORT_WEEKLY_KEY|604800|3600"; do

    IFS='|' read -r name var_name period grace <<< "$spec"

    url=$(heartbeat_exists "$name" "$existing_hb")

    if [[ -n "$url" ]]; then
        key=$(echo "$url" | awk -F/ '{print $NF}')
        echo -e "  ${GREEN}✓${NC} $name (already exists)"
    else
        json=$(printf '{"name":"%s","period":%s,"grace":%s,"email":true,"push":true}' "$name" "$period" "$grace")
        resp=$(curl -s -X POST "$API/heartbeats" -H "$AUTH" -H "Content-Type: application/json" -d "$json" || echo "")
        url=$(echo "$resp" | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['attributes']['url'])" 2>/dev/null || echo "")
        key=$(echo "$url" | awk -F/ '{print $NF}')

        if [[ -n "$key" ]]; then
            echo -e "  ${GREEN}✓${NC} $name (created)"
        else
            err=$(echo "$resp" | grep -o '"error": "[^"]*"' | head -1)
            echo -e "  ${RED}✗${NC} $name — ${err:-unknown}" >&2
            continue
        fi
    fi

    if $WRITE_ENV; then
        current=$(find_key_in_env "$var_name")
        if [[ "$current" != "$key" ]]; then
            write_key_to_env "$var_name" "$key"
            echo -e "    ${YELLOW}→${NC} Updated $var_name in .env"
        fi
    fi
done

# ─── Telegram webhooks ──────────────────────────────────────────────────────

if [[ -z "${TG_TOKEN:-}" || -z "${TG_CHAT_ID:-}" ]]; then
    echo -e "\n${YELLOW}Skipping webhooks — set TG_TOKEN and TG_CHAT_ID in secrets/.env${NC}"
else
    echo -e "\n${CYAN}Better Stack — Telegram webhooks${NC}\n"

    TELEGRAM_URL="https://api.telegram.org/bot${TG_TOKEN}/sendMessage"
    THREAD="${TG_THREAD_ID:-3}"

    existing_wh=$(get_existing_webhooks)

    ensure_webhook() {
        local name="$1" started="$2" resolved="$3" text="$4"

        # Check if webhook already exists by name
        existing_id=$(echo "$existing_wh" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for item in data.get('data', []):
    if item['attributes']['name'] == '$name':
        print(item['id'])
        break
" 2>/dev/null)

        # Build JSON payload
        python3 - "$name" "$TELEGRAM_URL" "$started" "$resolved" "$TG_CHAT_ID" "$THREAD" "$text" << 'PYEOF' > /dev/null
import sys, json

_, name, url, started, resolved, chat_id, thread, text = sys.argv
started = started.lower() == 'true'
resolved = resolved.lower() == 'true'

payload = {
    "custom_webhook_template_attributes": {
        "http_method": "post",
        "headers_template": [
            {"name": "Content-Type", "value": "application/json"}
        ],
        "body_template": {
            "chat_id": chat_id,
            "message_thread_id": int(thread),
            "text": text
        }
    }
}
with open("/tmp/bs_webhook.json", "w") as f:
    json.dump(payload, f)
PYEOF

        if [[ -n "$existing_id" ]]; then
            resp=$(curl -s -X PATCH "$API/outgoing-webhooks/$existing_id" -H "$AUTH" -H "Content-Type: application/json" -d "@/tmp/bs_webhook.json" || echo "")
            echo -e "  ${GREEN}✓${NC} $name (updated, ID $existing_id)"
        else
            # For creation we need the full payload
            python3 - "$name" "$TELEGRAM_URL" "$started" "$resolved" "$TG_CHAT_ID" "$THREAD" "$text" << 'PYEOF' > /dev/null
import sys, json

_, name, url, started, resolved, chat_id, thread, text = sys.argv
started = started.lower() == 'true'
resolved = resolved.lower() == 'true'

payload = {
    "name": name,
    "url": url,
    "trigger_type": "incident_change",
    "on_incident_started": started,
    "on_incident_resolved": resolved,
    "on_incident_acknowledged": False,
    "on_incident_reopened": False,
    "on_incident_comment": False,
    "custom_webhook_template_attributes": {
        "http_method": "post",
        "headers_template": [
            {"name": "Content-Type", "value": "application/json"}
        ],
        "body_template": {
            "chat_id": chat_id,
            "message_thread_id": int(thread),
            "text": text
        }
    }
}
with open("/tmp/bs_webhook.json", "w") as f:
    json.dump(payload, f)
PYEOF

            resp=$(curl -s -X POST "$API/outgoing-webhooks" -H "$AUTH" -H "Content-Type: application/json" -d "@/tmp/bs_webhook.json" || echo "")
            id=$(echo "$resp" | grep -o '"id": *"[^"]*"' | head -1 | cut -d'"' -f4)
            if [[ -n "$id" ]]; then
                echo -e "  ${GREEN}✓${NC} $name (created, ID $id)"
            else
                err=$(echo "$resp" | grep -o '"error": "[^"]*"' | head -1)
                echo -e "  ${RED}✗${NC} $name — ${err:-unknown}" >&2
            fi
        fi
        rm -f /tmp/bs_webhook.json
    }

    ensure_webhook "Better Stack → Alert" true false '\uD83D\uDD34BetterStack Alert\uD83D\uDD34\n\n$NAME\n$CAUSE\n---\n$STARTED_AT'
    ensure_webhook "Better Stack → Resolve" false true '\u2705BetterStack Resolved\u2705\n\n$NAME\n---\n$STARTED_AT\n$RESOLVED_AT'
fi

echo -e "\n${GREEN}All done${NC}"
