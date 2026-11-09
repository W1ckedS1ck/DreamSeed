#!/bin/bash
# Type: manual
# Better Stack Uptime inventory — lists monitors, heartbeats, and status pages.
# Portfolio documentation script. Read-only, no side effects.

set -euo pipefail

# Ensure HOME is set for temp directories
export HOME="${HOME:?ERROR: HOME environment variable not set}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/common_functions.sh
source "$SCRIPT_DIR/scripts/common_functions.sh"

# secrets/.env may be ansible-vault encrypted (local) or plaintext (CI).
_LIST_TMPFILES=()
# shellcheck disable=SC2154 # _f is assigned by the for-loop inside this same trap string
trap 'for _f in "${_LIST_TMPFILES[@]:-}"; do rm -f "$_f"; done' EXIT
ENV_PLAIN=$(mktemp)
chmod 600 "$ENV_PLAIN"
_LIST_TMPFILES+=("$ENV_PLAIN")
resolve_env_plain "$SCRIPT_DIR/secrets/.env" "${HOME}/.vault_pass_dreamseed" >"$ENV_PLAIN" || exit 1
load_env "$ENV_PLAIN"

[[ -z "${BETTERUPTIME_API_TOKEN:-}" ]] && {
    echo "Error: BETTERUPTIME_API_TOKEN not set in secrets/.env"
    exit 1
}

API="https://uptime.betterstack.com/api/v2"
bu_auth() { printf 'header = "Authorization: Bearer %s"\n' "$BETTERUPTIME_API_TOKEN"; }

CYAN=$'\033[0;36m'
NC=$'\033[0m'

echo -e "${CYAN}══════════════════════════════════════${NC}"
echo -e "${CYAN}  Better Stack — Uptime Inventory${NC}"
echo -e "${CYAN}══════════════════════════════════════${NC}\n"

# Helper: fetch JSON, run Python with heredoc
fetch_and_format() {
    local endpoint="$1" label="$2"
    local json_tmp py_tmp
    json_tmp=$(mktemp "${HOME:?}/.tmp_bs_json_XXXXXX")
    py_tmp=$(mktemp "${HOME:?}/.tmp_bs_py_XXXXXX")
    _LIST_TMPFILES+=("$json_tmp" "$py_tmp")
    curl -s "$API/$endpoint" --config <(bu_auth) >"$json_tmp"

    cat >"$py_tmp" <<'PYEOF'
import sys, json, re
with open(sys.argv[1]) as f:
    data = json.load(f)
for item in data.get('data', []):
    a = item['attributes']
    t = item['type']
    if t == 'monitor':
        kw = "  keyword: '%s'" % a['required_keyword'] if a.get('required_keyword') else ''
        regions = ','.join(a.get('regions', []))
        print("  %s" % a['pronounceable_name'])
        print("    URL:      %s" % a['url'])
        print("    Type:     %s %s" % (a['monitor_type'], kw))
        print("    Status:   %s" % a['status'])
        print("    Interval: %ss" % a['check_frequency'])
        print("    Timeout:  %ss" % a['request_timeout'])
        print("    Regions:  %s" % regions)
        ssl = 'yes' if a.get('verify_ssl') else 'no'
        em = 'yes' if a.get('email') else 'no'
        pu = 'yes' if a.get('push') else 'no'
        print("    SSL:      %s" % ssl)
        print("    Alert:    email=%s  push=%s" % (em, pu))
        print("    Team:     %s" % a.get('team_name', '-'))
        print("    Created:  %s" % a['created_at'])
        print()
    elif t == 'heartbeat':
        period_h = a['period'] // 3600
        period_m = (a['period'] % 3600) // 60
        grace_m = a['grace'] // 60
        em = 'yes' if a.get('email') else 'no'
        pu = 'yes' if a.get('push') else 'no'
        paused = 'yes' if a.get('paused') else 'no'
        print("  %s" % a['name'])
        print("    Status:   %s" % a['status'])
        print("    Period:   %ss  (%sh %sm)" % (a['period'], period_h, period_m))
        print("    Grace:    %ss  (%sm)" % (a['grace'], grace_m))
        print("    Alert:    email=%s  push=%s" % (em, pu))
        print("    Paused:   %s" % paused)
        print("    Created:  %s" % a['created_at'])
        print()
    elif t == 'outgoing_webhook':
        triggers = []
        if a.get('on_incident_started'): triggers.append('started')
        if a.get('on_incident_resolved'): triggers.append('resolved')
        if a.get('on_incident_acknowledged'): triggers.append('ack')
        # Webhook URL may embed secrets (e.g. Telegram bot token) — redact any botXX:token
        url = a['url']
        url = re.sub(r'(bot\d+):[A-Za-z0-9_-]+', r'\1:****REDACTED****', url)
        print("  %s" % a['name'])
        print("    URL:      %s" % url)
        print("    Trigger:  %s" % a['trigger_type'])
        print("    Events:   %s" % ', '.join(triggers))
        print()

    elif t == 'status_page':
        sub = a.get('subdomain', '')
        cd = a.get('custom_domain', '')
        public = 'no' if a.get('whitelabeled') else 'yes'
        url = "https://%s" % cd if cd else "https://%s.betterstackstatus.com" % sub
        nav = ', '.join('%s -> %s' % (x.get('text', '-'), x.get('href', '-'))
                        for x in a.get('navigation_links', []))
        print("  %s" % a.get('company_name', '-'))
        print("    URL:          %s" % url)
        print("    Timezone:     %s" % a.get('timezone', '-'))
        print("    Public:       %s" % public)
        print("    Design:       %s" % a.get('design', '-'))
        print("    Auto reports: %s" % a.get('automatic_reports'))
        print("    Min incident: %ss" % a.get('min_incident_length'))
        print("    Subscribable: %s" % a.get('subscribable'))
        print("    Announcement: %s" % (a.get('announcement') or '-'))
        print("    Nav links:    %s" % (nav or '-'))
        print("    Created:      %s" % a['created_at'])
        print()
PYEOF

    echo -e "${CYAN}${label}${NC}"
    printf "${CYAN}%*s${NC}\n" "${#label}" | tr ' ' '─'
    python3 "$py_tmp" "$json_tmp"
}

fetch_and_format "monitors" "MONITORS"
fetch_and_format "heartbeats" "HEARTBEATS"
fetch_and_format "outgoing-webhooks" "OUTGOING WEBHOOKS"
fetch_and_format "status-pages" "STATUS PAGES"

# Sections and resources are children of the (single) status page.
SP_ID=$(curl -s "$API/status-pages" --config <(bu_auth) \
    | python3 -c "import sys,json; d=json.load(sys.stdin).get('data',[]); print(d[0]['id'] if d else '')" 2>/dev/null)

if [[ -n "$SP_ID" ]]; then
    label="STATUS PAGE SECTIONS"
    echo -e "${CYAN}${label}${NC}"
    printf "${CYAN}%*s${NC}\n" "${#label}" | tr ' ' '─'
    curl -s "$API/status-pages/$SP_ID/sections?per_page=50" --config <(bu_auth) \
        | python3 -c "
import sys, json
for s in json.load(sys.stdin).get('data', []):
    a = s['attributes']
    print('  %s (position %s)' % (a.get('name', '-'), a.get('position', '-')))
"
    echo

    label="STATUS PAGE RESOURCES"
    echo -e "${CYAN}${label}${NC}"
    printf "${CYAN}%*s${NC}\n" "${#label}" | tr ' ' '─'
    curl -s "$API/status-pages/$SP_ID/resources?per_page=50" --config <(bu_auth) \
        | python3 -c "
import sys, json
for r in json.load(sys.stdin).get('data', []):
    a = r['attributes']
    print('  %-24s %-16s %-12s pos=%s section=%s' % (
        a.get('public_name', '-'),
        a.get('resource_type', '-'),
        a.get('status', '-'),
        a.get('position', '-'),
        a.get('status_page_section_id', '-')))
    if a.get('explanation'):
        print('    %s' % a['explanation'])
"
    echo
fi

echo -e "${CYAN}══════════════════════════════════════${NC}"
echo -e "Generated: $(date '+%Y-%m-%d %H:%M %Z')"
