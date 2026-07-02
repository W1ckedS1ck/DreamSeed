#!/bin/bash
set -euo pipefail

VERSION="2.0.0"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${LOG_DIR:-$SCRIPT_DIR/logs}"

export LC_ALL=C.UTF-8
PHP_VERSION="${PHP_VERSION:-8.3}"

ANSIBLE_PLAYBOOK="${ANSIBLE_PLAYBOOK:-ansible-playbook}"
TERRAFORM="${TERRAFORM:-}"
if [[ -z "$TERRAFORM" ]]; then
    if command -v tofu &>/dev/null; then TERRAFORM="tofu"
    elif command -v terraform &>/dev/null; then TERRAFORM="terraform"
    else echo "Error: neither tofu nor terraform found in PATH"; exit 1
    fi
fi

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; NC=$'\033[0m'
[[ -t 1 ]] || { RED=''; GREEN=''; YELLOW=''; NC=''; }
TTY=$([[ -t 1 ]] && echo true || echo false)

CLOUDINIT_ATTEMPTS=15 CLOUDINIT_INTERVAL=2

TARGET="" WEB_SERVER="" TF_PROVIDER="" TF_WORKSPACE="" TARGET_PREFIX=""
DEPLOY_DOMAIN="" ENV_FILE="" TF_DIR="" SERVER_IP=""
SKIP_TERRAFORM=false EXISTING_IP="" DESTROY_MODE=false PARALLEL_MODE=false DRY_RUN=false CHECK_MODE=false SKIP_DNS=false
STEP_NAMES=() STEP_TIMES=() STEP_START=0

DEPLOY_START=$(date +%s)
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/deploy_$(date +%Y%m%d_%H%M%S).log"
DEPLOY_TF_LOG="$LOG_DIR/terraform_$(date +%Y%m%d_%H%M%S).log"
DEPLOY_HISTORY="$LOG_DIR/deploy_history.log"
> "$LOG"; chmod 600 "$LOG"
> "$DEPLOY_TF_LOG"; chmod 600 "$DEPLOY_TF_LOG"

# Load modules
source "$SCRIPT_DIR/lib/helpers.sh"
source "$SCRIPT_DIR/lib/env.sh"
source "$SCRIPT_DIR/lib/preflight.sh"
source "$SCRIPT_DIR/lib/terraform.sh"
source "$SCRIPT_DIR/lib/ansible.sh"

trap cleanup EXIT INT TERM

# ----- arg parsing -----

usage() {
    cat << 'EOF'
DreamSeed Deploy Script  v2.0.0

Usage: deploy.sh TARGET -n|-a [OPTIONS]

TARGETS:
  prod               AWS        dreamseed.online
  dev-aws            AWS        aws.vitalikuts.online
  dev-hetz           Hetzner    hetz.vitalikuts.online
  prod-hetz          Hetzner    dreamseed.online

WEB SERVER (required):
  -n                 Nginx
  -a                 Apache

OPTIONS:
  -i IP              Skip Terraform, use existing server
  -x, --destroy      Destroy resources
  -p, --parallel     Parallel playbook execution (3 phases)
  -d, --dry-run      Preview only
  -c, --check        Validate config & syntax only (no deploy)
  --no-dns           Skip Cloudflare DNS update
  -h                 Show this help
   --logs [tf]        Tail latest deploy/terraform log
   --lint             Run all linters locally (no deploy)
EOF
}

parse_args() {
    [[ $# -eq 0 ]] && { usage; exit 1; }

    if [[ "$1" == "--logs" ]]; then
        local prefix="deploy"
        [[ "${2:-}" == "tf" || "${2:-}" == "terraform" ]] && prefix="terraform"
        local latest; latest=$(ls -t "$LOG_DIR/${prefix}_"*.log 2>/dev/null | head -1)
        [[ -z "$latest" ]] && { echo "No ${prefix} logs found"; exit 1; }
        tail -f "$latest"; exit 0
    fi

    if [[ "$1" == "--lint" ]]; then
        run_lint && exit 0
        echo "  ✗ Some linters reported issues (see above)"
        exit 1
    fi

    while [[ $# -gt 0 ]]; do
        case $1 in
            prod|dev-aws|dev-hetz|prod-hetz) TARGET="$1"; shift ;;
            -n) WEB_SERVER="nginx"; shift ;;
            -a) WEB_SERVER="apache"; shift ;;
            -i|--ip)
                if [[ -z "${2:-}" || "$2" =~ ^- ]]; then
                    echo "Error: -i requires an IP address argument"; usage; exit 1
                fi
                EXISTING_IP="$2"; SKIP_TERRAFORM=true; shift 2 ;;
            -x|--destroy) DESTROY_MODE=true; shift ;;
            -p|--parallel) PARALLEL_MODE=true; shift ;;
            -d|--dry-run) DRY_RUN=true; shift ;;
            -c|--check) CHECK_MODE=true; shift ;;
            --no-dns) SKIP_DNS=true; shift ;;
            -h|--help) usage; exit 0 ;;
            *) echo "Unknown option: $1"; usage; exit 1 ;;
        esac
    done

    if [[ -z "$TARGET" ]]; then echo "Error: target required"; usage; exit 1; fi
    if [[ -z "$WEB_SERVER" && "$DESTROY_MODE" == "false" ]]; then
        echo "Error: web server required (-n/-a)"; usage; exit 1
    fi
}

# ----- target resolution -----

resolve_target() {
    ENV_FILE="$SCRIPT_DIR/secrets/.env"
    case "$TARGET" in
        prod)    TF_PROVIDER="aws";    DEPLOY_DOMAIN="dreamseed.online";       TF_WORKSPACE="prod";    TARGET_PREFIX="PROD"
                 SSH_ATTEMPTS=40; SSH_INTERVAL=10 ;;
        dev-aws) TF_PROVIDER="aws";    DEPLOY_DOMAIN="aws.vitalikuts.online";  TF_WORKSPACE="dev-aws"; TARGET_PREFIX="DEV_AWS"
                 SSH_ATTEMPTS=40; SSH_INTERVAL=10 ;;
        dev-hetz)  TF_PROVIDER="hetzner"; DEPLOY_DOMAIN="hetz.vitalikuts.online"; TF_WORKSPACE="dev-hetz";  TARGET_PREFIX="DEV_HETZ"
                   SSH_ATTEMPTS=90; SSH_INTERVAL=2 ;;
        prod-hetz) TF_PROVIDER="hetzner"; DEPLOY_DOMAIN="dreamseed.online";      TF_WORKSPACE="prod-hetz"; TARGET_PREFIX="PROD_HETZ"
                   SSH_ATTEMPTS=90; SSH_INTERVAL=2 ;;
        *) echo "Error: unknown target '$TARGET'. Valid: prod, dev-aws, dev-hetz, prod-hetz"; exit 1 ;;
    esac
    TF_DIR="$SCRIPT_DIR/terraform/$TF_PROVIDER"
}

# ----- lint -----

run_lint() {
    bash "$SCRIPT_DIR/scripts/lint.sh" --fast
    local rc=$?
    if [[ "$TTY" == "false" ]]; then
        if [[ $rc -eq 0 ]]; then echo "::notice title=Lint::All linters passed"; fi
    fi
    return $rc
}

# ----- main -----

main() {
    parse_args "$@"
    resolve_target

    LOCK_ACQUIRED=false
    if command -v flock &>/dev/null; then
        LOCK_DIR="${HOME:-/tmp}/.locks"
        mkdir -p "$LOCK_DIR" && chmod 700 "$LOCK_DIR"
        LOCK_FILE="$LOCK_DIR/deploy-${TARGET}.lock"
        exec 200>"$LOCK_FILE"
        if ! flock -n 200; then
            local stale_pid
            stale_pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
            if [[ -n "$stale_pid" ]] && kill -0 "$stale_pid" 2>/dev/null; then
                echo "Error: deploy already running for $TARGET (PID $stale_pid)"
                exit 1
            fi
            # Stale lock from dead process — kernel released flock, retry
            flock -n 200 || { echo "Error: cannot acquire deploy lock for $TARGET"; exit 1; }
            echo "  ⚠ Removed stale deploy lock (PID ${stale_pid:-unknown})"
        fi
        LOCK_ACQUIRED=true
        echo "$$" > "$LOCK_FILE"
    fi

    [[ "$TTY" == "false" && "$DESTROY_MODE" == "false" && "$DRY_RUN" != "true" ]] && echo "::group::Environment"
    echo "  Target:     $TARGET"
    echo "  Domain:     $DEPLOY_DOMAIN"
    echo "  Provider:   $TF_PROVIDER"
    echo "  Web server: $WEB_SERVER"
    echo "  Mode:       $([[ "$PARALLEL_MODE" == "true" ]] && echo "parallel" || echo "sequential")"
    [[ "$DESTROY_MODE" == "true" ]] && echo "  Action:     destroy"
    [[ "$TTY" == "false" && "$DESTROY_MODE" == "false" && "$DRY_RUN" != "true" ]] && echo "::endgroup::"

    local web_playbook="playbook-02-web.yml:Web server (Nginx/Apache + PHP)"

    local playbooks=(
        "playbook-01-base.yml:Base packages"
        "$web_playbook"
        "playbook-03-db.yml:Database & Restore"
        "playbook-04-monitor.yml:Monitoring"
        "playbook-05-backup.yml:Backup & Telegram bot"
        "playbook-06-grafana.yml:Grafana"
        "playbook-07-security.yml:Security hardening"
    )

    preflight_checks

    # ----- Validate playbooks exist -----
    for entry in "${playbooks[@]}"; do
        local pb="${entry%%:*}"
        if [[ ! -f "$SCRIPT_DIR/ansible/$pb" ]]; then
            echo "Error: playbook not found: $SCRIPT_DIR/ansible/$pb"
            exit 1
        fi
    done

    # ----- Check mode (validate only) -----
    if [[ "$CHECK_MODE" == "true" ]]; then
        echo ""
        echo "  ══════════════════ CHECK ══════════════════"
        echo "  ✓ Preflight passed"
        echo "  ✓ All playbooks present"
        if [[ "$SKIP_TERRAFORM" == "false" ]]; then
            export_tf_env
            terraform_init_if_needed || { echo "Terraform init failed"; step_fail "Terraform init failed"; }
            if _tf validate -no-color >> "$LOG" 2>&1; then
                echo "  ✓ Terraform config valid"
            else
                echo "  ✗ Terraform config invalid (see $LOG)"; exit 1
            fi
        fi
        for entry in "${playbooks[@]}"; do
            local pb="${entry%%:*}" label="${entry##*:}"
            if "$ANSIBLE_PLAYBOOK" --syntax-check "$SCRIPT_DIR/ansible/$pb" > /dev/null 2>&1; then
                echo "  ✓ $label"
            else
                echo "  ✗ $label syntax error"
                ansible-playbook --syntax-check "$SCRIPT_DIR/ansible/$pb" 2>&1
                exit 1
            fi
        done
        echo ""
        echo "  ✓ All checks passed"
        echo "  ════════════════════════════════════════════════"
        echo ""
        exit 0
    fi

    # ----- Dry run -----
    if [[ "$DRY_RUN" == "true" ]]; then
        echo ""
        echo "  ══════════════════ DRY RUN ══════════════════"
        if [[ "$DESTROY_MODE" == "true" ]]; then
            echo "  Action:    Destroy $TARGET"
            echo "  Provider:  $TF_PROVIDER"
            echo "  Would destroy: server, firewall, DNS, key pair"
        else
            echo "  Action:    Deploy $TARGET"
            echo "  Provider:  $TF_PROVIDER"
            echo "  Domain:    $DEPLOY_DOMAIN"
            echo "  Provision: $([[ "$SKIP_TERRAFORM" == "true" ]] && echo "skip (IP: $EXISTING_IP)" || echo "new server")"
            echo ""
            echo "  Playbooks:"
            for entry in "${playbooks[@]}"; do
                printf "    ▶ %s\n" "${entry##*:}"
            done
        fi
        echo ""
        echo "  No changes were made."
        echo "  ════════════════════════════════════════════════"
        echo ""
        write_deploy_history "DRY-RUN"
        exit 0
    fi

    # ----- Production confirmation -----
    if [[ "$TARGET" =~ ^prod && "$DESTROY_MODE" == "false" ]]; then
        echo ""
        echo "  ⚠ Deploying to PRODUCTION ($DEPLOY_DOMAIN)"
        if [[ "${CI:-}" == "true" ]]; then
            echo "  CI mode — confirmation skipped"
        else
            read -rp "  Continue? [y/N] " confirm < /dev/tty
            [[ ! "${confirm:-}" =~ ^[Yy]$ ]] && { echo "Aborted."; exit 0; }
        fi
    fi

    # ----- Destroy path -----
    if [[ "$DESTROY_MODE" == "true" ]]; then
        step_start "Terraform destroy ($TARGET)"
        terraform_destroy || step_fail "Terraform destroy failed"
        step_ok
        write_deploy_history "DESTROYED"
        exit 0
    fi

    rotate_logs

    # ----- Terraform -----
    if [[ "$SKIP_TERRAFORM" == "false" ]]; then
        step_start "Terraform init + apply ($TARGET)"
        export_tf_env

        terraform_init_if_needed || { echo "Terraform init failed"; tail -30 "$DEPLOY_TF_LOG"; step_fail "Terraform init failed"; }
        terraform_select_workspace || step_fail "Failed to select workspace: $TF_WORKSPACE"

        local tf_args=()
        [[ "$TF_PROVIDER" == "aws" ]] && tf_args+=(-var="ssh_public_key_path=${SSH_PUBLIC_KEY_PATH:-/dev/null}")
        [[ "$TF_PROVIDER" == "hetzner" ]] && tf_args+=(-var="environment=${TARGET}")

        # Pre-apply state backup — rollback point if apply breaks
        local bk="$SCRIPT_DIR/secrets/tfstate-backup"
        mkdir -p "$bk"
        if _tf state pull > "$bk/${TF_WORKSPACE}_pre.tfstate" 2>/dev/null && [[ -s "$bk/${TF_WORKSPACE}_pre.tfstate" ]]; then
            echo "  ✓ Pre-apply state backed up"
        else
            rm -f "$bk/${TF_WORKSPACE}_pre.tfstate" 2>/dev/null
        fi

        if _tf apply -auto-approve -no-color "${tf_args[@]}" >> "$DEPLOY_TF_LOG" 2>&1; then
            :  # ok
        else
            tail -30 "$DEPLOY_TF_LOG"
            if [[ -f "$bk/${TF_WORKSPACE}_pre.tfstate" ]]; then
                echo "  ⚠ Apply failed. Rollback with:"
                echo "    cd ${TF_DIR} && ${TERRAFORM} state push ${bk}/${TF_WORKSPACE}_pre.tfstate -force"
            fi
            step_fail "Terraform apply failed"
        fi

        SERVER_IP=$(_tf output -raw server_ipv4 2>>"$DEPLOY_TF_LOG") || step_fail "Could not get server IP"
        [[ -z "$SERVER_IP" ]] && step_fail "Empty IP from Terraform"
        [[ "$SERVER_IP" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || step_fail "Invalid IP from Terraform: $SERVER_IP"
        export SERVER_IP

        # Post-apply state backup (timestamped, rotate 5)
        TF_STATE_BACKUP_TMP=$(mktemp)
        if _tf state pull > "$TF_STATE_BACKUP_TMP" 2>/dev/null && [[ -s "$TF_STATE_BACKUP_TMP" ]]; then
            mv "$TF_STATE_BACKUP_TMP" "$bk/${TF_WORKSPACE}_$(date +%Y%m%d_%H%M%S).tfstate"
            TF_STATE_BACKUP_TMP=
            ls -1t "$bk/${TF_WORKSPACE}"_[0-9]*.tfstate 2>/dev/null | tail -n +6 | xargs rm -f 2>/dev/null || true
        else
            rm -f "$TF_STATE_BACKUP_TMP"
            TF_STATE_BACKUP_TMP=
            echo "  ⚠ Post-apply state backup failed (empty or error)" | tee -a "$LOG"
        fi
        if [[ "$SKIP_DNS" == "false" ]]; then
            update_cloudflare_dns "$DEPLOY_DOMAIN" "$SERVER_IP"
        else
            echo "  — Cloudflare DNS update skipped (--no-dns)"
        fi
        step_ok
    else
        step_start "Using existing server"
        SERVER_IP="$EXISTING_IP"
        export SERVER_IP
        step_ok
    fi

    # ----- Clear stale host key (prevents mismatch on IP reuse) -----
    ssh-keygen -R "$SERVER_IP" > /dev/null 2>&1 || true
    ssh-keyscan -H "$SERVER_IP" >> ~/.ssh/known_hosts 2>/dev/null || true

    # ----- Wait for SSH -----
    step_start "Wait for SSH ($SERVER_IP)"
    local ssh_err="" attempt=0
    for ((attempt=1; attempt<=SSH_ATTEMPTS; attempt++)); do
        ssh_err=$(ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 \
            -o BatchMode=yes -o PasswordAuthentication=no \
            -i "$SSH_KEY" "ubuntu@$SERVER_IP" 'true' 2>&1) && break
        if [[ $((attempt % 10)) -eq 1 ]]; then
            local err_line
            err_line=$(echo "$ssh_err" | grep -iE '(Permission denied|Connection refused|Connection timed out|Could not resolve|Host key verification)' | head -1)
            [[ -n "$err_line" ]] && echo -e "\n  ⚠ $err_line"
        fi
        printf "."; sleep "$SSH_INTERVAL"
    done
    echo ""
    [[ $attempt -gt $SSH_ATTEMPTS ]] && step_fail "SSH not ready after $((SSH_ATTEMPTS * SSH_INTERVAL))s — $(echo "$ssh_err" | head -1)"
    step_ok

    # ----- Wait for cloud-init -----
    step_start "Wait for cloud-init"
    ssh -i "$SSH_KEY" "ubuntu@$SERVER_IP" "timeout 300 cloud-init status --wait" >/dev/null 2>/dev/null || {
        for ((i=1; i<=CLOUDINIT_ATTEMPTS; i++)); do
            local st
            st=$(ssh -i "$SSH_KEY" "ubuntu@$SERVER_IP" 'cloud-init status 2>/dev/null || echo unknown' 2>/dev/null || echo unknown)
            [[ "$st" == *"status: done"* || "$st" == *"No pending"* ]] && break
            [[ "$st" == *"status: error"* ]] && step_fail "Cloud-init failed (check /var/log/cloud-init-output.log)"
            [[ $i -eq $CLOUDINIT_ATTEMPTS ]] && step_fail "Cloud-init timeout"
            printf "."; sleep "$CLOUDINIT_INTERVAL"
        done
    }
    echo ""; step_ok

    # ----- Wait for apt lock -----
    step_start "Wait for apt lock"
    ssh -i "$SSH_KEY" "ubuntu@$SERVER_IP" \
        "while sudo fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do sleep 2; done" 2>/dev/null || true
    step_ok

    # ----- Generate inventory + vault -----
    mkdir -p "$SCRIPT_DIR/ansible/inventory"
    INVENTORY_FILE="$SCRIPT_DIR/ansible/inventory/hosts-${TF_WORKSPACE}.yml"
    cat > "$INVENTORY_FILE" << INVEOF
all:
  hosts:
    dreamseed:
      ansible_host: "${SERVER_IP}"
      ansible_user: ubuntu
      ansible_ssh_private_key_file: "${SSH_KEY}"
      ansible_ssh_common_args: "-o StrictHostKeyChecking=accept-new"
      server_ip: "${SERVER_IP}"
INVEOF

    DEPLOY_VARS_TMP=$(mktemp -d); chmod 700 "$DEPLOY_VARS_TMP"
    DEPLOY_VARS_FILE="$DEPLOY_VARS_TMP/vars.json"
    python3 -c "
import json, os, sys

target = sys.argv[1]
script_dir = sys.argv[2]
dst = sys.argv[3]

data = {
    'db_pass': os.environ.get('DB_PASS', ''),
    'server_ip': os.environ.get('SERVER_IP', ''),
    'web_server': os.environ.get('WEB_SERVER', ''),
    'domain': os.environ.get('DEPLOY_DOMAIN', ''),
    'domain_www': target.startswith('prod'),
    'cloudflare_enabled': target.startswith('prod'),

    'secrets_dir': f'{script_dir}/secrets',
    'configs_dir': f'{script_dir}/configs',
    'scripts_dir': f'{script_dir}/scripts',
    'deploy_env': target,
}

optional_map = {
    'CLOUDFLARE_API_TOKEN': 'cloudflare_api_token',
    'GRAFANA_PASS': 'grafana_admin_password',
    'SSH_PUBLIC_KEY_PATH': 'ssh_public_key_path',
    'GRAFANA_CLOUD_URL': 'grafana_cloud_url',
    'GRAFANA_CLOUD_USERNAME': 'grafana_cloud_username',
    'GRAFANA_CLOUD_TOKEN': 'grafana_cloud_token',
}
for env_var, key in optional_map.items():
    val = os.environ.get(env_var)
    if val:
        data[key] = val

additional_keys = os.environ.get('ADDITIONAL_SSH_KEYS', '')
if additional_keys.strip():
    data['additional_ssh_keys'] = [k.strip() for k in additional_keys.split('\n') if k.strip()]

with open(dst, 'w') as f:
    json.dump(data, f, indent=2)
" "$TARGET" "$SCRIPT_DIR" "$DEPLOY_VARS_FILE"

    # Strip Better Stack keys for non-prod (prevents env leakage to Ansible/SSH child processes)
    [[ ! "$TARGET" =~ ^prod ]] && for v in "${!BETTERUPTIME_@}"; do unset "$v"; done

    mkdir -p ~/.ansible/facts_cache

    # ----- Ansible playbooks -----
    if [[ "$PARALLEL_MODE" == "true" ]]; then
        # Phase 1: Base (sequential — prerequisite)
        step_start "Base packages"
        run_ansible "playbook-01-base.yml" "Base packages" || step_fail "Base packages failed"
        step_ok

        # Phase 2: Web + DB
        step_start "Phase 2: Web/DB"
        run_parallel "Web/DB" \
            "$web_playbook" \
            "playbook-03-db.yml:Database & Restore" || step_fail "Phase 2 failed"
        step_ok

        # Phase 2.5: Security (sequential — requires DB + web config)
        step_start "Security hardening"
        run_ansible "playbook-07-security.yml" "Security hardening" || step_fail "Security hardening failed"
        step_ok

        # Phase 3: Monitoring + Backup + Grafana
        step_start "Phase 3: Monitoring/Backup/Grafana"
        run_parallel "Monitoring/Backup/Grafana" \
            "playbook-04-monitor.yml:Monitoring" \
            "playbook-05-backup.yml:Backup & Telegram bot" \
            "playbook-06-grafana.yml:Grafana" || step_fail "Phase 3 failed"
        step_ok
    else
        for entry in "${playbooks[@]}"; do
            local pb="${entry%%:*}" label="${entry##*:}"
            step_start "$label"
            run_ansible "$pb" "$label" || step_fail "$label failed"
            step_ok
        done
    fi

    # ----- Post-deploy checks -----
    local chk_start; chk_start=$(date +%s)
    check_services
    STEP_NAMES+=("Post-deploy checks")
    STEP_TIMES+=($(( $(date +%s) - chk_start )))

    # ----- Summary -----
    print_summary

    write_deploy_history "SUCCESS"

    local total=$(( $(date +%s) - DEPLOY_START ))
    echo ""
    echo "  ✓ Deployment Successful!"
    echo "  Server   $SERVER_IP"
    echo "  Site     https://${DEPLOY_DOMAIN}"
    echo "  Grafana  https://${DEPLOY_DOMAIN}/grafana/"
    echo "  SSH      ssh -i ${SSH_KEY##*/} ubuntu@${SERVER_IP}"
    echo "  Time     $(format_time $total)"
    echo ""
    echo "  Log: $LOG"
}

main "$@"
