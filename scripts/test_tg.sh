#!/bin/bash

# ====== Load secrets ======
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common_functions.sh
source "$SCRIPT_DIR/common_functions.sh"
load_env "$SCRIPT_DIR/.env"

curl -s -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
     -d "chat_id=$TG_CHAT_ID" \
     -d "message_thread_id=$TG_THREAD_ID" \
     -d "text=✅ Connection test for topic $TG_THREAD_ID"
