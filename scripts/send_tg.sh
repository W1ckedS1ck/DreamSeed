#!/bin/bash
# Send a Telegram message. Thin CLI wrapper around common_functions.sh's
# send_tg() — that function is the single source of truth for the actual
# HTTP call, shared with scripts that source common_functions.sh directly.
#
# Reads TG_TOKEN / TG_CHAT_ID / TG_THREAD_ID from the environment.
# Usage: send_tg.sh "message text" [parse_mode]   (parse_mode default: HTML)
#
# The bot token stays out of argv (ps aux) — curl reads the URL from a
# 0600 temp config file instead of a command-line argument.

set -euo pipefail

if [[ $# -lt 1 || -z "$1" ]]; then
    echo "Usage: send_tg.sh <message> [parse_mode]" >&2
    exit 1
fi
MSG="$1"
PARSE_MODE="${2:-HTML}"

[[ -n "${TG_TOKEN:-}" && -n "${TG_CHAT_ID:-}" ]] || {
    echo "WARNING: TG_TOKEN/TG_CHAT_ID not set — message skipped" >&2
    exit 0
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common_functions.sh
source "$SCRIPT_DIR/common_functions.sh"

send_tg "$MSG" "$PARSE_MODE"
