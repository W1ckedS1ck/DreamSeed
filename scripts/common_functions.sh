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

load_env() {
    local env_file="$1"
    [[ ! -f "$env_file" ]] && { echo "Error: file $env_file not found!" >&2; exit 1; }
    while IFS= read -r line; do
        [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || continue
        local key="${line%%=*}" value="${line#*=}"
        # Strip matching outer quotes (single or double)
        if [[ "$value" =~ ^\"(.*)\"$ ]] || [[ "$value" =~ ^\'(.*)\'$ ]]; then
            value="${BASH_REMATCH[1]}"
        fi
        export "$key"="$value"
    done < "$env_file"
    OWNER="${OWNER:-}"
}

detect_env() {
    local h
    h=$(hostname)
    case "$h" in
        *-preprod|*preprod-*) echo "-preprod" ;;
        *-prod|*prod-*)       echo "" ;;
        *)
            if [[ -f /etc/dreamseed.env ]]; then
                grep -q "^ENV=prod" /etc/dreamseed.env 2>/dev/null && echo "" || echo "-preprod"
            else
                echo "-preprod"
            fi
            ;;
    esac
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
    echo "$1" | sed 's/[][_*()~`>#+={|}.!-\\]/\\&/g'
}



