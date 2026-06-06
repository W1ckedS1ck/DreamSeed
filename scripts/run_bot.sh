#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR" || exit 1
source "$SCRIPT_DIR/common_functions.sh"
load_env "$SCRIPT_DIR/.env"
exec "$(command -v python3)" "$SCRIPT_DIR/telegram_bot.py"
