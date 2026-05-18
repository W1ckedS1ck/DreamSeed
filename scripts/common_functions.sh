#!/bin/bash
# Shared functions for DreamSeed scripts. Source this file, do not execute directly.

GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
RED=$'\033[0;31m'
CYAN=$'\033[0;36m'
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
        *-prod|*prod-*)  echo "" ;;
        *)               echo "-preprod" ;;
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
    curl -s -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
         -d chat_id="$TG_CHAT_ID" \
         -d "message_thread_id=$TG_THREAD_ID" \
         -d parse_mode="MarkdownV2" \
         -d text="$1" >/dev/null 2>&1
}

escape_md2() {
    echo "$1" | sed 's/[][_*()~`>#+={|}.!-]/\\&/g'
}

# "2026-04-05_15-00" → "2026-04-05 15:00"
to_dt() {
    echo "$1" | sed 's/\([0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}\)_\([0-9]\{2\}\)-\([0-9]\{2\}\)/\1 \2:\3/'
}
