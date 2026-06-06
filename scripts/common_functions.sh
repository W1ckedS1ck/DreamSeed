#!/bin/bash
# Shared functions for DreamSeed scripts. Source this file, do not execute directly.

# shellcheck disable=SC2034  # color vars are consumed by sourcing scripts
GREEN=$'\033[0;32m'
# shellcheck disable=SC2034
YELLOW=$'\033[1;33m'
# shellcheck disable=SC2034
RED=$'\033[0;31m'
# shellcheck disable=SC2034
CYAN=$'\033[0;36m'
# shellcheck disable=SC2034
NC=$'\033[0m'

# Backup rotation defaults (can be overridden via environment)
BACKUP_PROJECT_KEEP="${BACKUP_PROJECT_KEEP:-5}"
BACKUP_DB_KEEP="${BACKUP_DB_KEEP:-15}"

load_env() {
    local env_file="$1"
    [[ ! -f "$env_file" ]] && { echo "Error: file $env_file not found!" >&2; exit 1; }
    local blocked_vars='^(PATH|LD_PRELOAD|LD_LIBRARY_PATH|IFS|BASH_ENV|SHELL|SHELLOPTS|BASHOPPS|BASH_FUNC_.*)$'
    while IFS= read -r line; do
        line="${line#export }"
        [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || continue
        local key="${line%%=*}" value="${line#*=}"
        [[ "$key" =~ $blocked_vars ]] && continue
        # Strip matching outer quotes (single or double)
        if [[ "$value" =~ ^\"(.*)\"$ ]] || [[ "$value" =~ ^\'(.*)\'$ ]]; then
            value="${BASH_REMATCH[1]}"
        fi
        export "$key"="$value"
    done < "$env_file"
    OWNER="${OWNER:-}"
}

detect_env() {
    if [[ -f "$SCRIPT_DIR/.env" ]]; then
        grep -q "^ENV=prod" "$SCRIPT_DIR/.env" 2>/dev/null && echo "" || echo "-dev"
    else
        local h
        h=$(hostname)
        case "$h" in
            *-prod|*prod-*) echo "" ;;
            *) echo "-dev" ;;
        esac
    fi
}

format_env_display() {
    local env="$1"
    if [ -z "$env" ]; then
        echo "prod"
    else
        echo "$env"
    fi
}

format_env_escaped() {
    local env="$1"
    if [ -z "$env" ]; then
        echo "*PROD*"
    else
        echo "***$(escape_md2 "$env")***"
    fi
}

format_name() {
    basename "$1" | sed 's/DreamSeed_//; s/db_modx_db_//; s/.tar.gz//; s/.sql.gz//; s/_/ /'
}

send_tg() {
    local text="$1"
    local parse_mode="${2:-MarkdownV2}"
    local tg_url="https://api.telegram.org/bot${TG_TOKEN}/sendMessage"
    local data=(
        --data-urlencode "chat_id=$TG_CHAT_ID"
        --data-urlencode "text=$text"
        --data-urlencode "parse_mode=$parse_mode"
    )
    [[ -n "${TG_THREAD_ID:-}" ]] && data+=(--data-urlencode "message_thread_id=$TG_THREAD_ID")
    curl -s -X POST "$tg_url" "${data[@]}" > /dev/null 2>&1
}

ping_heartbeat() {
    local key="${1:-}"
    [[ -z "$key" ]] && return 0
    curl -fsS -m 10 --retry 3 "https://uptime.betterstack.com/api/v1/heartbeat/$key" > /dev/null 2>&1
}

prune_cloud_backups() {
    local subdir="$1" max="$2"
    local all
    all=$(rclone lsf "$RCLONE_REMOTE:$REMOTE_BASE/${subdir}${ENV}/" --files-only 2>/dev/null | sort -r) || return 1
    local count
    count=$(printf '%s\n' "$all" | grep -c '[^[:space:]]')
    if [ "$count" -gt "$max" ]; then
        printf '%s\n' "$all" | tail -n +$((max + 1)) | while read -r file; do
            [ -n "$file" ] && rclone delete "$RCLONE_REMOTE:$REMOTE_BASE/${subdir}${ENV}/$file"
        done
    fi
}

escape_md2() {
    echo "$1" | sed 's/[_*\[\]()~`>#+=|{}.!@:-]/\\&/g'
}

rotate_files() {
    local pattern="$1"
    local keep="$2"
    local dir glob
    dir=$(dirname "$pattern")
    glob=$(basename "$pattern")
    mapfile -t files < <(find "$dir" -maxdepth 1 -name "$glob" -printf '%T@ %p\n' 2>/dev/null | sort -rn | cut -d' ' -f2-)
    if [ "${#files[@]}" -gt "$keep" ]; then
        for ((i=keep; i<${#files[@]}; i++)); do
            rm -f "${files[i]}"
        done
    fi
}

export_metric() {
    local payload="$1"
    echo "$payload" | curl -s --data-binary @- "http://127.0.0.1:8428/api/v1/import/prometheus" > /dev/null 2>&1 || true
}
