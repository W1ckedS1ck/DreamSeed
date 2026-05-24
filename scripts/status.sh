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

echo "─── Services ────────────────────────────────────────────"
SSH_KEY=""
if [[ -n "${SSH_PRIVATE_KEY_PATH:-}" ]]; then
    SSH_KEY=$(eval echo "$SSH_PRIVATE_KEY_PATH")
fi
if [[ -z "$SSH_KEY" || ! -f "$SSH_KEY" ]]; then
    echo "  (SSH_PRIVATE_KEY_PATH not set or not found)"
else
    SERVERS=()

    # Hetzner → dev-hetz
    if [[ -n "${HCLOUD_TOKEN:-}" ]]; then
        while IFS= read -r ip; do
            [[ -n "$ip" ]] && SERVERS+=("dev-hetz:$ip")
        done < <(curl -sf -H "Authorization: Bearer $HCLOUD_TOKEN" \
            "https://api.hetzner.cloud/v1/servers" 2>/dev/null | python3 -c "
import sys,json
for s in json.load(sys.stdin).get('servers',[]):
    ip = (s.get('public_net',{}).get('ipv4') or {}).get('ip','')
    if ip: print(ip)
" 2>/dev/null)
    fi

    # AWS → prod, dev-aws
    for var_prefix in PROD DEV_AWS; do
        ak="${var_prefix}_ACCESS_KEY"
        sk="${var_prefix}_SECRET_KEY"
        rg="${var_prefix}_REGION"
        key="${!ak:-}"
        secret="${!sk:-}"
        region="${!rg:-us-west-1}"
        case "$var_prefix" in
            PROD)    label="prod" ;;
            DEV_AWS) label="dev-aws" ;;
        esac
        if [[ -n "$key" && -n "$secret" ]]; then
            while IFS= read -r ip; do
                [[ -n "$ip" ]] && SERVERS+=("$label:$ip")
            done < <(AWS_ACCESS_KEY_ID="$key" AWS_SECRET_ACCESS_KEY="$secret" \
                aws ec2 describe-instances --region "$region" \
                --filters "Name=instance-state-name,Values=running" \
                --query 'Reservations[*].Instances[*].PublicIpAddress' \
                --output text 2>/dev/null)
        fi
    done

    if [[ ${#SERVERS[@]} -eq 0 ]]; then
        echo "  (no running servers found)"
    else
        for entry in "${SERVERS[@]}"; do
            IFS=':' read -r label ip <<< "$entry"
            case "$label" in
                prod)    domain="dreamseed.online" ;;
                dev-aws) domain="aws.vitalikuts.online" ;;
                dev-hetz) domain="hetz.vitalikuts.online" ;;
                *)       domain="" ;;
            esac

            echo ""
            echo "  $label · $domain ($ip)"

            deploy_info=$(grep "SUCCESS.*${label}" "$SCRIPT_DIR/../logs/deploy_history.log" 2>/dev/null | tail -1)
            if [[ -n "$deploy_info" ]]; then
                last_date=$(echo "$deploy_info" | cut -d'|' -f1 | xargs)
                last_ver=$(echo "$deploy_info" | cut -d'|' -f7 | xargs)
                echo "    Deployed:  ${last_date} (${last_ver})"
            fi

            remote=$(ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new -o BatchMode=yes \
                -i "$SSH_KEY" "ubuntu@$ip" "bash -s" 2>/dev/null <<-'SHEOF'
                set -uo pipefail
                echo "UPTIME=$(uptime -p 2>/dev/null || uptime)"
                echo "OS=$(lsb_release -ds 2>/dev/null || grep ^PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '\"')"
                for s in nginx apache2 php8.3-fpm mariadb victoria-metrics grafana-server telegram-bot; do
                    st=$(systemctl is-active "$s" 2>/dev/null || echo "not_found")
                    if [[ "$st" == "active" ]]; then
                        since=$(systemctl show -p ActiveEnterTimestamp "$s" 2>/dev/null | sed 's/ActiveEnterTimestamp=//')
                        echo "SVC:$s:active:${since:-?}"
                    else
                        echo "SVC:$s:$st"
                    fi
                done
                echo "---DISK---"
                df -h / /boot 2>/dev/null | tail -n +2 || true
                echo "---MEM---"
                free -h 2>/dev/null | awk '/Mem:/{printf "MEM:%s/%s\n",$3,$2} /Swap:/{printf "SWAP:%s/%s\n",$3,$2}'
                echo "LOAD=$(awk '{printf "%s, %s, %s",$1,$2,$3}' /proc/loadavg 2>/dev/null || echo '0,0,0')"
                echo "BACKUP=$(ls -1t /home/ubuntu/backups/project/ 2>/dev/null | head -1 || echo 'none')"
                echo "SESSIONS=$(mysql -e 'SELECT COUNT(*) FROM modx_db.modx_session' 2>/dev/null | tail -1 || echo '?')"
                echo "UPDATES=$(apt list --upgradable 2>/dev/null | grep -c "/" || echo 0)"
                echo "SECUPDATES=$(apt list --upgradable 2>/dev/null | grep -ci security || echo 0)"
                echo "FAILED=$(systemctl --failed --no-legend 2>/dev/null | wc -l || echo 0)"
                f2b_raw=$(sudo fail2ban-client status 2>/dev/null || true)
                if [[ -n "$f2b_raw" ]]; then
                    f2b_jails=$(echo "$f2b_raw" | grep "Jail list" | sed 's/.*\t//' || echo "none")
                    f2b_count=$(echo "$f2b_raw" | grep "Number of jail" | awk '{print $NF}')
                    echo "F2B:${f2b_count:-0}:${f2b_jails}"
                else
                    echo "F2B:0:none"
                fi
SHEOF
            ) || remote="FAILED"

            if [[ "$remote" == "FAILED" ]]; then
                echo "    ✗ SSH connection failed"
                continue
            fi

            disk_section=false
            updates=""; sec_updates=""; failed_units=""
            while IFS= read -r line; do
                case "$line" in
                    UPTIME=*) echo "    Uptime:  ${line#UPTIME=}" ;;
                    OS=*)     echo "    OS:      ${line#OS=}" ;;
                    SVC:*)    IFS=':' read -r _ svc state extra <<< "$line"
                              if [[ "$state" == "active" ]]; then
                                  sdate=$(echo "$extra" | awk '{print $2}')
                                  printf "    ● %-18s active   since %s\n" "$svc" "${sdate:-?}"
                              else
                                  printf "    ○ %-18s %s\n" "$svc" "${state//_/ }"
                              fi
                              ;;
                    ---DISK---) disk_section=true ;;
                    ---MEM---)  disk_section=false ;;
                    MEM:*)    echo "    Mem:     ${line#MEM:}" ;;
                    SWAP:*)   echo "    Swap:    ${line#SWAP:}" ;;
                    LOAD=*)   echo "    Load:    ${line#LOAD=}" ;;
                    UPDATES=*)   updates="${line#UPDATES=}" ;;
                    SECUPDATES=*) sec_updates="${line#SECUPDATES=}" ;;
                    FAILED=*)    failed_units="${line#FAILED=}" ;;
                    F2B:*)    IFS=':' read -r _ f2b_count f2b_jails <<< "$line" ;;
                    BACKUP=*) bak="${line#BACKUP=}"; echo "    Backup:  ${bak:-(none)}" ;;
                    SESSIONS=*) sessions="${line#SESSIONS=}" ;;
                    /dev/*)  if $disk_section; then
                               read -r _ sz used _ use mt <<< "$line"
                               echo "    ${mt}: ${used}/${sz} (${use})"
                             fi
                             ;;
                esac
            done <<< "$remote"

            echo "    Updates: ${updates:-?} packages  Security: ${sec_updates:-?} pending"
            echo "    Failed:  ${failed_units:-0} units    Fail2ban: ${f2b_jails:-none} (${f2b_count:-0} jails)    Sessions: ${sessions:-?}"

            # Site health check
            if [[ -n "$domain" ]]; then
                code=$(curl -sI -o /dev/null -w '%{http_code}' "https://$domain" 2>/dev/null || echo "fail")
                echo "    Site:    → ${code}"

                cert=$(echo | openssl s_client -servername "$domain" -connect "$domain":443 2>/dev/null | \
                    openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2 | sed 's/ [A-Z]*$//')
                if [[ -n "$cert" ]]; then
                    epoch=$(date -j -f "%b %d %H:%M:%S %Y" "$cert" +%s 2>/dev/null || date -d "$cert" +%s 2>/dev/null)
                    days=$(( (epoch - $(date +%s)) / 86400 ))
                    echo "    Cert:    ${days}d"
                fi
            fi
        done
    fi
fi
echo ""

echo "─── Local Terraform State Backups ────────────────────────"
ls -1t "$SCRIPT_DIR/../secrets/tfstate-backup/" 2>/dev/null | head -5 | while read -r f; do
    echo "  $f"
done
echo ""

echo "─── Quick SSH ───────────────────────────────────────────"
awk '/^Host /{h=$2} /HostName/{print "  ssh "h}' ~/.ssh/config 2>/dev/null | grep -v '@\|github.com\|\*'