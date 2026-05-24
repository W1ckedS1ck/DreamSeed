#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common_functions.sh
source "$SCRIPT_DIR/common_functions.sh"
load_env "$SCRIPT_DIR/../secrets/.env"

echo "╭──────────────────────────────────────────────────────────╮"
echo "│  DreamSeed — Infrastructure Status                      │"
echo "╰──────────────────────────────────────────────────────────╯"
echo ""

echo "─── Hetzner ──────────────────────────────────────────────"
if [[ -n "${HCLOUD_TOKEN:-}" ]]; then
    SERVERS=$(curl -sf -H "Authorization: Bearer $HCLOUD_TOKEN" \
        "https://api.hetzner.cloud/v1/servers" 2>/dev/null) || SERVERS='{"servers":[]}'
    echo "$SERVERS" | python3 -c "
import sys,json
data = json.load(sys.stdin)
servers = data.get('servers', [])
if not servers:
    print('  (no servers)')
else:
    for s in servers:
        ip = s['public_net']['ipv4']['ip'] if s['public_net'].get('ipv4') else '-'
        name = s['name']
        stype = s['server_type']['name']
        status = s['status']
        created = s['created'][:10]
        print(f'  {name:25s} {stype:8s} {status:8s} {ip:16s} {created}')
" 2>/dev/null || echo '  (API error)'
else
    echo '  (HCLOUD_TOKEN not set)'
fi
echo ""

echo "─── AWS ────────────────────────────────────────────────"
AWS_FOUND=""
for prefix in PROD DEV_AWS; do
    key="${prefix}_ACCESS_KEY"
    secret="${prefix}_SECRET_KEY"
    region="${prefix}_REGION"
    ak="${!key:-}"
    sk="${!secret:-}"
    rg="${!region:-us-west-1}"
    if [[ -n "$ak" && -n "$sk" ]]; then
        result=$(AWS_ACCESS_KEY_ID="$ak" AWS_SECRET_ACCESS_KEY="$sk" \
            aws ec2 describe-instances --region "$rg" \
            --query 'Reservations[*].Instances[*].[InstanceId,InstanceType,State.Name,PublicIpAddress,Tags[?Key==`Name`].Value|[0]]' \
            --output text 2>/dev/null)
        if [[ -n "$result" ]]; then
            while read -r id type state ip name; do
                [[ -n "$id" ]] && printf "  %-25s %-8s %-8s %s\n" "${name:-$id}" "$type" "$state" "$ip" && AWS_FOUND="yes"
            done <<< "$result"
        fi
    fi
done
[[ -z "$AWS_FOUND" ]] && echo '  (no instances or credentials stale)'
echo ""

echo "─── Server Reachability ──────────────────────────────────"
awk '/^Host /{h=$2} /HostName/{print h" "$2}' ~/.ssh/config 2>/dev/null | grep -v '@\|github.com' | while read -r host ip; do
    if ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=accept-new -o BatchMode=yes "$host" "uptime" > /dev/null 2>&1; then
        echo "  ✓ $host ($ip)"
    else
        echo "  ✗ $host ($ip)"
    fi
done
echo ""

echo "─── Local Terraform State Backups ────────────────────────"
ls -1t "$SCRIPT_DIR/../secrets/tfstate-backup/" 2>/dev/null | head -5 | while read -r f; do
    echo "  $f"
done
echo ""

echo "─── Quick SSH ───────────────────────────────────────────"
awk '/^Host /{h=$2} /HostName/{print "  ssh "h}' ~/.ssh/config 2>/dev/null | grep -v '@\|github.com\|\*'