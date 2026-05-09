#!/bin/bash
# Push all CI/CD secrets to GitHub Actions.
# Run once locally after: gh auth login
# Usage: ./scripts/push-secrets.sh

set -euo pipefail

REPO="W1ckedS1ck/DreamSeed"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

if ! gh auth status &>/dev/null; then
    echo -e "${RED}Error:${NC} gh CLI not authenticated."
    echo "Run: gh auth login"
    exit 1
fi

push() {
    local name="$1" file="$2" encode="${3:-plain}"
    if [[ ! -f "$file" ]]; then
        echo -e "  ${YELLOW}skip${NC}  $name  (file not found: $file)"
        return
    fi
    if [[ "$encode" == "base64" ]]; then
        base64 -i "$file" | tr -d '\n' | gh secret set "$name" --repo "$REPO"
    else
        gh secret set "$name" --repo "$REPO" < "$file"
    fi
    echo -e "  ${GREEN}✓${NC}  $name"
}

echo "Pushing secrets to $REPO..."
echo ""

push "ENV_FILE_BASE64"      "$PROJECT_DIR/secrets/.env"              base64
push "VAULT_PASSWORD"       "$HOME/.vault_pass_dreamseed"             plain
push "SSH_PRIVATE_KEY"      "$HOME/.ssh/Vitali.pem"                  plain
push "RCLONE_CONF_BASE64"   "$PROJECT_DIR/secrets/rclone.conf"       base64

echo ""
echo -e "${GREEN}Done.${NC} GitHub Actions can now deploy without any local files."
