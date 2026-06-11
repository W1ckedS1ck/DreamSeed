# Shared helper functions for deploy.sh
# Sourced by deploy.sh — do not execute directly.
# shellcheck shell=bash

format_time() {
    local s=$1
    if [[ $s -ge 3600 ]]; then printf "%dh %02dm %02ds" $((s/3600)) $(((s%3600)/60)) $((s%60))
    elif [[ $s -ge 60 ]]; then printf "%dm %02ds" $((s/60)) $((s%60))
    else printf "%ds" "$s"; fi
}

log() { echo "[$(date '+%H:%M:%S')] $*" >> "$LOG"; }

step_start() {
    STEP_START=$(date +%s)
    STEP_LABEL="$*"
    log "▶ $*"
    if [[ "$TTY" == "true" ]]; then
        printf "\n  \033[1m▶ %s\033[0m\n" "$*"
    else
        printf "\n  ▶ %s\n" "$*"
    fi
}

step_ok() {
    local d=$(( $(date +%s) - STEP_START ))
    STEP_NAMES+=("$STEP_LABEL"); STEP_TIMES+=("$d")
    log "✓ $STEP_LABEL (elapsed: $(format_time $d))"
    if [[ "$TTY" == "true" ]]; then
        printf "  ${GREEN}✓${NC} %s (${YELLOW}%s${NC})\n" "$STEP_LABEL" "$(format_time $d)"
    else
        printf "  ✓ %s (%s)\n" "$STEP_LABEL" "$(format_time $d)"
    fi
}

step_fail() {
    log "✗ $*"
    if [[ "$TTY" == "true" ]]; then
        printf "\n  ${RED}✗${NC} %s\n" "$*"
    else
        printf "\n  ✗ %s\n" "$*"
        echo "::error title=${STEP_LABEL:-Deploy}::$1"
    fi
    write_deploy_history "FAILURE" "$*"
    exit 1
}

cleanup() {
    [[ -n "${DEPLOY_VARS_TMP:-}" && -f "${DEPLOY_VARS_TMP:-}" ]] && rm -f "$DEPLOY_VARS_TMP"
    [[ -n "${ENV_DECRYPTED_TMP:-}" && -f "${ENV_DECRYPTED_TMP:-}" ]] && rm -f "$ENV_DECRYPTED_TMP"
    [[ -n "${TF_TMP_OUT:-}" && -f "${TF_TMP_OUT:-}" ]] && rm -f "$TF_TMP_OUT"
    [[ -n "${LOCK_FILE:-}" ]] && rm -f "$LOCK_FILE" 2>/dev/null || true
}

write_deploy_history() {
    local status="$1" msg="${2:-}" ts dur
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    dur=$(( $(date +%s) - DEPLOY_START ))
    printf "%s | %-7s | %-8s | %-6s | %-15s | %5ss | v%s" \
        "$ts" "$status" "$TARGET" "${WEB_SERVER:-N/A}" "${SERVER_IP:-N/A}" "$dur" "$VERSION" >> "$DEPLOY_HISTORY"
    [[ -n "$msg" ]] && printf " | %s" "$msg" >> "$DEPLOY_HISTORY"
    echo >> "$DEPLOY_HISTORY"
}

rotate_logs() {
    local max="${MAX_LOG_FILES:-10}" f
    (( max < 1 )) && max=1
    while IFS= read -r f; do rm -f "$f"; done < <(ls -1t "$LOG_DIR"/deploy_2*.log 2>/dev/null | tail -n +$((max + 1))) 2>/dev/null || true
    while IFS= read -r f; do rm -f "$f"; done < <(ls -1t "$LOG_DIR"/terraform_2*.log 2>/dev/null | tail -n +$((max + 1))) 2>/dev/null || true
    # Rotate deploy_history.log with timestamp (keep last 10 archives)
    if [[ -f "$LOG_DIR/deploy_history.log" && $(wc -l < "$LOG_DIR/deploy_history.log") -gt 500 ]]; then
        mv "$LOG_DIR/deploy_history.log" "$LOG_DIR/deploy_history_$(date +%s).log" 2>/dev/null || true
        while IFS= read -r f; do rm -f "$f"; done < <(ls -1t "$LOG_DIR"/deploy_history_*.log 2>/dev/null | tail -n +$((max + 1))) 2>/dev/null || true
    fi
}

update_cloudflare_dns() {
    local domain="$1" ip="$2"
    [[ -z "${CLOUDFLARE_API_TOKEN:-}" ]] && {
        log "Cloudflare DNS: skip (CLOUDFLARE_API_TOKEN not set)"
        return 0
    }

    # Resolve zone ID from domain (API token must have Zone:Read access)
    local zone_id zone_name api_base
    api_base="https://api.cloudflare.com/client/v4"
    zone_id=$(curl -s -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
        "$api_base/zones?name=${domain#*.}" | python3 -c "
import json,sys
d=json.load(sys.stdin)
zones=d.get('result',[])
if zones:
    print(zones[0]['id'])
" 2>/dev/null || echo "")

    [[ -z "$zone_id" ]] && { log "Cloudflare DNS: skip (no zone found for $domain)"; return 0; }

    local base="$api_base/zones/$zone_id/dns_records"
    local type="A"

    local existing
    existing=$(curl -s -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
        "$base?type=$type&name=$domain" 2>/dev/null)
    local count
    count=$(echo "$existing" | python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d.get('result',[])))" 2>/dev/null || echo 0)

    if [[ "$count" -gt 0 ]]; then
        local record_id old_ip
        record_id=$(echo "$existing" | python3 -c "import json,sys; print(json.load(sys.stdin)['result'][0]['id'])")
        old_ip=$(echo "$existing" | python3 -c "import json,sys; print(json.load(sys.stdin)['result'][0]['content'])")
        [[ "$old_ip" == "$ip" ]] && { log "Cloudflare DNS: $domain → $ip (unchanged)"; return 0; }
        curl -s -X PUT "$base/$record_id" \
            -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
            -H "Content-Type: application/json" \
            -d "{\"type\":\"$type\",\"name\":\"$domain\",\"content\":\"$ip\",\"ttl\":120,\"proxied\":true}" >/dev/null 2>&1
        log "Cloudflare DNS: $domain $old_ip → $ip"
    else
        curl -s -X POST "$base" \
            -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
            -H "Content-Type: application/json" \
            -d "{\"type\":\"$type\",\"name\":\"$domain\",\"content\":\"$ip\",\"ttl\":120,\"proxied\":true}" >/dev/null 2>&1
        log "Cloudflare DNS: $domain → $ip (created)"
    fi
    echo "  ✓ Cloudflare DNS: $domain → $ip"
}

print_summary() {
    echo ""
    echo "  ──────────────────────────────────────────────────────"
    printf "  %-5s %-35s %s\n" "" "Step" "Time"
    echo "  ──────────────────────────────────────────────────────"
    local i
    for i in "${!STEP_NAMES[@]}"; do
        printf "  %-40s ${YELLOW}%s${NC}\n" "${STEP_NAMES[$i]}" "$(format_time "${STEP_TIMES[$i]}")"
    done
    echo "  ──────────────────────────────────────────────────────"
    local total=$(( $(date +%s) - DEPLOY_START ))
    printf "  %-40s ${YELLOW}%s${NC}\n" "Total" "$(format_time $total)"
}
