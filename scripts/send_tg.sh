#!/bin/bash
# CLI wrapper around common_functions.sh's send_tg(). Usage: send_tg.sh "text" [parse_mode]
# Token stays out of argv (ps aux) — curl reads it from a 0600 temp config file.

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
