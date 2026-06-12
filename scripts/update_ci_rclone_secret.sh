#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RCLONE_CONF="${SCRIPT_DIR}/../secrets/rclone.conf"
REPO="W1ckedS1ck/DreamSeed"

if [ ! -f "$RCLONE_CONF" ]; then
  echo "❌ $RCLONE_CONF not found"
  echo "   Run 'rclone config' first, then copy the [gdrive] section to secrets/rclone.conf"
  exit 1
fi

SIZE=$(wc -c < "$RCLONE_CONF")
if [ "$SIZE" -lt 50 ]; then
  echo "❌ $RCLONE_CONF is too small (${SIZE}B) — looks like a placeholder"
  echo "   Run 'rclone config' and set up a real Google Drive remote"
  exit 1
fi

if ! grep -q '^\[gdrive\]' "$RCLONE_CONF"; then
  echo "❌ $RCLONE_CONF has no [gdrive] section"
  exit 1
fi

echo "=== Updating RCLONE_CONF_BASE64 from $RCLONE_CONF ==="
BASE64=$(base64 -i "$RCLONE_CONF" | tr -d '\n')

if ! gh secret set "RCLONE_CONF_BASE64" --body "$BASE64" --repo "$REPO"; then
  echo "❌ Failed to update secret — is 'gh' authenticated for $REPO?"
  exit 1
fi

echo "✅ RCLONE_CONF_BASE64 updated from $(echo ${SIZE} | awk '{printf "%.0f", $1}')B config"
echo "   Repo: $REPO"
