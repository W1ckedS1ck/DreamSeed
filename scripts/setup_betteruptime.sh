#!/bin/bash
# Better Stack setup — heartbeats + Telegram webhooks. Idempotent.
#   --write-env        Write new keys to secrets/.env automatically
#   --heartbeats-only  Reconcile heartbeat period/grace only; skip .env writes
# Requires BETTERUPTIME_API_TOKEN in secrets/.env; TG_TOKEN/TG_CHAT_ID optional.

set -euo pipefail

DOMAIN="${DOMAIN:-dreamseed.online}"

# Ensure HOME is set for temp directories
export HOME="${HOME:?ERROR: HOME environment variable not set}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/common_functions.sh
source "$SCRIPT_DIR/scripts/common_functions.sh"

ENV_PLAIN=$(mktemp)
chmod 600 "$ENV_PLAIN"
# Track every temp file (incl. write_key_to_env's $tmpfile.new) so none
# survives a failed run (M10). rm -f is safe for already-deleted entries.
_SETUP_TMPFILES=("$ENV_PLAIN")
# shellcheck disable=SC2154 # _f is assigned by the for-loop inside this same trap string
trap 'for _f in "${_SETUP_TMPFILES[@]:-}"; do rm -f "$_f"; done' EXIT

VAULT_PW_FILE="${VAULT_PASSWORD_FILE:-$HOME/.vault_pass_dreamseed}"
resolve_env_plain "$SCRIPT_DIR/secrets/.env" "$VAULT_PW_FILE" >"$ENV_PLAIN" || exit 1

load_env "$ENV_PLAIN"

[[ -z "${BETTERUPTIME_API_TOKEN:-}" ]] && {
    echo "Error: BETTERUPTIME_API_TOKEN not set in secrets/.env"
    exit 1
}

WRITE_ENV=false
HEARTBEATS_ONLY=false
for arg in "$@"; do
    case "$arg" in
    --write-env) WRITE_ENV=true ;;
    --heartbeats-only) HEARTBEATS_ONLY=true ;;
    *)
        echo "Unknown option: $arg" >&2
        exit 2
        ;;
    esac
done

API="https://uptime.betterstack.com/api/v2"
# Auth header via process substitution (not argv) — token stays out of ps aux.
# Usage: curl ... --config <(bu_auth) ...
bu_auth() { printf 'header = "Authorization: Bearer %s"\n' "$BETTERUPTIME_API_TOKEN"; }

ENV_FILE="$SCRIPT_DIR/secrets/.env"

# ==== Helpers ====

get_existing_heartbeats() {
    curl -s -X GET "$API/heartbeats?page=1&per_page=50" --config <(bu_auth) || echo '{"data":[]}'
}

get_existing_webhooks() {
    curl -s -X GET "$API/outgoing-webhooks" --config <(bu_auth) || echo '{"data":[]}'
}

# Print "id\turl\tperiod\tgrace" for the named heartbeat (detect + reconcile drift).
heartbeat_lookup() {
    local name="$1"
    # shellcheck disable=SC2178 # false positive: confused by python "data" below
    local data="$2"
    # shellcheck disable=SC2128 # same false positive
    echo "$data" | python3 -c "
import sys, json
target = sys.argv[1]
data = json.load(sys.stdin)
for item in data.get('data', []):
    a = item['attributes']
    if a['name'] == target:
        print('%s\t%s\t%s\t%s' % (item['id'], a['url'], a.get('period', ''), a.get('grace', '')))
        break
" "$name" 2>/dev/null
}

find_key_in_env() {
    local var_name="$1"
    local line
    line=$(grep "^${var_name}=" "$ENV_PLAIN" 2>/dev/null | tail -1)
    if [[ -n "$line" ]]; then
        echo "$line" | sed 's/^[^=]*="\(.*\)"$/\1/'
    fi
}

write_key_to_env() {
    local var_name="$1" value="$2"
    local tmpfile encrypted
    tmpfile=$(mktemp)
    chmod 600 "$tmpfile"
    _SETUP_TMPFILES+=("$tmpfile")

    resolve_env_plain "$ENV_FILE" "$VAULT_PW_FILE" >"$tmpfile" || {
        rm -f "$tmpfile"
        return 1
    }

    # Portable replacement for GNU-only grep -P (BSD grep broke key replacement).
    awk -v k="$var_name" 'index($0, k "=") != 1' "$tmpfile" >"$tmpfile.new"
    chmod 600 "$tmpfile.new"
    _SETUP_TMPFILES+=("$tmpfile.new")
    mv "$tmpfile.new" "$tmpfile"
    echo "${var_name}=\"${value}\"" >>"$tmpfile"

    # Encrypt into a temp file, validate it, then atomically mv into place.
    # Writing directly with --output="$ENV_FILE" would corrupt the only
    # secrets store if encrypt fails mid-write (disk full, Ctrl-C, bad vault
    # password). mv is atomic — the old vault survives any failure before it.
    encrypted=$(mktemp)
    chmod 600 "$encrypted"
    _SETUP_TMPFILES+=("$encrypted")
    if ! ansible-vault encrypt "$tmpfile" --vault-password-file "$VAULT_PW_FILE" --output="$encrypted"; then
        rm -f "$tmpfile" "$encrypted"
        echo "Error: failed to encrypt secrets/.env" >&2
        return 1
    fi
    if ! head -c 16 "$encrypted" | grep -qF '$ANSIBLE_VAULT'; then
        rm -f "$tmpfile" "$encrypted"
        echo "Error: encrypted output is not a valid vault file — secrets/.env NOT touched" >&2
        return 1
    fi
    [[ -s "$encrypted" ]] || {
        rm -f "$tmpfile" "$encrypted"
        echo "Error: encrypted output empty — secrets/.env NOT touched" >&2
        return 1
    }
    mv "$encrypted" "$ENV_FILE"
    rm -f "$tmpfile"
}

# ==== Heartbeats ====

echo -e "\n${CYAN}Better Stack — heartbeats${NC}\n"

existing_hb=$(get_existing_heartbeats)

# github-posture is created manually (its key lives in GitHub Actions secrets,
# not secrets/.env). Reconcile its period/grace if present, but never create it
# or write the key to the server env.
for spec in \
    "backup|BETTERUPTIME_BACKUP_KEY|3600|300" \
    "gdrive-upload|BETTERUPTIME_GDRIVE_KEY|3600|300" \
    "report-daily|BETTERUPTIME_REPORT_DAILY_KEY|86400|1800" \
    "report-weekly|BETTERUPTIME_REPORT_WEEKLY_KEY|604800|3600" \
    "verify-backups|BETTERUPTIME_VERIFY_KEY|86400|600" \
    "check-services|BETTERUPTIME_CHECK_SERVICES_KEY|300|300" \
    "github-posture|POSTURE_HEARTBEAT_KEY|93600|18000|noenv"; do

    IFS='|' read -r name var_name period grace env_mode <<<"$spec"
    env_mode="${env_mode:-env}"

    hb_id="" hb_url="" hb_period="" hb_grace=""
    hb_line=$(heartbeat_lookup "$name" "$existing_hb" || true)
    if [[ -n "$hb_line" ]]; then
        IFS=$'\t' read -r hb_id hb_url hb_period hb_grace <<<"$hb_line" || true
    fi

    if [[ -n "$hb_id" ]]; then
        key=$(echo "$hb_url" | awk -F/ '{print $NF}')
        if [[ "$hb_period" == "$period" && "$hb_grace" == "$grace" ]]; then
            echo -e "  ${GREEN}✓${NC} $name (already exists)"
        else
            # Reconcile drift so spec changes reach Better Stack (was create-only).
            json=$(printf '{"period":%s,"grace":%s}' "$period" "$grace")
            resp=$(curl -s -X PATCH "$API/heartbeats/$hb_id" --config <(bu_auth) -H "Content-Type: application/json" -d "$json" || echo "")
            if echo "$resp" | grep -q '"id"'; then
                echo -e "  ${GREEN}✓${NC} $name (updated: period ${hb_period}s→${period}s, grace ${hb_grace}s→${grace}s)"
            else
                err=$(echo "$resp" | grep -o '"error": "[^"]*"' | head -1)
                echo -e "  ${RED}✗${NC} $name — update failed ${err:-}" >&2
            fi
        fi
    else
        if [[ "$env_mode" == "noenv" ]]; then
            echo -e "  ${YELLOW}⚠${NC} $name — not found; create it manually and set $var_name in GitHub Actions secrets" >&2
            continue
        fi
        json=$(printf '{"name":"%s","period":%s,"grace":%s,"email":true,"push":true}' "$name" "$period" "$grace")
        resp=$(curl -s -X POST "$API/heartbeats" --config <(bu_auth) -H "Content-Type: application/json" -d "$json" || echo "")
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

    if $WRITE_ENV && [[ "$env_mode" == "env" ]]; then
        current=$(find_key_in_env "$var_name")
        if [[ "$current" != "$key" ]]; then
            write_key_to_env "$var_name" "$key"
            echo -e "    ${YELLOW}→${NC} Updated $var_name in .env"
        fi
    elif $WRITE_ENV; then
        echo -e "    ${YELLOW}→${NC} $var_name stays in GitHub Actions secrets (not secrets/.env)"
    fi
done

# Reconcile-only mode stops before monitors/webhooks/.env.
if $HEARTBEATS_ONLY; then
    echo -e "\n${GREEN}All done (heartbeats only)${NC}"
    exit 0
fi

# ==== HTTP monitors ====

echo -e "\n${CYAN}Better Stack — HTTP monitors${NC}\n"
# Note: widget type for status page (history/response_time) is UI-only.
# After first run, open Status Pages → DreamSeed (status.dreamseed.online)
# and set Response time for main monitor (🌐 dreamseed.online).

existing_mon=$(curl -s -X GET "$API/monitors" --config <(bu_auth) || echo '{"data":[]}')

monitor_exists() {
    local url="$1"
    # shellcheck disable=SC2178 # false positive: confused by python "data" below
    local data="$2"
    # shellcheck disable=SC2128 # same false positive
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
    "https://${DOMAIN}/|Main site|Garden of Dreamers|180|keyword" \
    "https://${DOMAIN}/manager/|Admin panel|MODX|300|keyword" \
    "https://${DOMAIN}/grafana|Grafana|Grafana|180|keyword" \
    "https://${DOMAIN}/bot-health|Telegram Bot||180|status" \
    "https://${DOMAIN}/catalog/bamboo|Product Lucky Bamboo|Lucky Bamboo Bonsai|180|keyword" \
    "https://${DOMAIN}/personal-account/registration|Registration Page||180|status"; do

    IFS='|' read -r url name keyword freq mtype <<<"$spec"

    mid=$(monitor_exists "$url" "$existing_mon")

    json=$(python3 -c "
import json, sys

url, name, keyword, mtype = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[5]
freq = int(sys.argv[4])

payload = {
    'url': url,
    'pronounceable_name': name,
    'monitor_type': mtype,
    'check_frequency': freq,
    'request_timeout': 30,
    'regions': ['eu', 'us', 'as', 'au'],
}
if mtype == 'keyword':
    payload['required_keyword'] = keyword
print(json.dumps(payload))
" "$url" "$name" "$keyword" "$freq" "$mtype")

    if [[ -n "$mid" ]]; then
        curl -s -X PATCH "$API/monitors/$mid" --config <(bu_auth) -H "Content-Type: application/json" -d "$json" >/dev/null
        echo -e "  ${GREEN}✓${NC} $name ($url) — already exists"
    else
        resp=$(curl -s -X POST "$API/monitors" --config <(bu_auth) -H "Content-Type: application/json" -d "$json" || echo "")
        id=$(echo "$resp" | grep -o '"id": *"[^"]*"' | head -1 | cut -d'"' -f4)
        if [[ -n "$id" ]]; then
            echo -e "  ${GREEN}✓${NC} $name ($url) — created"
        else
            err=$(echo "$resp" | grep -o '"error": "[^"]*"' | head -1)
            echo -e "  ${RED}✗${NC} $name — ${err:-unknown}" >&2
        fi
    fi
done

# ==== Status page ====

SP_JSON=$(curl -s -X GET "$API/status-pages" --config <(bu_auth) || echo '{"data":[]}')
SP_ID=$(echo "$SP_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin).get('data',[]); print(d[0]['id'] if d else '')" 2>/dev/null)
SP_CUSTOM_DOMAIN=$(echo "$SP_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin).get('data',[]); print((d[0]['attributes'].get('custom_domain') or '') if d else '')" 2>/dev/null)
SP_SUBDOMAIN=$(echo "$SP_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin).get('data',[]); print((d[0]['attributes'].get('subdomain') or '') if d else '')" 2>/dev/null)

if [[ -n "$SP_ID" ]]; then
    # Refresh inventories: the create/update loops above may have just added
    # monitors or heartbeats that are not in the earlier snapshots.
    existing_mon=$(curl -s -X GET "$API/monitors" --config <(bu_auth) || echo '{"data":[]}')
    existing_hb=$(get_existing_heartbeats)

    # --- settings ---
    echo -e "\n${CYAN}Better Stack — status page settings${NC}\n"

    # Subscriptions are plan-gated (the free plan rejects the PATCH), so they
    # are intentionally not managed here. Enable them in the UI if available.
    if [[ -n "$SP_CUSTOM_DOMAIN" ]]; then
        feed_host="$SP_CUSTOM_DOMAIN"
    elif [[ -n "$SP_SUBDOMAIN" ]]; then
        feed_host="${SP_SUBDOMAIN}.betterstackstatus.com"
    else
        feed_host="status.${DOMAIN}"
    fi
    settings_json=$(python3 -c '
import json, sys
domain, feed_host = sys.argv[1], sys.argv[2]
print(json.dumps({
    "design": "v2",
    "automatic_reports": True,
    "min_incident_length": 120,
    "announcement": None,
    "company_url": "https://" + domain,
    "contact_url": "https://" + domain,
    "navigation_links": [
        {"text": "Status", "href": "/"},
        {"text": "Maintenance", "href": "/maintenance"},
        {"text": "Previous incidents", "href": "/incidents"},
        {"text": "RSS", "href": "https://" + feed_host + "/feed.rss"},
    ],
}))
' "$DOMAIN" "$feed_host")
    resp=$(curl -s -X PATCH "$API/status-pages/$SP_ID" --config <(bu_auth) -H "Content-Type: application/json" -d "$settings_json" || echo "")
    if echo "$resp" | grep -q '"id"'; then
        echo -e "  ${GREEN}✓${NC} auto incidents, 120s threshold, RSS nav, public URLs"
    else
        err=$(echo "$resp" | grep -o '"errors": *"[^"]*"' | head -1)
        echo -e "  ${RED}✗${NC} settings — ${err:-unknown}" >&2
    fi

    # --- sections ---
    sections_json=$(curl -s -X GET "$API/status-pages/$SP_ID/sections" --config <(bu_auth) || echo '{"data":[]}')
    core_section=$(echo "$sections_json" | python3 -c "
import sys, json
d = json.load(sys.stdin).get('data', [])
d.sort(key=lambda s: s['attributes'].get('position', 0))
print(d[0]['id'] if d else '')
" 2>/dev/null)
    upstream_section=$(echo "$sections_json" | python3 -c "
import sys, json
for s in json.load(sys.stdin).get('data', []):
    if s['attributes'].get('name') == 'Upstream providers':
        print(s['id'])
        break
" 2>/dev/null)

    if [[ -z "$upstream_section" ]]; then
        resp=$(curl -s -X POST "$API/status-pages/$SP_ID/sections" --config <(bu_auth) \
            -H "Content-Type: application/json" \
            -d '{"name":"Upstream providers","position":1}' || echo "")
        upstream_section=$(echo "$resp" | python3 -c "import sys,json; print(json.load(sys.stdin).get('data',{}).get('id',''))" 2>/dev/null)
        if [[ -n "$upstream_section" ]]; then
            echo -e "  ${GREEN}✓${NC} Upstream providers section"
        else
            err=$(echo "$resp" | grep -o '"errors": *"[^"]*"' | head -1)
            echo -e "  ${RED}✗${NC} Upstream providers section — ${err:-unknown}" >&2
        fi
    fi

    # --- resources ---
    echo -e "\n${CYAN}Better Stack — status page resources${NC}\n"

    existing_sp=$(curl -s -X GET "$API/status-pages/$SP_ID/resources" --config <(bu_auth) || echo '{"data":[]}')

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

    make_sp_payload() {
        local mode="$1" rtype="$2" rid="$3" name="$4" pos="$5" section="$6" widget="$7" expl="$8"
        python3 -c '
import json, sys
mode, rtype, rid, name, pos, section, widget, expl = sys.argv[1:9]
d = {"public_name": name, "position": int(pos)}
if section:
    d["status_page_section_id"] = int(section)
if widget:
    d["widget_type"] = widget
if expl:
    d["explanation"] = expl
if mode == "create":
    d["resource_type"] = rtype
    d["resource_id"] = int(rid)
print(json.dumps(d))
' "$mode" "$rtype" "$rid" "$name" "$pos" "$section" "$widget" "$expl"
    }

    ensure_sp_resource() {
        local rtype="$1" rid="$2" name="$3" pos="$4" section="$5" widget="${6:-}" explanation="${7:-}"
        local existing_id payload resp sp_id err
        if [[ -z "$rid" ]]; then
            echo -e "  ${YELLOW}⚠${NC} $name — resource not found" >&2
            return 0
        fi

        existing_id=$(sp_resource_exists "$rtype" "$rid")
        if [[ -n "$existing_id" ]]; then
            payload=$(make_sp_payload update "$rtype" "$rid" "$name" "$pos" "$section" "$widget" "$explanation")
            resp=$(curl -s -X PATCH "$API/status-pages/$SP_ID/resources/$existing_id" --config <(bu_auth) \
                -H "Content-Type: application/json" -d "$payload" || echo "")
            if echo "$resp" | grep -q '"id"'; then
                echo -e "  ${GREEN}✓${NC} $name — already on status page"
            else
                err=$(echo "$resp" | grep -o '"errors": *"[^"]*"' | head -1)
                echo -e "  ${RED}✗${NC} $name — update failed ${err:-}" >&2
            fi
        else
            payload=$(make_sp_payload create "$rtype" "$rid" "$name" "$pos" "$section" "$widget" "$explanation")
            resp=$(curl -s -X POST "$API/status-pages/$SP_ID/resources" --config <(bu_auth) \
                -H "Content-Type: application/json" -d "$payload" || echo "")
            sp_id=$(echo "$resp" | python3 -c "import sys,json; print(json.load(sys.stdin).get('data',{}).get('id',''))" 2>/dev/null)
            if [[ -n "$sp_id" ]]; then
                echo -e "  ${GREEN}✓${NC} $name — added to status page"
            else
                err=$(echo "$resp" | grep -o '"errors": *"[^"]*"' | head -1)
                echo -e "  ${RED}✗${NC} $name — failed ${err:-}" >&2
            fi
        fi
    }

    hb_id_for() {
        heartbeat_lookup "$1" "$existing_hb" | cut -f1
    }

    # Public page: user-facing services only. /manager/, /catalog/bamboo and
    # /personal-account/registration are intentionally not shown.
    ensure_sp_resource "Monitor" "$(monitor_exists "https://${DOMAIN}/" "$existing_mon")" "🌐 ${DOMAIN}" 0 "$core_section" "response_times" "Response time & uptime"
    ensure_sp_resource "Monitor" "$(monitor_exists "https://${DOMAIN}/grafana" "$existing_mon")" "📊 Grafana" 1 "$core_section" "history" "Grafana Monitoring"
    ensure_sp_resource "Monitor" "$(monitor_exists "https://${DOMAIN}/bot-health" "$existing_mon")" "🤖 Telegram Bot" 2 "$core_section" "plain" ""
    ensure_sp_resource "Heartbeat" "$(hb_id_for backup)" "📦 Backup" 3 "$core_section" "plain" ""
    ensure_sp_resource "Heartbeat" "$(hb_id_for gdrive-upload)" "☁️ GDrive Upload" 4 "$core_section" "plain" ""
    ensure_sp_resource "Heartbeat" "$(hb_id_for report-daily)" "📅 Daily Report" 5 "$core_section" "plain" ""
    ensure_sp_resource "Heartbeat" "$(hb_id_for report-weekly)" "📆 Weekly Report" 6 "$core_section" "plain" ""
    ensure_sp_resource "Heartbeat" "$(hb_id_for verify-backups)" "🔍 Verify Backups" 7 "$core_section" "intraday_history" ""
    ensure_sp_resource "Heartbeat" "$(hb_id_for check-services)" "⏱ Check Services" 8 "$core_section" "plain" ""

    # Third-party rows can only be created in the status page editor. If they
    # already exist, file them under Upstream providers and explain them.
    third_party_id() {
        local name="$1"
        echo "$existing_sp" | python3 -c "
import sys, json
target = sys.argv[1]
for r in json.load(sys.stdin).get('data', []):
    a = r['attributes']
    if a.get('resource_type') == 'ThirdPartyService' and a.get('public_name') == target:
        print(r['id'])
        break
" "$name" 2>/dev/null
    }

    ensure_third_party() {
        local name="$1" pos="$2" explanation="$3" record_id payload resp err
        record_id=$(third_party_id "$name")
        if [[ -z "$record_id" ]]; then
            echo -e "  ${YELLOW}⚠${NC} $name — add it manually in the status page editor (Third party services)" >&2
            return 0
        fi
        if [[ -z "$upstream_section" ]]; then
            echo -e "  ${YELLOW}⚠${NC} $name — no Upstream providers section" >&2
            return 0
        fi
        payload=$(python3 -c 'import json,sys; print(json.dumps({"status_page_section_id": int(sys.argv[1]), "position": int(sys.argv[2]), "explanation": sys.argv[3]}))' "$upstream_section" "$pos" "$explanation")
        resp=$(curl -s -X PATCH "$API/status-pages/$SP_ID/resources/$record_id" --config <(bu_auth) \
            -H "Content-Type: application/json" -d "$payload" || echo "")
        if echo "$resp" | grep -q '"id"'; then
            echo -e "  ${GREEN}✓${NC} $name — Upstream providers"
        else
            err=$(echo "$resp" | grep -o '"errors": *"[^"]*"' | head -1)
            echo -e "  ${RED}✗${NC} $name — update failed ${err:-}" >&2
        fi
    }

    ensure_third_party "Cloudflare" 0 "CDN, DNS, WAF and TLS - external provider status"
    ensure_third_party "Hetzner" 1 "Hosting in nbg1 (Nuremberg) - external provider status"
    ensure_third_party "GitHub" 2 "CI/CD, Actions and repository - external provider status"

fi

# ==== Telegram webhooks ====

if [[ -z "${TG_TOKEN:-}" || -z "${TG_CHAT_ID:-}" ]]; then
    echo -e "\n${YELLOW}Skipping webhooks — set TG_TOKEN and TG_CHAT_ID in secrets/.env${NC}"
else
    echo -e "\n${CYAN}Better Stack — Telegram webhooks${NC}\n"

    THREAD="${TG_THREAD_ID:-}"

    existing_wh=$(get_existing_webhooks)

    ensure_webhook() {
        local name="$1" started="$2" resolved="$3" text="$4"
        local wh_json
        # Keep the X's at the end: BSD/macOS mktemp treats a suffix as a literal
        # filename, which makes the second call fail with "File exists".
        wh_json=$(mktemp "${HOME:?}/.tmp_bs_webhook_XXXXXX")
        _SETUP_TMPFILES+=("$wh_json")

        # Check if webhook already exists by name
        existing_id=$(
            echo "$existing_wh" | python3 -c "
import sys, json
target = sys.argv[1]
data = json.load(sys.stdin)
for item in data.get('data', []):
    if item['attributes']['name'] == target:
        print(item['id'])
        break
" "$name" 2>/dev/null
        )

        TG_TOKEN="$TG_TOKEN" python3 - "$name" "$started" "$resolved" "$TG_CHAT_ID" "$THREAD" "$text" "$([[ -n "$existing_id" ]] && echo false || echo true)" "$wh_json" <<'PYEOF' >/dev/null
import os, sys, json

_, name, started, resolved, chat_id, thread, text, for_creation, out_path = sys.argv
started = started.lower() == 'true'
resolved = resolved.lower() == 'true'
for_creation = for_creation.lower() == 'true'
text = text.replace('\\n', '\n')
url = "https://api.telegram.org/bot{}/sendMessage".format(os.environ["TG_TOKEN"])

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
        "message_thread_id": int(thread) if thread else None,
        "parse_mode": "HTML",
        "text": text
    }
}
with open(out_path, "w") as f:
    json.dump(payload, f)
PYEOF

        if [[ -n "$existing_id" ]]; then
            resp=$(curl -s -X PATCH "$API/outgoing-webhooks/$existing_id" --config <(bu_auth) -H "Content-Type: application/json" -d "@$wh_json" || echo "")
            echo -e "  ${GREEN}✓${NC} $name (updated, ID $existing_id)"
        else
            resp=$(curl -s -X POST "$API/outgoing-webhooks" --config <(bu_auth) -H "Content-Type: application/json" -d "@$wh_json" || echo "")
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
