#!/bin/bash

# ====== Load secrets ======
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
if [ ! -f "$ENV_FILE" ]; then
    echo "Error: file $ENV_FILE not found!" >&2
    exit 1
fi
# shellcheck source=.env
source "$ENV_FILE"

TOKEN="$TG_TOKEN"
CHAT_ID="$TG_CHAT_ID"
THREAD_ID="$TG_THREAD_ID"

curl -s -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" \
     -d "chat_id=$CHAT_ID" \
     -d "message_thread_id=$THREAD_ID" \
     -d "text=✅ Connection test for topic $THREAD_ID"
