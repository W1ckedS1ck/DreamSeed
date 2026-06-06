#!/bin/bash
# Better Stack Uptime inventory — lists monitors, heartbeats, and status pages.
# Portfolio documentation script. Read-only, no side effects.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/common_functions.sh
source "$SCRIPT_DIR/scripts/common_functions.sh"
load_env "$SCRIPT_DIR/secrets/.env"

[[ -z "${BETTERUPTIME_API_TOKEN:-}" ]] && { echo "Error: BETTERUPTIME_API_TOKEN not set in secrets/.env"; exit 1; }

API="https://uptime.betterstack.com/api/v2"
AUTH="Authorization: Bearer $BETTERUPTIME_API_TOKEN"

CYAN='\033[0;36m'; NC='\033[0m'

echo -e "${CYAN}══════════════════════════════════════${NC}"
echo -e "${CYAN}  Better Stack — Uptime Inventory${NC}"
echo -e "${CYAN}══════════════════════════════════════${NC}\n"

# Helper: fetch JSON, run Python with heredoc
fetch_and_format() {
    local endpoint="$1" label="$2"
    local json_tmp py_tmp
    json_tmp=$(mktemp /tmp/bs_json_XXXXXX)
    py_tmp=$(mktemp /tmp/bs_py_XXXXXX)
    curl -s "$API/$endpoint" -H "$AUTH" > "$json_tmp"

    cat > "$py_tmp" << 'PYEOF'
import sys, json
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
        print("  %s" % a['name'])
        print("    URL:      %s" % a['url'])
        print("    Trigger:  %s" % a['trigger_type'])
        print("    Events:   %s" % ', '.join(triggers))
        print()

    elif t == 'status_page':
        sub = a.get('subdomain', '')
        cd = a.get('custom_domain', '')
        public = 'no' if a.get('whitelabeled') else 'yes'
        url_suffix = "  (custom: %s)" % cd if cd else ""
        print("  %s" % a.get('company_name', '-'))
        print("    URL:      https://%s.betterstackstatus.com%s" % (sub, url_suffix))
        print("    Timezone: %s" % a.get('timezone', '-'))
        print("    Public:   %s" % public)
        print("    Created:  %s" % a['created_at'])
        print()
PYEOF

    echo -e "${CYAN}${label}${NC}"
    printf "${CYAN}%s${NC}\n" "$(printf '─%.0s' $(eval "echo {1..${#label}}"))"
    python3 "$py_tmp" "$json_tmp"

    rm -f "$json_tmp" "$py_tmp"
}

fetch_and_format "monitors" "MONITORS"
fetch_and_format "heartbeats" "HEARTBEATS"
fetch_and_format "outgoing-webhooks" "OUTGOING WEBHOOKS"
fetch_and_format "status-pages" "STATUS PAGES"

echo -e "${CYAN}══════════════════════════════════════${NC}"
echo -e "Generated: $(date '+%Y-%m-%d %H:%M %Z')"
