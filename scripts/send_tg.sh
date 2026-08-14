#!/bin/bash
# Send a Telegram message. Single source of truth for Telegram notifications —
# used by both GitHub Actions workflows and local/remote scripts.
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

tg_cfg=$(mktemp) || exit 0
chmod 600 "$tg_cfg"
printf 'url = "https://api.telegram.org/bot%s/sendMessage"\n' "$TG_TOKEN" > "$tg_cfg"

tg_resp=$(curl -s -m 10 -X POST --config "$tg_cfg" \
    --data-urlencode "chat_id=$TG_CHAT_ID" \
    ${TG_THREAD_ID:+--data-urlencode "message_thread_id=$TG_THREAD_ID"} \
    --data-urlencode "parse_mode=$PARSE_MODE" \
    --data-urlencode "text=$MSG" 2>/dev/null) || true
rm -f "$tg_cfg"

if ! echo "$tg_resp" | jq -e '.ok == true' >/dev/null 2>&1; then
    err=$(echo "$tg_resp" | jq -r '.description // "unknown"' 2>/dev/null || echo "unknown")
    echo "WARNING: Telegram send failed: $err" >&2
    exit 1
fi
