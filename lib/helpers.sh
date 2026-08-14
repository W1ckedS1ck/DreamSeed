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
    if [[ -n "${DEPLOY_VARS_TMP:-}" && -d "${DEPLOY_VARS_TMP:-}" ]]; then
        if command -v shred &>/dev/null; then
            find "$DEPLOY_VARS_TMP" -type f -exec shred -u {} + 2>/dev/null || true
        fi
        rm -rf "$DEPLOY_VARS_TMP"
    fi
    if [[ -n "${ENV_DECRYPTED_TMP:-}" && -f "${ENV_DECRYPTED_TMP:-}" ]]; then
        if command -v shred &>/dev/null; then
            shred -u "$ENV_DECRYPTED_TMP" 2>/dev/null || true
        else
            rm -f "$ENV_DECRYPTED_TMP"
        fi
    fi
    [[ -n "${TF_TMP_OUT:-}" && -f "${TF_TMP_OUT:-}" ]] && rm -f "$TF_TMP_OUT" || true
    [[ -n "${TF_STATE_BACKUP_TMP:-}" && -f "${TF_STATE_BACKUP_TMP:-}" ]] && rm -f "$TF_STATE_BACKUP_TMP" || true
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

_cfcurl() { curl -s --connect-timeout 5 --max-time 15 "$@"; }

# Resolve Cloudflare zone ID from a (sub)domain by walking labels down to the
# registrable zone, e.g. ssh.aws.vitalikuts.online → vitalikuts.online.
# Works for any nesting depth; apex domains resolve on the first attempt.
_cf_zone_id() {
    local domain="$1"
    [[ -z "${CLOUDFLARE_API_TOKEN:-}" ]] && { log "Cloudflare: CLOUDFLARE_API_TOKEN not set"; return 1; }
    local api_base="https://api.cloudflare.com/client/v4"
    local candidate="$domain"
    local zone_id=""
    while [[ "$candidate" == *.* ]]; do
        zone_id=$(_cfcurl -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
            "$api_base/zones?name=$candidate" | jq -r '.result[0].id // ""' 2>/dev/null) || zone_id=""
        [[ -n "$zone_id" ]] && { echo "$zone_id"; return 0; }
        candidate="${candidate#*.}"
    done
    log "Cloudflare: no zone found for $domain"
    return 1
}

update_cloudflare_dns() {
    local domain="$1" ip="$2"
    [[ -z "${CLOUDFLARE_API_TOKEN:-}" ]] && { log "Cloudflare DNS: skip (token not set)"; return 0; }
    local api_base="https://api.cloudflare.com/client/v4"
    local zone_id
    zone_id=$(_cf_zone_id "$domain") || return 1
    local base="$api_base/zones/$zone_id/dns_records"
    local type="A"

    local existing
    existing=$(_cfcurl -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
        "$base?type=$type&name=$domain" 2>/dev/null || true)

    # Single jq pass: parse existing records → count, id, old_ip
    IFS='|' read -r count record_id old_ip < <(echo "$existing" | jq -r '.result | length as $c | "\($c)|\(. [0].id // "")|\(. [0].content // "")"' 2>/dev/null) || { count=0; record_id=; old_ip=; }

    local ttl="${CLOUDFLARE_DNS_TTL:-120}"
    local dns_body
    # Build JSON via jq (not printf) — escapes special chars in domain/ip and
    # validates ttl as a number (errors out if non-numeric, preventing injection).
    dns_body=$(jq -nc --arg type "$type" --arg name "$domain" --arg content "$ip" \
        --argjson ttl "$ttl" --argjson proxied true \
        '{type:$type,name:$name,content:$content,ttl:$ttl,proxied:$proxied}') || {
        log "Cloudflare DNS: invalid ttl '$ttl' (must be a number)"
        echo "  ✗ Cloudflare DNS: invalid ttl '$ttl' (must be a number)" >&2
        return 1
    }

    if [[ "$count" -gt 0 ]]; then
        [[ "$old_ip" == "$ip" ]] && { log "Cloudflare DNS: $domain → $ip (unchanged)"; return 0; }
        if _cfcurl --retry 1 --retry-delay 3 -X PUT "$base/$record_id" \
            -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
            -H "Content-Type: application/json" \
            -d "$dns_body" | jq -e '.success' >/dev/null 2>&1; then
            log "Cloudflare DNS: $domain $old_ip → $ip"
            echo "  ✓ Cloudflare DNS: $domain → $ip"
            return 0
        else
            log "Cloudflare DNS: UPDATE FAILED for $domain"
            echo "  ✗ Cloudflare DNS: update failed (check token/permissions)"
            return 1
        fi
    else
        if _cfcurl --retry 1 --retry-delay 3 -X POST "$base" \
            -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
            -H "Content-Type: application/json" \
            -d "$dns_body" | jq -e '.success' >/dev/null 2>&1; then
            log "Cloudflare DNS: $domain → $ip (created)"
            echo "  ✓ Cloudflare DNS: $domain → $ip"
            return 0
        else
            log "Cloudflare DNS: CREATE FAILED for $domain"
            echo "  ✗ Cloudflare DNS: create failed (check token/permissions)"
            return 1
        fi
    fi
}

delete_cloudflare_dns() {
    local domain="$1"
    [[ -z "${CLOUDFLARE_API_TOKEN:-}" ]] && { log "Cloudflare DNS cleanup: skip (token not set)"; echo "  — Cloudflare DNS: skipped (token not set)"; return 0; }
    local api_base="https://api.cloudflare.com/client/v4"
    local zone_id
    zone_id=$(_cf_zone_id "$domain") || return 0
    local base="$api_base/zones/$zone_id/dns_records"

    local existing
    existing=$(_cfcurl -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
        "$base?type=A&name=$domain" 2>/dev/null || true)

    local record_id
    record_id=$(echo "$existing" | jq -r '.result[0].id // ""' 2>/dev/null) || record_id=""

    [[ -z "$record_id" ]] && { log "Cloudflare DNS cleanup: no A record found for $domain"; echo "  — Cloudflare DNS: no A record found"; return 0; }

    if _cfcurl --retry 1 --retry-delay 3 -X DELETE "$base/$record_id" \
        -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
        -H "Content-Type: application/json" | jq -e '.success' >/dev/null 2>&1; then
        log "Cloudflare DNS: deleted A record for $domain"
        echo "  ✓ Cloudflare DNS: deleted $domain"
    else
        log "Cloudflare DNS: DELETE FAILED for $domain"
        echo "  ✗ Cloudflare DNS: delete failed (check token/permissions)"
    fi
}

# Update Cloudflare DNS A record WITHOUT proxy (grey cloud) — for SSH access
update_cloudflare_dns_direct() {
    local subdomain="$1" ip="$2"
    [[ -z "${CLOUDFLARE_API_TOKEN:-}" ]] && { log "Cloudflare direct DNS: skip (token not set)"; return 0; }
    local zone_id
    zone_id=$(_cf_zone_id "$subdomain") || return 1
    local base="https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records"
    local ttl="${CLOUDFLARE_DNS_TTL:-120}"

    local existing
    existing=$(_cfcurl -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" "$base?type=A&name=$subdomain" 2>/dev/null || true)

    IFS='|' read -r count record_id old_ip < <(echo "$existing" | jq -r '.result | length as $c | "\($c)|\(. [0].id // "")|\(. [0].content // "")"' 2>/dev/null) || { count=0; record_id=; old_ip=; }

    local dns_body
    # Build JSON via jq (not printf) — escapes special chars in subdomain/ip and
    # validates ttl as a number (errors out if non-numeric, preventing injection).
    dns_body=$(jq -nc --arg name "$subdomain" --arg content "$ip" \
        --argjson ttl "$ttl" --argjson proxied false \
        '{type:"A",name:$name,content:$content,ttl:$ttl,proxied:$proxied}') || {
        log "Cloudflare direct DNS: invalid ttl '$ttl' (must be a number)"
        echo "  ⚠ SSH DNS: invalid ttl '$ttl' (must be a number)" >&2
        return 1
    }

    if [[ "$count" -gt 0 ]]; then
        [[ "$old_ip" == "$ip" ]] && { log "Cloudflare direct DNS: $subdomain → $ip (unchanged)"; return 0; }
        if _cfcurl --retry 1 --retry-delay 3 -X PUT "$base/$record_id" \
            -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
            -H "Content-Type: application/json" \
            -d "$dns_body" > /dev/null 2>&1; then
            log "Cloudflare direct DNS: $subdomain → $ip"
            echo "  ✓ SSH DNS: $subdomain → $ip"
            return 0
        else
            log "Cloudflare direct DNS: UPDATE FAILED for $subdomain"
            echo "  ⚠ SSH DNS: update failed (check token/permissions)"
            return 1
        fi
    else
        if _cfcurl --retry 1 --retry-delay 3 -X POST "$base" \
            -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
            -H "Content-Type: application/json" \
            -d "$dns_body" > /dev/null 2>&1; then
            log "Cloudflare direct DNS: $subdomain → $ip (created)"
            echo "  ✓ SSH DNS: $subdomain → $ip"
            return 0
        else
            log "Cloudflare direct DNS: CREATE FAILED for $subdomain"
            echo "  ⚠ SSH DNS: $subdomain create failed (check token/permissions)"
            return 1
        fi
    fi
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
