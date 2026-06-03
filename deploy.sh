#!/bin/bash
set -euo pipefail

VERSION="2.0.0"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${LOG_DIR:-$SCRIPT_DIR/logs}"

export LC_ALL=C.UTF-8
PHP_VERSION="${PHP_VERSION:-8.3}"

# Executable paths
ANSIBLE_PLAYBOOK="${ANSIBLE_PLAYBOOK:-ansible-playbook}"
TERRAFORM="${TERRAFORM:-}"
if [[ -z "$TERRAFORM" ]]; then
    if command -v tofu &>/dev/null; then TERRAFORM="tofu"
    elif command -v terraform &>/dev/null; then TERRAFORM="terraform"
    else echo "Error: neither tofu nor terraform found in PATH"; exit 1
    fi
fi

# Colors (stripped in non-TTY)
RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; NC=$'\033[0m'
[[ -t 1 ]] || { RED=''; GREEN=''; YELLOW=''; NC=''; }
TTY=$([[ -t 1 ]] && echo true || echo false)

# Timeouts
SSH_ATTEMPTS=20 SSH_INTERVAL=1
AWS_SSH_ATTEMPTS=40 AWS_SSH_INTERVAL=10
CLOUDINIT_ATTEMPTS=15 CLOUDINIT_INTERVAL=2

# State
TARGET="" WEB_SERVER="" TF_PROVIDER="" TF_WORKSPACE="" TARGET_PREFIX=""
DEPLOY_DOMAIN="" ENV_FILE="" TF_DIR="" SERVER_IP=""
SKIP_TERRAFORM=false EXISTING_IP="" DESTROY_MODE=false PARALLEL_MODE=false DRY_RUN=false
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

Usage: $0 TARGET -n|-a [OPTIONS]

TARGETS:
  prod               AWS        dreamseed.online
  dev-aws            AWS        aws.vitalikuts.online
  dev-hetz           Hetzner    hetz.vitalikuts.online

WEB SERVER (required):
  -n                 Nginx
  -a                 Apache

OPTIONS:
  -i IP              Skip Terraform, use existing server
  -x, --destroy      Destroy resources
  -p, --parallel     Parallel playbook execution (3 phases)
  -d, --dry-run      Preview only
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
        run_lint
        exit $?
    fi

    while [[ $# -gt 0 ]]; do
        case $1 in
            prod|dev-aws|dev-hetz) TARGET="$1"; shift ;;
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
        prod)    TF_PROVIDER="aws";    DEPLOY_DOMAIN="dreamseed.online";       TF_WORKSPACE="prod";    TARGET_PREFIX="PROD" ;;
        dev-aws) TF_PROVIDER="aws";    DEPLOY_DOMAIN="aws.vitalikuts.online";  TF_WORKSPACE="dev-aws"; TARGET_PREFIX="DEV_AWS" ;;
        dev-hetz) TF_PROVIDER="hetzner"; DEPLOY_DOMAIN="hetz.vitalikuts.online"; TF_WORKSPACE="dev-hetz" ;;
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

    LOCK_FILE="/tmp/deploy-${TARGET}.lock"
    mkdir "$LOCK_FILE" 2>/dev/null || {
        if [[ -f "$LOCK_FILE/pid" ]] && kill -0 "$(cat "$LOCK_FILE/pid")" 2>/dev/null; then
            echo "Error: deploy already running for $TARGET (PID $(cat "$LOCK_FILE/pid"))"
            exit 1
        fi
        echo "Warning: removing stale lock for $TARGET"
        rmdir "$LOCK_FILE" 2>/dev/null || true
        mkdir "$LOCK_FILE"
    }
    echo "$$" > "$LOCK_FILE/pid"

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
    if [[ "$TARGET" == "prod" && "$DESTROY_MODE" == "false" ]]; then
        echo ""
        echo "  ⚠ Deploying to PRODUCTION ($DEPLOY_DOMAIN)"
        if [[ "${CI:-}" == "true" ]]; then
            echo "  CI mode — confirmation skipped"
        else
            read -rp "  Continue? [y/N] " confirm
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

        local tf_args=""
        [[ "$TF_PROVIDER" == "aws" ]] && tf_args="-var=ssh_public_key_path=${SSH_PUBLIC_KEY_PATH:-/dev/null}"

        local ok=false
        for try in 1 2; do
            # shellcheck disable=SC2086
            if _tf apply -auto-approve -no-color $tf_args >> "$DEPLOY_TF_LOG" 2>&1; then
                ok=true; break
            fi
            [[ $try -lt 2 ]] && { echo "    Attempt $try/2 failed, retrying in 10s..."; sleep 10; }
        done
        [[ "$ok" != "true" ]] && { tail -30 "$DEPLOY_TF_LOG"; step_fail "Terraform apply failed"; }

        SERVER_IP=$(_tf output -raw server_ipv4 2>&1 | tee -a "$DEPLOY_TF_LOG") || step_fail "Could not get server IP"
        [[ -z "$SERVER_IP" ]] && step_fail "Empty IP from Terraform"

        ssh-keygen -R "$SERVER_IP" > /dev/null 2>&1 || true

        local bk="$SCRIPT_DIR/secrets/tfstate-backup"
        mkdir -p "$bk"
        _tf state pull > "$bk/${TF_WORKSPACE}_$(date +%Y%m%d_%H%M%S).tfstate" 2>/dev/null || true
        ls -1t "$bk/${TF_WORKSPACE}"_*.tfstate 2>/dev/null | tail -n +6 | xargs rm -f 2>/dev/null || true
        step_ok
    else
        step_start "Using existing server"
        SERVER_IP="$EXISTING_IP"
        step_ok
    fi

    # ----- Wait for SSH -----
    if [[ "$TF_PROVIDER" == "aws" ]]; then
        SSH_ATTEMPTS=$AWS_SSH_ATTEMPTS; SSH_INTERVAL=$AWS_SSH_INTERVAL
    elif [[ "$TF_PROVIDER" == "hetzner" ]]; then
        SSH_ATTEMPTS=90; SSH_INTERVAL=2
    fi
    step_start "Wait for SSH ($SERVER_IP)"
    for ((i=1; i<=SSH_ATTEMPTS; i++)); do
        if ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 \
            -o BatchMode=yes -i "$SSH_KEY" "ubuntu@$SERVER_IP" 'true' 2>/dev/null; then
            break
        fi
        [[ $i -eq $SSH_ATTEMPTS ]] && step_fail "SSH not ready after $((SSH_ATTEMPTS * SSH_INTERVAL))s"
        printf "."; sleep "$SSH_INTERVAL"
    done
    echo ""
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

    # ----- Generate inventory + vault -----
    mkdir -p "$SCRIPT_DIR/ansible/inventory"
    INVENTORY_FILE="$SCRIPT_DIR/ansible/inventory/hosts-${TF_WORKSPACE}.yml"
    cat > "$INVENTORY_FILE" << INVEOF
all:
  hosts:
    dreamseed:
      ansible_host: ${SERVER_IP}
      ansible_user: ubuntu
      ansible_ssh_private_key_file: ${SSH_KEY}
      ansible_ssh_common_args: "-o StrictHostKeyChecking=accept-new"
      server_ip: ${SERVER_IP}
INVEOF

    VAULT_TMP=$(mktemp); chmod 600 "$VAULT_TMP"
    {
        echo "db_pass: '$(yaml_escape "$DB_PASS")'"
        echo "server_ip: \"${SERVER_IP}\""
        echo "web_server: \"${WEB_SERVER}\""
        echo "domain: \"${DEPLOY_DOMAIN}\""
        if [[ "$TARGET" == "prod" ]]; then
            echo "domain_www: true"
            echo "dev_write_perms: false"
        else
            echo "domain_www: false"
            echo "dev_write_perms: true"
        fi
        echo "php_version: \"${PHP_VERSION}\""
        echo "secrets_dir: \"${SCRIPT_DIR}/secrets\""
        echo "configs_dir: \"${SCRIPT_DIR}/configs\""
        echo "scripts_dir: \"${SCRIPT_DIR}/scripts\""
        [[ -n "${CLOUDFLARE_API_TOKEN:-}" ]] && echo "cloudflare_api_token: '$(yaml_escape "$CLOUDFLARE_API_TOKEN")'"
        [[ -n "${GRAFANA_PASS:-}" ]] && echo "grafana_admin_password: '$(yaml_escape "$GRAFANA_PASS")'"
        [[ -n "${SSH_PUBLIC_KEY_PATH:-}" ]] && echo "ssh_public_key_path: \"${SSH_PUBLIC_KEY_PATH}\""
        [[ -n "${GRAFANA_CLOUD_URL:-}" ]] && echo "grafana_cloud_url: '$(yaml_escape "$GRAFANA_CLOUD_URL")'"
        [[ -n "${GRAFANA_CLOUD_USERNAME:-}" ]] && echo "grafana_cloud_username: '$(yaml_escape "$GRAFANA_CLOUD_USERNAME")'"
        [[ -n "${GRAFANA_CLOUD_TOKEN:-}" ]] && echo "grafana_cloud_token: '$(yaml_escape "$GRAFANA_CLOUD_TOKEN")'"
        [[ -n "${ADDITIONAL_SSH_KEYS:-}" ]] && {
            echo "additional_ssh_keys:"
            while IFS= read -r key; do
                [[ -n "$key" ]] && echo "  - '$(yaml_escape "$key")'"
            done <<< "$ADDITIONAL_SSH_KEYS"
        }
    } > "$VAULT_TMP"

    # Strip Better Stack keys for non-prod
    [[ "$TARGET" != "prod" ]] && unset "${!BETTERUPTIME_@}"

    # ----- Ansible playbooks -----
    if [[ "$PARALLEL_MODE" == "true" ]]; then
        # Phase 1: Base (sequential — prerequisite)
        step_start "Base packages"
        run_ansible "playbook-01-base.yml" "Base packages" || step_fail "Base packages failed"
        step_ok

        # Phase 2: Web + DB + Security
        step_start "Phase 2: Web/DB/Security"
        run_parallel "Web/DB/Security" \
            "$web_playbook" \
            "playbook-03-db.yml:Database & Restore" \
            "playbook-07-security.yml:Security hardening" || step_fail "Phase 2 failed"
        step_ok

        # Phase 3: Monitoring + Backup
        step_start "Phase 3: Monitoring/Backup"
        run_parallel "Monitoring/Backup" \
            "playbook-04-monitor.yml:Monitoring" \
            "playbook-05-backup.yml:Backup & Telegram bot" || step_fail "Phase 3 failed"
        step_ok

        # Phase 4: Grafana (sequential — needs VictoriaMetrics up)
        step_start "Grafana"
        run_ansible "playbook-06-grafana.yml" "Grafana" || step_fail "Grafana failed"
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
