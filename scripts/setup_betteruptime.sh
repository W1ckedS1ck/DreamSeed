#!/bin/bash
# Better Stack setup — heartbeats + Telegram webhooks.
# Portfolio script. Idempotent: safe to run repeatedly.
#   --write-env    Write new keys to secrets/.env automatically
#
# Requires BETTERUPTIME_API_TOKEN in secrets/.env.
# TG_TOKEN, TG_CHAT_ID are optional — if set, also sets up webhooks.

set -euo pipefail

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
target = sys.argv[1]
data = json.load(sys.stdin)
for item in data.get('data', []):
    a = item['attributes']
    if a['name'] == target:
        print(a['url'])
        break
" "$name" 2>/dev/null
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
        sed -i.bak "s|^${var_name}=.*$|${var_name}=\"${value}\"|" "$ENV_FILE"
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

# ─── HTTP monitors ──────────────────────────────────────────────────────────

echo -e "\n${CYAN}Better Stack — HTTP monitors${NC}\n"
# Note: widget type for status page (history/response_time) is UI-only.
# After first run, go to Better Stack → Status Pages → go-dreams
# and set Response time for main monitor (🌐 dreamseed.online).

existing_mon=$(curl -s -X GET "$API/monitors" -H "$AUTH" || echo '{"data":[]}')

monitor_exists() {
    local url="$1"
    local data="$2"
    echo "$data" | python3 -c "
import sys, json
target = sys.argv[1]
data = json.load(sys.stdin)
for item in data.get('data', []):
    if item['attributes']['url'] == target:
        print(item['id'])
        break
" "$url" 2>/dev/null
}

for spec in \
    "https://dreamseed.online/|Main site|The Dreamers|180" \
    "https://dreamseed.online/grafana|Grafana|Grafana|180"; do

    IFS='|' read -r url name keyword freq <<< "$spec"

    mid=$(monitor_exists "$url" "$existing_mon")

    json=$(python3 -c "
import json, sys

url, name, keyword = sys.argv[1], sys.argv[2], sys.argv[3]
freq = int(sys.argv[4])

payload = {
    'url': url,
    'pronounceable_name': name,
    'check_frequency': freq,
    'request_timeout': 30,
    'regions': ['eu', 'us', 'as', 'au'],
    'required_keyword': keyword,
    'keyword_type': 'exists'
}
print(json.dumps(payload))
" "$url" "$name" "$keyword" "$freq")

    if [[ -n "$mid" ]]; then
        curl -s -X PATCH "$API/monitors/$mid" -H "$AUTH" -H "Content-Type: application/json" -d "$json" > /dev/null
        echo -e "  ${GREEN}✓${NC} $name ($url) — already exists"
    else
        resp=$(curl -s -X POST "$API/monitors" -H "$AUTH" -H "Content-Type: application/json" -d "$json" || echo "")
        id=$(echo "$resp" | grep -o '"id": *"[^"]*"' | head -1 | cut -d'"' -f4)
        if [[ -n "$id" ]]; then
            echo -e "  ${GREEN}✓${NC} $name ($url) — created"
        else
            err=$(echo "$resp" | grep -o '"error": "[^"]*"' | head -1)
            echo -e "  ${RED}✗${NC} $name — ${err:-unknown}" >&2
        fi
    fi
done

# ─── Status page resources ──────────────────────────────────────────────────

SP_ID=$(curl -s -X GET "$API/status-pages" -H "$AUTH" | python3 -c "import sys,json; d=json.load(sys.stdin)['data']; print(d[0]['id'] if d else '')" 2>/dev/null)

if [[ -n "$SP_ID" ]]; then
    echo -e "\n${CYAN}Better Stack — status page resources${NC}\n"

existing_sp=$(curl -s -X GET "$API/status-pages/$SP_ID/resources" -H "$AUTH" || echo '{"data":[]}')

sp_resource_exists() {
    local rtype="$1" rid="$2"
    echo "$existing_sp" | python3 -c "
import sys, json
t, i = sys.argv[1], int(sys.argv[2])
for r in json.load(sys.stdin).get('data', []):
    a = r['attributes']
    if a.get('resource_type') == t and a.get('resource_id') == i:
        print(r['id'])
        break
" "$rtype" "$rid" 2>/dev/null
}

for spec in \
    "Monitor|4015585|🌐 dreamseed.online|0" \
    "Monitor|4015606|📊 Grafana|1" ; do

    IFS='|' read -r rtype rid name pos <<< "$spec"
    rtype_cap="${rtype}"

    existing_id=$(sp_resource_exists "$rtype_cap" "$rid")

    if [[ -n "$existing_id" ]]; then
        curl -s -X PATCH "$API/status-pages/$SP_ID/resources/$existing_id" -H "$AUTH" \
          -H "Content-Type: application/json" \
          -d "{\"public_name\":\"$name\",\"position\":$pos}" > /dev/null
        echo -e "  ${GREEN}✓${NC} $name — already on status page"
    else
        resp=$(curl -s -X POST "$API/status-pages/$SP_ID/resources" -H "$AUTH" \
          -H "Content-Type: application/json" \
          -d "{\"resource_type\":\"$rtype_cap\",\"resource_id\":$rid,\"public_name\":\"$name\",\"position\":$pos}" || echo "")
        sp_id=$(echo "$resp" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('data',{}).get('id',''))" 2>/dev/null)
        if [[ -n "$sp_id" ]]; then
            echo -e "  ${GREEN}✓${NC} $name — added to status page"
        else
            echo -e "  ${RED}✗${NC} $name — failed" >&2
        fi
    fi
done

fi

# ─── Telegram webhooks ──────────────────────────────────────────────────────

if [[ -z "${TG_TOKEN:-}" || -z "${TG_CHAT_ID:-}" ]]; then
    echo -e "\n${YELLOW}Skipping webhooks — set TG_TOKEN and TG_CHAT_ID in secrets/.env${NC}"
else
    echo -e "\n${CYAN}Better Stack — Telegram webhooks${NC}\n"

    TELEGRAM_URL="https://api.telegram.org/bot${TG_TOKEN}/sendMessage"
    THREAD="${TG_THREAD_ID:-}"

    existing_wh=$(get_existing_webhooks)

    ensure_webhook() {
        local name="$1" started="$2" resolved="$3" text="$4"
        local wh_json; wh_json=$(mktemp /tmp/bs_webhook_XXXXXX.json)
        trap 'rm -f "$wh_json"' RETURN

        # Check if webhook already exists by name
        existing_id=$(echo "$existing_wh" | python3 -c "
import sys, json
target = sys.argv[1]
data = json.load(sys.stdin)
for item in data.get('data', []):
    if item['attributes']['name'] == target:
        print(item['id'])
        break
" "$name" 2>/dev/null
)

        python3 - "$name" "$TELEGRAM_URL" "$started" "$resolved" "$TG_CHAT_ID" "$THREAD" "$text" "$([[ -n "$existing_id" ]] && echo false || echo true)" "$wh_json" << 'PYEOF' > /dev/null
import sys, json

_, name, url, started, resolved, chat_id, thread, text, for_creation, out_path = sys.argv
started = started.lower() == 'true'
resolved = resolved.lower() == 'true'
for_creation = for_creation.lower() == 'true'
text = text.replace('\\n', '\n')

payload = {}
if for_creation:
    payload.update({
        "name": name,
        "url": url,
        "trigger_type": "incident_change",
        "on_incident_started": started,
        "on_incident_resolved": resolved,
        "on_incident_acknowledged": False,
        "on_incident_reopened": False,
        "on_incident_comment": False,
    })
payload["custom_webhook_template_attributes"] = {
    "http_method": "post",
    "headers_template": [
        {"name": "Content-Type", "value": "application/json"}
    ],
    "body_template": {
        "chat_id": chat_id,
        "message_thread_id": int(thread),
        "parse_mode": "MarkdownV2",
        "text": text
    }
}
with open(out_path, "w") as f:
    json.dump(payload, f)
PYEOF

        if [[ -n "$existing_id" ]]; then
            resp=$(curl -s -X PATCH "$API/outgoing-webhooks/$existing_id" -H "$AUTH" -H "Content-Type: application/json" -d "@$wh_json" || echo "")
            echo -e "  ${GREEN}✓${NC} $name (updated, ID $existing_id)"
        else
            resp=$(curl -s -X POST "$API/outgoing-webhooks" -H "$AUTH" -H "Content-Type: application/json" -d "@$wh_json" || echo "")
            id=$(echo "$resp" | grep -o '"id": *"[^"]*"' | head -1 | cut -d'"' -f4)
            if [[ -n "$id" ]]; then
                echo -e "  ${GREEN}✓${NC} $name (created, ID $id)"
            else
                err=$(echo "$resp" | grep -o '"error": "[^"]*"' | head -1)
                echo -e "  ${RED}✗${NC} $name — ${err:-unknown}" >&2
            fi
        fi
    }

    ensure_webhook "Better Stack → Alert" true false '🚨 *$NAME*\n_$CAUSE_\n\n🔗 $URL\n⏱ Started: $STARTED_AT'
    ensure_webhook "Better Stack → Resolve" false true '✅ *$NAME* — Resolved\n_Back to normal_\n\n⏱ Down: $DURATION\n🕐 $STARTED_AT — $RESOLVED_AT'
fi

echo -e "\n${GREEN}All done${NC}"
