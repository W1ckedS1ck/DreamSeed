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
    [[ -n "${VAULT_TMP:-}" && -f "${VAULT_TMP:-}" ]] && rm -f "$VAULT_TMP"
    [[ -n "${ENV_DECRYPTED_TMP:-}" && -f "${ENV_DECRYPTED_TMP:-}" ]] && rm -f "$ENV_DECRYPTED_TMP"
    [[ -n "${TF_TMP_OUT:-}" && -f "${TF_TMP_OUT:-}" ]] && rm -f "$TF_TMP_OUT"
    [[ -n "${LOCK_FILE:-}" && -d "${LOCK_FILE:-}" ]] && rmdir "$LOCK_FILE" 2>/dev/null || true
}

yaml_escape() {
    local val="$1"
    val="${val//\'/\'\'}"
    printf '%s' "$val"
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
    while IFS= read -r f; do rm -f "$f"; done < <(ls -1t "$LOG_DIR"/deploy_2*.log 2>/dev/null | tail -n +$((max + 1))) 2>/dev/null || true
    while IFS= read -r f; do rm -f "$f"; done < <(ls -1t "$LOG_DIR"/terraform_2*.log 2>/dev/null | tail -n +$((max + 1))) 2>/dev/null || true
    # Rotate deploy_history.log if too large (keep last 500 lines)
    if [[ -f "$LOG_DIR/deploy_history.log" && $(wc -l < "$LOG_DIR/deploy_history.log") -gt 500 ]]; then
        mv "$LOG_DIR/deploy_history.log" "$LOG_DIR/deploy_history.old.log" 2>/dev/null || true
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
