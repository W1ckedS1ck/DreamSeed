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

# secrets/.env is ansible-vault encrypted — decrypt to a temp file first.
_LIST_TMPFILES=()
trap 'for _f in "${_LIST_TMPFILES[@]:-}"; do rm -f "$_f"; done' EXIT
ENV_PLAIN=$(mktemp)
chmod 600 "$ENV_PLAIN"
_LIST_TMPFILES+=("$ENV_PLAIN")
ansible-vault view "$SCRIPT_DIR/secrets/.env" --vault-password-file "${HOME}/.vault_pass_dreamseed" >"$ENV_PLAIN" 2>/dev/null || {
    echo "Error: cannot decrypt secrets/.env" >&2
    exit 1
}
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
        url_suffix = "  (custom: %s)" % cd if cd else ""
        print("  %s" % a.get('company_name', '-'))
        print("    URL:      https://%s.betterstackstatus.com%s" % (sub, url_suffix))
        print("    Timezone: %s" % a.get('timezone', '-'))
        print("    Public:   %s" % public)
        print("    Created:  %s" % a['created_at'])
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

echo -e "${CYAN}══════════════════════════════════════${NC}"
echo -e "Generated: $(date '+%Y-%m-%d %H:%M %Z')"
