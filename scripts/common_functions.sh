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
    while IFS='=' read -r key value; do
        [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
        value="${value#\"}" ; value="${value%\"}"
        value="${value#\'}" ; value="${value%\'}"
        export "$key=$value"
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
    local tg_url="https://api.telegram.org/bot${TG_TOKEN}/sendMessage"
    local data=(
        --data-urlencode "chat_id=$TG_CHAT_ID"
        --data-urlencode "text=$1"
        --data-urlencode "parse_mode=MarkdownV2"
    )
    [[ -n "${TG_THREAD_ID:-}" ]] && data+=(--data-urlencode "message_thread_id=$TG_THREAD_ID")
    curl -s -X POST "$tg_url" "${data[@]}" > /dev/null 2>&1
}

escape_md2() {
    echo "$1" | sed 's/[][_*()~`>#+={|}.!-\\]/\\&/g'
}

