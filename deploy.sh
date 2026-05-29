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
RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; DIM=$'\033[2m'; NC=$'\033[0m'
[[ -t 1 ]] || { RED=''; GREEN=''; YELLOW=''; DIM=''; NC=''; }
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
TF_LOG="$LOG_DIR/terraform_$(date +%Y%m%d_%H%M%S).log"
DEPLOY_HISTORY="$LOG_DIR/deploy_history.log"

# ----- helpers -----

format_time() {
    local s=$1
    if [[ $s -ge 3600 ]]; then printf "%dh %02dm %02ds" $((s/3600)) $(((s%3600)/60)) $((s%60))
    elif [[ $s -ge 60 ]]; then printf "%dm %02ds" $((s/60)) $((s%60))
    else printf "%ds" "$s"; fi
}

log() { echo "[$(date '+%H:%M:%S')] $*" >> "$LOG"; }

step_start() {
    STEP_START=$(date +%s)
    STEP_LABEL="$*"
    log "▶ $*"
    if [[ "$TTY" == "true" ]]; then
        printf "\n  \033[1m▶ %s\033[0m\n" "$*"
    else
        printf "\n  ▶ %s\n" "$*"
    fi
}

step_ok() {
    local d=$(( $(date +%s) - STEP_START ))
    STEP_NAMES+=("$STEP_LABEL"); STEP_TIMES+=("$d")
    log "✓ $STEP_LABEL (elapsed: $(format_time $d))"
    if [[ "$TTY" == "true" ]]; then
        printf "  ${GREEN}✓${NC} %s (${YELLOW}%s${NC})\n" "$STEP_LABEL" "$(format_time $d)"
    else
        printf "  ✓ %s (%s)\n" "$STEP_LABEL" "$(format_time $d)"
    fi
}

step_fail() {
    log "✗ $*"
    if [[ "$TTY" == "true" ]]; then
        printf "\n  ${RED}✗${NC} %s\n" "$*"
    else
        printf "\n  ✗ %s\n" "$*"
        echo "::error title=${STEP_LABEL:-Deploy}::$1"
    fi
    write_deploy_history "FAILURE" "$*"
    exit 1
}

cleanup() {
    [[ -n "${VAULT_TMP:-}" && -f "${VAULT_TMP:-}" ]] && rm -f "$VAULT_TMP"
    [[ -n "${ENV_DECRYPTED_TMP:-}" && -f "${ENV_DECRYPTED_TMP:-}" ]] && rm -f "$ENV_DECRYPTED_TMP"
    [[ -n "${LOCK_FILE:-}" && -d "${LOCK_FILE:-}" ]] && rmdir "$LOCK_FILE" 2>/dev/null || true
}
trap cleanup EXIT

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

    while [[ $# -gt 0 ]]; do
        case $1 in
            prod|dev-aws|dev-hetz) TARGET="$1"; shift ;;
            -n) WEB_SERVER="nginx"; shift ;;
            -a) WEB_SERVER="apache"; shift ;;
            -i|--ip) EXISTING_IP="$2"; SKIP_TERRAFORM=true; shift 2 ;;
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
        dev-hetz) TF_PROVIDER="hetzner"; DEPLOY_DOMAIN="hetz.vitalikuts.online"; TF_WORKSPACE="dev-hetz"; TARGET_PREFIX="DEV_HETZ" ;;
    esac
    TF_DIR="$SCRIPT_DIR/terraform/$TF_PROVIDER"
}

# ----- .env handling -----

validate_env_file() {
    local f="$1" n=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        ((n++)) || true
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || { echo "Invalid env format at $f:$n"; exit 1; }
    done < "$f"
}

resolve_env_file() {
    local f="$1"
    [[ ! -f "$f" ]] && { echo "Error: $f not found" >&2; exit 1; }
    if head -c 16 "$f" 2>/dev/null | grep -qF '$ANSIBLE_VAULT'; then
        local pw="${VAULT_PASSWORD_FILE:-$HOME/.vault_pass_dreamseed}"
        [[ ! -f "$pw" ]] && { echo "Error: vault password file not found: $pw" >&2; exit 1; }
        local tmp; tmp=$(mktemp); chmod 600 "$tmp"
        ansible-vault view "$f" --vault-password-file "$pw" > "$tmp" 2>/dev/null || { echo "Error: vault decrypt failed" >&2; exit 1; }
        ENV_DECRYPTED_TMP="$tmp"
        printf '%s' "$tmp"
    else
        printf '%s' "$f"
    fi
}

# ----- env var helpers -----

apply_target_vars() {
    if [[ "$TF_PROVIDER" == "aws" ]]; then
        local pfx="$TARGET_PREFIX"
        local v_key="${pfx}_ACCESS_KEY" v_sec="${pfx}_SECRET_KEY"
        local v_reg="${pfx}_REGION" v_eip="${pfx}_EIP"
        AWS_ACCESS_KEY="${!v_key:-}"
        AWS_SECRET_KEY="${!v_sec:-}"
        AWS_REGION="${!v_reg:-us-west-1}"
        AWS_EIP_ALLOCATION_ID="${!v_eip:-}"
        export AWS_ACCESS_KEY AWS_SECRET_KEY AWS_REGION AWS_EIP_ALLOCATION_ID
    fi
}

export_tf_env() {
    [[ "$TF_PROVIDER" == "aws" ]] && {
        export AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY"
        export AWS_SECRET_ACCESS_KEY="$AWS_SECRET_KEY"
        export AWS_DEFAULT_REGION="$AWS_REGION"
        [[ -n "${AWS_EIP_ALLOCATION_ID:-}" ]] && export TF_VAR_elastic_ip_allocation_id="$AWS_EIP_ALLOCATION_ID"
    }
    [[ "$TF_PROVIDER" == "hetzner" ]] && {
        export TF_VAR_hcloud_token="${HCLOUD_TOKEN:-}"
        [[ -n "${HETZNER_SERVER_TYPE:-}" ]] && export TF_VAR_server_type="$HETZNER_SERVER_TYPE"
        [[ -n "${HETZNER_LOCATION:-}" ]] && export TF_VAR_location="$HETZNER_LOCATION"
        [[ -n "${HETZNER_SSH_KEY_NAME:-}" ]] && export TF_VAR_ssh_key_name="$HETZNER_SSH_KEY_NAME"
        [[ -n "${HETZNER_PRIMARY_IP_NAME:-}" ]] && export TF_VAR_primary_ip_name="$HETZNER_PRIMARY_IP_NAME"
        if [[ -z "${HETZNER_SSH_KEY_NAME:-}" && -n "${SSH_PUBLIC_KEY_PATH:-}" ]]; then
            local pk; pk="$(eval echo "$SSH_PUBLIC_KEY_PATH")"
            if [[ -r "$pk" ]]; then
                local pk_content; pk_content="$(<"$pk")"
                export TF_VAR_ssh_public_key="$pk_content"
            fi
        fi
    }
    export TF_VAR_environment="$TARGET"
    export TF_WORKSPACE="$TF_WORKSPACE"
    export TF_TOKEN_app_terraform_io="${TF_API_TOKEN:-}"
}

# ----- YAML escaping for extra-vars -----

yaml_escape() {
    local val="$1"
    val="${val//\\/\\\\}"; val="${val//\"/\\\"}"; val="${val//$'\n'/\\n}"
    val="${val//!/\\!}"; val="${val//'#'/\\#}"
    printf '%s' "$val"
}

# ----- deploy history -----

write_deploy_history() {
    local status="$1" msg="${2:-}" ts dur
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    dur=$(( $(date +%s) - DEPLOY_START ))
    printf "%s | %-7s | %-8s | %-6s | %-15s | %5ss | v%s" \
        "$ts" "$status" "$TARGET" "${WEB_SERVER:-N/A}" "${SERVER_IP:-N/A}" "$dur" "$VERSION" >> "$DEPLOY_HISTORY"
    [[ -n "$msg" ]] && printf " | %s" "$msg" >> "$DEPLOY_HISTORY"
    echo >> "$DEPLOY_HISTORY"
}

# ----- log rotation -----

rotate_logs() {
    local max="${MAX_LOG_FILES:-10}"
    ls -1t "$LOG_DIR"/deploy_2*.log 2>/dev/null | tail -n +$((max + 1)) | xargs rm -f 2>/dev/null || true
    ls -1t "$LOG_DIR"/terraform_2*.log 2>/dev/null | tail -n +$((max + 1)) | xargs rm -f 2>/dev/null || true
}

# ----- preflight -----

check_prerequisites() {
    local missing=()
    command -v "$ANSIBLE_PLAYBOOK" &>/dev/null || missing+=("ansible-playbook")
    command -v "$TERRAFORM" &>/dev/null || missing+=("terraform")
    command -v ssh &>/dev/null || missing+=("ssh")
    command -v ssh-keygen &>/dev/null || missing+=("ssh-keygen")
    command -v ansible-vault &>/dev/null || missing+=("ansible-vault")
    if [[ ${#missing[@]} -gt 0 ]]; then echo "Missing: ${missing[*]}"; exit 1; fi
}

preflight_checks() {
    check_prerequisites

    local env_src; env_src=$(resolve_env_file "$ENV_FILE")
    validate_env_file "$env_src"

    local saved_opts; saved_opts="$(set +o)"
    set -a; source "$env_src"; set +a
    eval "$saved_opts"

    # Auto-setup Better Stack heartbeats for prod if needed
    if [[ "$TARGET" == "prod" && -z "${BETTERUPTIME_BACKUP_KEY:-}" && -n "${BETTERUPTIME_API_TOKEN:-}" ]]; then
        bash "$SCRIPT_DIR/scripts/setup_betteruptime.sh" --write-env
        source <(grep -E '^BETTERUPTIME_' "$SCRIPT_DIR/secrets/.env" 2>/dev/null)
    fi

    apply_target_vars

    # Load Grafana Cloud credentials (PROD_ for prod, DEV_ for all dev)
    local gc_pfx="DEV"
    [[ "$TARGET" == "prod" ]] && gc_pfx="PROD"
    local gc_url="${gc_pfx}_GRAFANA_CLOUD_URL"
    local gc_user="${gc_pfx}_GRAFANA_CLOUD_USERNAME"
    local gc_token="${gc_pfx}_GRAFANA_CLOUD_TOKEN"
    GRAFANA_CLOUD_URL="${!gc_url:-}"
    GRAFANA_CLOUD_USERNAME="${!gc_user:-}"
    GRAFANA_CLOUD_TOKEN="${!gc_token:-}"
    export GRAFANA_CLOUD_URL GRAFANA_CLOUD_USERNAME GRAFANA_CLOUD_TOKEN

    SSH_KEY="${SSH_PRIVATE_KEY_PATH:-}"
    SSH_KEY="${SSH_KEY/#\~/$HOME}"
    if [[ -z "$SSH_KEY" ]]; then echo "Error: SSH_PRIVATE_KEY_PATH not set"; exit 1; fi
    if [[ ! -f "$SSH_KEY" ]]; then echo "Error: SSH key not found: $SSH_KEY"; exit 1; fi

    if [[ "$DESTROY_MODE" == "false" ]]; then
        if [[ -z "${DB_PASS:-}" ]]; then echo "Error: DB_PASS not set"; exit 1; fi
        if [[ -z "${GRAFANA_PASS:-}" ]]; then echo "Error: GRAFANA_PASS not set"; exit 1; fi
    fi

    if [[ "$TF_PROVIDER" == "aws" ]]; then
        if [[ -z "${AWS_ACCESS_KEY:-}" || -z "${AWS_SECRET_KEY:-}" ]]; then echo "Error: AWS credentials required"; exit 1; fi
        : "${AWS_REGION:=us-west-1}"
        if [[ -z "${SSH_PUBLIC_KEY_PATH:-}" ]]; then echo "Error: SSH_PUBLIC_KEY_PATH not set"; exit 1; fi
    fi

    if [[ "$TF_PROVIDER" == "hetzner" && -z "${HCLOUD_TOKEN:-}" ]]; then
        echo "Error: HCLOUD_TOKEN not set"; exit 1
    fi
    if [[ "$SKIP_TERRAFORM" == "false" && ! -f "$TF_DIR/main.tf" ]]; then
        echo "Error: $TF_DIR/main.tf not found"; exit 1
    fi
}

# ----- summary table -----

print_summary() {
    echo ""
    echo "  ──────────────────────────────────────────────────────"
    printf "  %-5s %-35s %s\n" "" "Step" "Time"
    echo "  ──────────────────────────────────────────────────────"
    local i
    for i in "${!STEP_NAMES[@]}"; do
        printf "  %-40s ${YELLOW}%s${NC}\n" "${STEP_NAMES[$i]}" "$(format_time "${STEP_TIMES[$i]}")"
    done
    echo "  ──────────────────────────────────────────────────────"
    local total=$(( $(date +%s) - DEPLOY_START ))
    printf "  %-40s ${YELLOW}%s${NC}\n" "Total" "$(format_time $total)"
}

# ----- Terraform -----

terraform_select_workspace() {
    local ws="$TF_WORKSPACE"
    ( cd "$TF_DIR" && unset TF_WORKSPACE && ( \
        "$TERRAFORM" workspace select "$ws" 2>/dev/null || \
        "$TERRAFORM" workspace new "$ws" ) ) >> "$TF_LOG" 2>&1
}

terraform_init_if_needed() {
    local ws
    ws=$(cat "$TF_DIR/.terraform/environment" 2>/dev/null || echo "")
    if [[ ! -d "$TF_DIR/.terraform" ]] || [[ "$ws" != "$TF_WORKSPACE" ]]; then
        ( cd "$TF_DIR" && "$TERRAFORM" init -reconfigure -input=false -no-color >> "$TF_LOG" 2>&1 )
    fi
}

terraform_destroy() {
    if [[ "$TTY" == "false" ]]; then
        [[ "${CI_DESTROY_CONFIRM:-}" == "yes" ]] || { echo "Error: CI destroy requires CI_DESTROY_CONFIRM=yes"; exit 1; }
    elif [[ "$TARGET" == "prod" ]]; then
        echo ""
        echo "  ⚠  PRODUCTION DESTROY REQUESTED  ⚠"
        echo "  This will PERMANENTLY DELETE: dreamseed.online"
        echo ""
        read -rp "  Step 1/3 — Do you REALLY want to destroy PROD? [y/N] " a1
        [[ ! "${a1:-}" =~ ^[Yy]$ ]] && { echo "Aborted."; exit 0; }
        read -rp "  Step 2/3 — Are you absolutely sure? [y/N] " a2
        [[ ! "${a2:-}" =~ ^[Yy]$ ]] && { echo "Aborted."; exit 0; }
        echo "  Step 3/3 — Type 'destroy prod' to confirm: "
        read -rp "  > " a3
        [[ "$a3" != "destroy prod" ]] && { echo "Aborted."; exit 0; }
    else
        read -rp "  Destroy $TARGET? [y/N] " a
        [[ ! "${a:-}" =~ ^[Yy]$ ]] && { echo "Aborted."; exit 0; }
    fi

    export_tf_env

    # Check server reachability
    local ip; ip=$(cd "$TF_DIR" && "$TERRAFORM" output -raw server_ipv4 2>/dev/null || true)
    [[ -n "$ip" && -n "${SSH_KEY:-}" ]] && \
        ssh -o ConnectTimeout=5 -o BatchMode=yes -i "$SSH_KEY" "ubuntu@$ip" 'true' 2>/dev/null \
            && echo "  ✓ Server $ip reachable" \
            || echo "  ⚠ Server $ip unreachable — destroying anyway"

    terraform_init_if_needed || { echo "Terraform init failed"; cat "$TF_LOG"; return 1; }
    ( cd "$TF_DIR" && terraform_select_workspace ) >> "$TF_LOG" 2>&1 || step_fail "Failed to select Terraform workspace: $TF_WORKSPACE"

    ( cd "$TF_DIR" && "$TERRAFORM" show -no-color 2>/dev/null ) | grep -q "No state" && { echo "  No resources to destroy"; return 0; }

    local var_arg=""
    [[ "$TF_PROVIDER" == "aws" ]] && var_arg="-var=ssh_public_key_path=${SSH_PUBLIC_KEY_PATH:-/dev/null}"
    echo "  ━━━ Destroying resources ($TARGET)"

    local out; out=$(mktemp)
    # shellcheck disable=SC2086
    ( cd "$TF_DIR" && "$TERRAFORM" destroy -auto-approve -no-color $var_arg 2>&1 | tee -a "$out" ) || true
    grep -q "Destroy complete" "$out" || step_fail "Terraform destroy failed (check $TF_LOG)"
    cat "$out" >> "$TF_LOG"; rm -f "$out"

    rm -f "$SCRIPT_DIR/secrets/tfstate-backup/${TF_WORKSPACE}"_*.tfstate 2>/dev/null

    if [[ "$TARGET" != "prod" ]]; then
        local ws_del="$TF_WORKSPACE"
        ( cd "$TF_DIR" && unset TF_WORKSPACE && \
          "$TERRAFORM" workspace delete "$ws_del" 2>&1 ) >> "$TF_LOG" 2>&1 || true
    fi
    echo "  ✓ Destroyed"
}

# ----- Ansible execution -----

run_ansible() {
    local pb="$1" label="$2"
    [[ "$TTY" == "false" ]] && echo "::group::${label}"
    echo "    ▶ ${label}"
    ANSIBLE_CONFIG="$SCRIPT_DIR/ansible/ansible.cfg" \
    ANSIBLE_ROLES_PATH="$SCRIPT_DIR/ansible-roles" \
    ANSIBLE_FORCE_COLOR=0 ANSIBLE_NOCOLOR=1 \
    "$ANSIBLE_PLAYBOOK" -i "$INVENTORY_FILE" --extra-vars "@${VAULT_TMP}" \
        "$SCRIPT_DIR/ansible/$pb" 2>&1 | tee -a "$LOG"
    local rc="${PIPESTATUS[0]}"
    [[ "$TTY" == "false" ]] && echo "::endgroup::"
    return "$rc"
}

run_parallel() {
    local phase="$1"; shift
    [[ "$TTY" == "false" ]] && echo "::group::${phase}"
    echo "    ▶ ${phase}"
    local pids=() ok=true
    for entry in "$@"; do
        local pb="${entry%%:*}" label="${entry##*:}"
        echo "      ├ ${label}"
        (
            ANSIBLE_CONFIG="$SCRIPT_DIR/ansible/ansible.cfg" \
            ANSIBLE_ROLES_PATH="$SCRIPT_DIR/ansible-roles" \
            ANSIBLE_FORCE_COLOR=0 ANSIBLE_NOCOLOR=1 \
            "$ANSIBLE_PLAYBOOK" -i "$INVENTORY_FILE" --extra-vars "@${VAULT_TMP}" \
                "$SCRIPT_DIR/ansible/$pb" >> "$LOG" 2>&1
        ) &
        pids+=("$!")
    done
    for pid in "${pids[@]}"; do wait "$pid" || ok=false; done
    [[ "$TTY" == "false" ]] && echo "::endgroup::"
    $ok
}

# ----- service checks -----

check_services() {
    echo ""
    echo "  ▸ Post-deploy checks"

    local web_svc="nginx"
    [[ "$WEB_SERVER" == "apache" ]] && web_svc="apache2"
    local services=("$web_svc" "php${PHP_VERSION}-fpm" "mariadb" "victoria-metrics" "grafana-server")

    while IFS= read -r line; do
        local svc="${line%%:*}" status="${line#*: }"
        if [[ "$status" == "active" ]]; then
            echo "    ✓ $svc"
        else
            echo "    ✗ $svc — service not active"
        fi
    done < <(ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 \
        -i "$SSH_KEY" "ubuntu@$SERVER_IP" \
        "for s in ${services[*]}; do echo \"\$s: \$(systemctl is-active \"\$s\" 2>/dev/null || echo inactive)\"; done")

    local http
    http=$(ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 \
        -i "$SSH_KEY" "ubuntu@$SERVER_IP" \
        "curl -sk -o /dev/null -w '%{http_code}' --max-time 10 https://${DEPLOY_DOMAIN}/" 2>/dev/null || echo "000")
    if [[ "$http" == "200" || "$http" == "301" ]]; then
        echo "    ✓ HTTP $http $DEPLOY_DOMAIN"
        echo "    All checks passed"
    else
        echo "    ✗ HTTP $http $DEPLOY_DOMAIN — site not serving"
        step_fail "Site check failed: HTTP $http from https://${DEPLOY_DOMAIN}/"
    fi
}

# ----- main -----

main() {
    parse_args "$@"
    resolve_target

    LOCK_FILE="/tmp/deploy-${TARGET}.lock"
    mkdir "$LOCK_FILE" 2>/dev/null || { echo "Error: deploy already running for $TARGET ($LOCK_FILE)"; exit 1; }

    [[ "$TTY" == "false" && "$DESTROY_MODE" == "false" && "$DRY_RUN" != "true" ]] && echo "::group::Environment"
    echo "  Target:     $TARGET"
    echo "  Domain:     $DEPLOY_DOMAIN"
    echo "  Provider:   $TF_PROVIDER"
    echo "  Web server: $WEB_SERVER"
    echo "  Mode:       $([[ "$PARALLEL_MODE" == "true" ]] && echo "parallel" || echo "sequential")"
    [[ "$DESTROY_MODE" == "true" ]] && echo "  Action:     destroy"
    [[ "$TTY" == "false" && "$DESTROY_MODE" == "false" && "$DRY_RUN" != "true" ]] && echo "::endgroup::"

    local web_playbook="playbook-02-nginx.yml:Web server (Nginx/PHP)"
    [[ "$WEB_SERVER" == "apache" ]] && web_playbook="playbook-02-apache.yml:Web server (Apache/PHP)"

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

        terraform_init_if_needed || { echo "Terraform init failed"; cat "$TF_LOG"; step_fail "Terraform init failed"; }
        ( cd "$TF_DIR" && terraform_select_workspace ) || step_fail "Failed to select workspace: $TF_WORKSPACE"

        local tf_args=""
        [[ "$TF_PROVIDER" == "aws" ]] && tf_args="-var=ssh_public_key_path=${SSH_PUBLIC_KEY_PATH:-/dev/null}"

        local ok=false
        for try in 1 2; do
            # shellcheck disable=SC2086
            if ( cd "$TF_DIR" && "$TERRAFORM" apply -auto-approve -no-color $tf_args >> "$TF_LOG" 2>&1 ); then
                ok=true; break
            fi
            [[ $try -lt 2 ]] && { echo "    Attempt $try/2 failed, retrying in 10s..."; sleep 10; }
        done
        [[ "$ok" != "true" ]] && { tail -30 "$TF_LOG"; step_fail "Terraform apply failed"; }

        SERVER_IP=$(cd "$TF_DIR" && "$TERRAFORM" output -raw server_ipv4 2>/dev/null) || step_fail "Could not get server IP"
        [[ -z "$SERVER_IP" ]] && step_fail "Empty IP from Terraform"

        ssh-keygen -R "$SERVER_IP" > /dev/null 2>&1 || true

        local bk="$SCRIPT_DIR/secrets/tfstate-backup"
        mkdir -p "$bk"
        [[ -f "$TF_DIR/terraform.tfstate" ]] && \
            cp "$TF_DIR/terraform.tfstate" "$bk/${TF_WORKSPACE}_$(date +%Y%m%d_%H%M%S).tfstate"
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
    fi
    step_start "Wait for SSH ($SERVER_IP)"
    local ready=false
    for i in $(seq 1 "$SSH_ATTEMPTS"); do
        if ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 \
            -o BatchMode=yes -i "$SSH_KEY" "ubuntu@$SERVER_IP" 'true' 2>/dev/null; then
            ready=true; break
        fi
        [[ $i -eq $SSH_ATTEMPTS ]] && step_fail "SSH not ready after ${SSH_ATTEMPTS}s"
        printf "."; sleep "$SSH_INTERVAL"
    done
    echo ""
    if [[ "$ready" == "true" ]]; then step_ok; else step_fail "SSH failed"; fi

    # ----- Wait for cloud-init -----
    step_start "Wait for cloud-init"
    ssh -i "$SSH_KEY" "ubuntu@$SERVER_IP" "timeout 300 cloud-init status --wait" >/dev/null 2>/dev/null || {
        for i in $(seq 1 "$CLOUDINIT_ATTEMPTS"); do
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
        echo "db_pass: \"$(yaml_escape "$DB_PASS")\""
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
        echo "secrets_dir: \"${SCRIPT_DIR}/secrets\""
        echo "configs_dir: \"${SCRIPT_DIR}/configs\""
        echo "scripts_dir: \"${SCRIPT_DIR}/scripts\""
        [[ -n "${CLOUDFLARE_API_TOKEN:-}" ]] && echo "cloudflare_api_token: \"$(yaml_escape "$CLOUDFLARE_API_TOKEN")\""
        [[ -n "${GRAFANA_PASS:-}" ]] && echo "grafana_admin_password: \"$(yaml_escape "$GRAFANA_PASS")\""
        [[ -n "${SSH_PUBLIC_KEY_PATH:-}" ]] && echo "ssh_public_key_path: \"${SSH_PUBLIC_KEY_PATH}\""
        [[ -n "${GRAFANA_CLOUD_URL:-}" ]] && echo "grafana_cloud_url: \"$(yaml_escape "$GRAFANA_CLOUD_URL")\""
        [[ -n "${GRAFANA_CLOUD_USERNAME:-}" ]] && echo "grafana_cloud_username: \"$(yaml_escape "$GRAFANA_CLOUD_USERNAME")\""
        [[ -n "${GRAFANA_CLOUD_TOKEN:-}" ]] && echo "grafana_cloud_token: \"$(yaml_escape "$GRAFANA_CLOUD_TOKEN")\""
        [[ -n "${ADDITIONAL_SSH_KEYS:-}" ]] && {
            echo "additional_ssh_keys:"
            while IFS= read -r key; do
                [[ -n "$key" ]] && echo "  - \"$(yaml_escape "$key")\""
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
