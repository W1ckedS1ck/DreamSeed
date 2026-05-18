#!/bin/bash
set -euo pipefail

VERSION="1.0.1"

# --- Configuration ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${LOG_DIR:-$SCRIPT_DIR/logs}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/Vitali.pem}"
PHP_VERSION="${PHP_VERSION:-8.3}"
VAULT_PASSWORD_FILE="${VAULT_PASSWORD_FILE:-$HOME/.vault_pass_dreamseed}"

# Executable paths
ANSIBLE_PLAYBOOK="${ANSIBLE_PLAYBOOK:-ansible-playbook}"
TERRAFORM="${TERRAFORM:-terraform}"

export LC_ALL=C.UTF-8

# Timeouts
SSH_ATTEMPTS="${SSH_ATTEMPTS:-20}"
SSH_RETRY_INTERVAL="${SSH_RETRY_INTERVAL:-1}"
AWS_SSH_ATTEMPTS="${AWS_SSH_ATTEMPTS:-40}"
AWS_SSH_RETRY_INTERVAL="${AWS_SSH_RETRY_INTERVAL:-10}"
CLOUDINIT_ATTEMPTS="${CLOUDINIT_ATTEMPTS:-15}"
CLOUDINIT_RETRY_INTERVAL="${CLOUDINIT_RETRY_INTERVAL:-2}"

# Runtime state
WEB_SERVER=""
TARGET=""
TF_PROVIDER=""
TF_WORKSPACE=""
TARGET_PREFIX=""
DEPLOY_DOMAIN=""
ENV_FILE=""
TF_DIR=""
SKIP_TERRAFORM=false
EXISTING_IP=""
DESTROY_MODE=false
PARALLEL_MODE=false
VAULT_TMP=""
ENV_DECRYPTED_TMP=""
SERVER_IP=""

DEPLOY_START=$(date +%s)
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/deploy_$(date +%Y%m%d_%H%M%S).log"
TF_LOG="$LOG_DIR/terraform_$(date +%Y%m%d_%H%M%S).log"
DEPLOY_HISTORY="$LOG_DIR/deploy_history.log"

STEP_NUM=0
TOTAL_STEPS=0
STEP_DURATIONS=()
STEP_NAMES=()

# Colors
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
CYAN=$'\033[0;36m'
BOLD=$'\033[1m'
DIM=$'\033[2m'
NC=$'\033[0m'
# Disable spinner/colors when not running in an interactive terminal (e.g. CI)
[[ -t 1 ]] || { RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; DIM=''; NC=''; }
TTY_MODE=$([[ -t 1 ]] && echo true || echo false)

# --- Helpers ---
yaml_escape() {
    local val="$1"
    val="${val//\\/\\\\}"
    val="${val//\"/\\\"}"
    val="${val//$'\n'/\\n}"
    printf '%s' "$val"
}

progress_bar() {
    local current=$1 total=$2
    local width=8 filled empty bar="" i
    if (( total > 0 )); then
        filled=$(( current * width / total ))
    else
        filled=0
    fi
    empty=$(( width - filled ))
    for (( i=0; i<filled; i++ )); do bar+="━"; done
    for (( i=0; i<empty; i++ )); do bar+="░"; done
    printf '%s' "$bar"
}

step_icon() {
    case "$1" in
        *Terraform*)  printf '▲' ;;
        *SSH*)        printf '→' ;;
        *Cloud-init*) printf '☁' ;;
        *Ansible*|*Base*|*Web*|*Database*|*Monitor*|*Grafana*|*Security*) printf '⚙' ;;
        *existing*)   printf '↻' ;;
        *Inventory*)  printf '⊞' ;;
        *Destroy*)    printf '✕' ;;
        *Check*|*check*) printf '✓' ;;
        *)            printf '·' ;;
    esac
}

# --- Targets ---
# Each target defines: provider, domain, env file, terraform workspace
resolve_target() {
    ENV_FILE="$SCRIPT_DIR/secrets/.env"
    case "$TARGET" in
        prod)
            TF_PROVIDER="aws"
            DEPLOY_DOMAIN="dreamseed.online"
            TF_WORKSPACE="prod"
            TARGET_PREFIX="PROD"
            ;;
        dev-aws)
            TF_PROVIDER="aws"
            DEPLOY_DOMAIN="aws.vitalikuts.online"
            TF_WORKSPACE="dev-aws"
            TARGET_PREFIX="DEV_AWS"
            ;;
        dev-hetz)
            TF_PROVIDER="hetzner"
            DEPLOY_DOMAIN="hetz.vitalikuts.online"
            TF_WORKSPACE="dev-hetz"
            TARGET_PREFIX="DEV_HETZ"
            ;;
    esac
    TF_DIR="$SCRIPT_DIR/terraform/${TF_PROVIDER}"
}

# Map PROD_AWS_ACCESS_KEY / DEV_AWS_ACCESS_KEY / ... → standard var names
# DB_PASS and GRAFANA_PASS are shared — read directly from .env
apply_target_vars() {
    if [[ "$TF_PROVIDER" == "aws" ]]; then
        local pfx="$TARGET_PREFIX"
        local v_key="${pfx}_ACCESS_KEY"
        local v_sec="${pfx}_SECRET_KEY"
        local v_reg="${pfx}_REGION"
        local v_eip="${pfx}_EIP"
        AWS_ACCESS_KEY="${!v_key:-}"
        AWS_SECRET_KEY="${!v_sec:-}"
        AWS_REGION="${!v_reg:-us-west-1}"
        AWS_EIP_ALLOCATION_ID="${!v_eip:-}"
        export AWS_ACCESS_KEY AWS_SECRET_KEY AWS_REGION AWS_EIP_ALLOCATION_ID
    fi
}

# Export provider-specific TF_VAR_* / AWS_* env vars for Terraform
export_tf_env() {
    if [[ "$TF_PROVIDER" == "aws" ]]; then
        export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY:-}"
        export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_KEY:-}"
        export AWS_DEFAULT_REGION="${AWS_REGION:-us-west-1}"
        [[ -n "${AWS_EIP_ALLOCATION_ID:-}" ]] && \
            export TF_VAR_elastic_ip_allocation_id="$AWS_EIP_ALLOCATION_ID"
    fi
    [[ -n "${CLOUDFLARE_API_TOKEN:-}" ]] && export TF_VAR_cloudflare_api_token="$CLOUDFLARE_API_TOKEN"
    [[ -n "${CLOUDFLARE_ZONE_ID:-}" ]] && export TF_VAR_cloudflare_zone_id="$CLOUDFLARE_ZONE_ID"
    if [[ "$TF_PROVIDER" == "hetzner" ]]; then
        export TF_VAR_hcloud_token="${HCLOUD_TOKEN:-}"
    fi
    export TF_VAR_environment="$TARGET"
    export TF_TOKEN_app_terraform_io="${TF_API_TOKEN:-}"
    export TF_WORKSPACE="$TF_WORKSPACE"
}

# --- Helper functions ---

cleanup() {
    [[ -n "${VAULT_TMP:-}" && -f "${VAULT_TMP:-}" ]] && rm -f "$VAULT_TMP"
    [[ -n "${ENV_DECRYPTED_TMP:-}" && -f "${ENV_DECRYPTED_TMP:-}" ]] && rm -f "$ENV_DECRYPTED_TMP"
}

trap 'cleanup; echo -e "\n${YELLOW}Interrupted! Exiting...${NC}"; exit 130' INT TERM
trap cleanup ERR

usage() {
    cat << EOF
DreamSeed Deploy Script  v${VERSION}

Usage: \$0 TARGET -n|-a [OPTIONS]

TARGETS:
    prod               AWS        · dreamseed.online        · secrets/.env
    dev-aws            AWS        · aws.vitalikuts.online   · secrets/.env
    dev-hetz           Hetzner    · hetz.vitalikuts.online  · secrets/.env

WEB SERVER (required):
    -n                 Nginx
    -a                 Apache

OPTIONS:
    -i IP              Use existing server (skip Terraform)
    -x, --destroy      Destroy resources
    -p, --parallel     Parallel playbook execution (3 phases)
    -h                 Show this help

EXAMPLES:
    \$0 prod -n                  Deploy prod (AWS + Nginx)
    \$0 prod -a                  Deploy prod (AWS + Apache)
    \$0 dev-aws -n               Deploy dev on AWS (Nginx)
    \$0 dev-hetz -n              Deploy dev on Hetzner (Nginx)
    \$0 prod -n -i 1.2.3.4       Ansible-only on existing server
    \$0 prod -x                  Destroy prod resources
EOF
    exit 1
}

parse_args() {
    if [[ $# -eq 0 ]]; then usage; fi

    while [[ $# -gt 0 ]]; do
        case $1 in
            prod|dev-aws|dev-hetz) TARGET="$1"; shift ;;
            -n) WEB_SERVER="nginx"; shift ;;
            -a) WEB_SERVER="apache"; shift ;;
            -i|--ip) EXISTING_IP="$2"; SKIP_TERRAFORM=true; shift 2 ;;
            -x|--destroy) DESTROY_MODE=true; shift ;;
            -p|--parallel) PARALLEL_MODE=true; shift ;;
            -h|--help) usage ;;
            *) echo -e "${RED}Unknown option: $1${NC}"; usage ;;
        esac
    done

    if [[ -z "$TARGET" ]]; then
        echo -e "${RED}Error: target required. Choose: prod | dev-aws | dev-hetz${NC}"
        usage
    fi

    if [[ -z "$WEB_SERVER" ]] && [[ "$DESTROY_MODE" == "false" ]]; then
        echo -e "${RED}Error: web server required. Use -n (Nginx) or -a (Apache)${NC}"
        usage
    fi
}

log_error_details() {
    local log_file="$1"
    if [[ -f "$log_file" ]]; then
        echo -e "\n${RED}=== Error: $(basename "$log_file") ===${NC}"
        local errors
        errors=$(grep -i -E "(error|fail|fatal|panic)" "$log_file" | tail -10)
        if [[ -n "$errors" ]]; then
            echo -e "${YELLOW}Error indicators:${NC}"
            echo "$errors" | while IFS= read -r line; do
                echo -e "  ${RED}!${NC} $line"
            done
            echo -e "\n${YELLOW}Last 30 lines:${NC}"
        else
            echo -e "${YELLOW}Last 30 lines:${NC}"
        fi
        tail -30 "$log_file"
        echo -e "${YELLOW}Full log: ${log_file}${NC}"
    fi
}

validate_env_file() {
    local env_file="$1"
    if [[ ! -f "$env_file" ]]; then
        echo -e "${RED}Error: env file not found: $env_file${NC}"
        exit 1
    fi
    local line_num=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        ((line_num++)) || true
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        if [[ ! "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
            echo -e "${RED}Error: Invalid env format at $env_file:$line_num: $line${NC}"
            exit 1
        fi
    done < "$env_file"
}

# If ENV_FILE is ansible-vault encrypted, decrypt to a tmp file (0600) and
# echo the tmp path. Otherwise echo the original path. Tmp file is removed
# by cleanup() via trap.
resolve_env_file() {
    local env_file="$1"
    if [[ ! -f "$env_file" ]]; then
        echo -e "${RED}Error: env file not found: $env_file${NC}" >&2
        exit 1
    fi
    if head -c 16 "$env_file" 2>/dev/null | grep -qF '$ANSIBLE_VAULT'; then
        if [[ ! -f "$VAULT_PASSWORD_FILE" ]]; then
            echo -e "${RED}Error: $env_file is vault-encrypted but password file not found: $VAULT_PASSWORD_FILE${NC}" >&2
            echo -e "${YELLOW}Hint: echo -n 'your-password' > $VAULT_PASSWORD_FILE && chmod 600 $VAULT_PASSWORD_FILE${NC}" >&2
            exit 1
        fi
        ENV_DECRYPTED_TMP=$(mktemp)
        chmod 600 "$ENV_DECRYPTED_TMP"
        if ! ansible-vault view "$env_file" --vault-password-file "$VAULT_PASSWORD_FILE" > "$ENV_DECRYPTED_TMP" 2>/dev/null; then
            echo -e "${RED}Error: failed to decrypt $env_file (wrong password?)${NC}" >&2
            exit 1
        fi
        printf '%s' "$ENV_DECRYPTED_TMP"
    else
        printf '%s' "$env_file"
    fi
}

write_deploy_history() {
    local status="$1" error_msg="${2:-}"
    local ts duration
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    duration=$(( $(date +%s) - DEPLOY_START ))
    printf "%s | %-7s | %-8s | %-6s | %-15s | %5ss | v%s" \
        "$ts" "$status" "$TARGET" "${WEB_SERVER:-N/A}" "${SERVER_IP:-N/A}" "$duration" "$VERSION" \
        >> "$DEPLOY_HISTORY"
    [[ -n "$error_msg" ]] && printf " | %s" "$error_msg" >> "$DEPLOY_HISTORY"
    echo >> "$DEPLOY_HISTORY"
}

preflight_checks() {
    local env_to_source
    env_to_source=$(resolve_env_file "$ENV_FILE")
    validate_env_file "$env_to_source"
    local _saved_opts
    _saved_opts="$(set +o)"
    set -a; source "$env_to_source"; set +a
    eval "$_saved_opts"
    apply_target_vars

    # Override SSH_KEY if SSH_PRIVATE_KEY_PATH is set in .env
    if [[ -n "${SSH_PRIVATE_KEY_PATH:-}" ]]; then
        SSH_KEY="$SSH_PRIVATE_KEY_PATH"
    fi

    if [[ ! -f "$SSH_KEY" ]]; then
        echo -e "${RED}Error: SSH key not found: $SSH_KEY${NC}"
        exit 1
    fi

    if [[ "$DESTROY_MODE" == "false" ]]; then
        [[ -z "${DB_PASS:-}" ]]     && { echo -e "${RED}Error: DB_PASS not set in $ENV_FILE${NC}"; exit 1; }
        [[ -z "${GRAFANA_PASS:-}" ]] && { echo -e "${RED}Error: GRAFANA_PASS not set in $ENV_FILE${NC}"; exit 1; }
    fi

    if [[ "$TF_PROVIDER" == "aws" ]]; then
        if [[ -z "${AWS_ACCESS_KEY:-}" ]] || [[ -z "${AWS_SECRET_KEY:-}" ]]; then
            echo -e "${RED}Error: AWS_ACCESS_KEY and AWS_SECRET_KEY required${NC}"; exit 1
        fi
        : "${AWS_REGION:=us-west-1}"
        if [[ -z "${SSH_PUBLIC_KEY_PATH:-}" ]]; then
            echo -e "${RED}Error: SSH_PUBLIC_KEY_PATH not set in $ENV_FILE${NC}"; exit 1
        fi
    fi

    if [[ "$TF_PROVIDER" == "hetzner" ]]; then
        [[ -z "${HCLOUD_TOKEN:-}" ]] && { echo -e "${RED}Error: HCLOUD_TOKEN not set in $ENV_FILE${NC}"; exit 1; }
    fi

    if [[ "$SKIP_TERRAFORM" == "false" ]] && [[ ! -f "$TF_DIR/main.tf" ]]; then
        echo -e "${RED}Error: Terraform config not found: $TF_DIR/main.tf${NC}"; exit 1
    fi
}

calculate_steps() {
    TOTAL_STEPS=0
    if [[ "$DESTROY_MODE" == "true" ]]; then TOTAL_STEPS=1; return; fi
    [[ "$SKIP_TERRAFORM" == "false" ]] && ((TOTAL_STEPS++)) || true
    ((TOTAL_STEPS += 2))  # SSH, cloud-init
    if [[ "$PARALLEL_MODE" == "true" ]]; then
        TOTAL_STEPS=$((TOTAL_STEPS + 4))  # base, phase2, phase3, grafana
    else
        TOTAL_STEPS=$((TOTAL_STEPS + ${#playbooks[@]}))
    fi
}

step_start() {
    local name=$1
    ((STEP_NUM++)) || true
    STEP_START=$(date +%s)
    STEP_LABEL="$name"
    local bar icon
    bar=$(progress_bar "$STEP_NUM" "$TOTAL_STEPS")
    icon=$(step_icon "$name")
    if [[ "$TTY_MODE" == "false" ]]; then
        printf "\n  %s %d/%d %s %-36s\n" "$bar" "$STEP_NUM" "$TOTAL_STEPS" "$icon" "$name"
    else
        printf "\n  ${DIM}%s${NC} ${CYAN}%d/%d${NC} ${icon} ${BOLD}%-36s${NC}" "$bar" "$STEP_NUM" "$TOTAL_STEPS" "$name"
    fi
}

step_ok() {
    local elapsed=$(( $(date +%s) - STEP_START ))
    local bar icon
    bar=$(progress_bar "$STEP_NUM" "$TOTAL_STEPS")
    icon=$(step_icon "${STEP_LABEL:-}")
    STEP_DURATIONS+=("$elapsed")
    STEP_NAMES+=("${STEP_LABEL:-}")
    if [[ "$TTY_MODE" == "false" ]]; then
        printf "  %s %d/%d %s %-36s  ✓ %s\n" "$bar" "$STEP_NUM" "$TOTAL_STEPS" "$icon" "${STEP_LABEL:-}" "$(format_time $elapsed)"
    else
        printf "\r\033[K  ${DIM}%s${NC} ${CYAN}%d/%d${NC} ${icon} ${BOLD}%-36s${NC} ${GREEN}✓${NC} ${YELLOW}%s${NC}\n" "$bar" "$STEP_NUM" "$TOTAL_STEPS" "${STEP_LABEL:-}" "$(format_time $elapsed)"
    fi
}

step_fail() {
    local bar
    bar=$(progress_bar "$STEP_NUM" "$TOTAL_STEPS")
    if [[ "$TTY_MODE" == "false" ]]; then
        printf "  %s %d/%d ✗ %s\n" "$bar" "$STEP_NUM" "$TOTAL_STEPS" "${STEP_LABEL:-}"
        echo "::error title=${STEP_LABEL:-Deploy}::$1"
    else
        printf "\r\033[K  ${DIM}%s${NC} ${CYAN}%d/%d${NC} ${RED}✗${NC} ${BOLD}%-36s${NC}\n" "$bar" "$STEP_NUM" "$TOTAL_STEPS" "${STEP_LABEL:-}"
        echo -e "${RED}Error: $1${NC}"
    fi
    [[ -n "${DEPLOY_HISTORY:-}" ]] && write_deploy_history "FAILURE" "$1" 2>/dev/null || true
    exit 1
}

format_time() {
    local s=$1
    if [[ $s -ge 3600 ]]; then printf "%dh %02dm %02ds" $((s/3600)) $(((s%3600)/60)) $((s%60))
    elif [[ $s -ge 60 ]]; then printf "%dm %02ds" $((s/60)) $((s%60))
    else printf "%ds" "$s"; fi
}

print_summary() {
    echo -e "\n  ${DIM}────────────────────────────────────────────────────${NC}"
    printf "  ${BOLD}%-5s %-35s %s${NC}\n" "" "Step" "Time"
    echo -e "  ${DIM}────────────────────────────────────────────────────${NC}"
    local i icon name dur
    for i in "${!STEP_NAMES[@]}"; do
        name="${STEP_NAMES[$i]}"
        dur="${STEP_DURATIONS[$i]}"
        icon=$(step_icon "$name")
        printf "  ${icon}  %-35s ${YELLOW}%s${NC}\n" "$name" "$(format_time $dur)"
    done
    echo -e "  ${DIM}────────────────────────────────────────────────────${NC}"
    local total_time=$(( $(date +%s) - DEPLOY_START ))
    printf "  ${BOLD}%-38s ${YELLOW}%s${NC}\n" "Total" "$(format_time $total_time)"
}

run_with_spinner() {
    local label="$1"; shift
    local icon
    icon=$(step_icon "$label")
    if [[ "$TTY_MODE" == "false" ]]; then
        local bar
        bar=$(progress_bar "$STEP_NUM" "$TOTAL_STEPS")
        echo "  $bar $STEP_NUM/$TOTAL_STEPS $icon $label"
        "$@"
        return
    fi
    local spins=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    local i=0
    "$@" &
    local pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        local elapsed=$(( $(date +%s) - STEP_START ))
        local bar
        bar=$(progress_bar "$STEP_NUM" "$TOTAL_STEPS")
        printf "\r\033[K  ${DIM}%s${NC} ${CYAN}%d/%d${NC} ${icon} ${BOLD}%-36s${NC}  ${CYAN}%s${NC} ${YELLOW}%ds${NC}" \
            "$bar" "$STEP_NUM" "$TOTAL_STEPS" "$label" "${spins[$i]}" "$elapsed"
        i=$(( (i + 1) % ${#spins[@]} ))
        sleep 0.3
    done
    printf "\r\033[K"
    wait "$pid"
}

run_ansible() {
    local args=("$@")

    if [[ "$TTY_MODE" == "false" ]]; then
        local status_file tmp_output
        status_file=$(mktemp)
        tmp_output=$(mktemp)

        echo "::group::${STEP_LABEL:-Ansible}"

        local task_num=0 task_name="" task_pending=false
        local counts_ok=0 counts_changed=0 counts_skipped=0 counts_failed=0
        local lines_read=0

        _ci_print_task() { printf "  [%2d] %-58s %s\n" "$task_num" "$task_name" "$1"; }

        _ci_parse_lines() {
            local line
            while IFS= read -r line; do
                if [[ "$line" =~ ^TASK[[:space:]]\[(.+)\] ]]; then
                    task_name="${BASH_REMATCH[1]}"
                    ((task_num++)) || true; task_pending=true
                elif [[ "$task_pending" == "true" ]]; then
                    case "$line" in
                        changed:*)        _ci_print_task "✎ changed"; ((counts_changed++)) || true; task_pending=false ;;
                        ok:*)             _ci_print_task "· ok";      ((counts_ok++))      || true; task_pending=false ;;
                        failed:*|fatal:*) _ci_print_task "✗ FAILED";  ((counts_failed++))  || true; task_pending=false ;;
                        skipping:*)       _ci_print_task "– skipped";  ((counts_skipped++)) || true; task_pending=false ;;
                    esac
                fi
            done
        }

        ANSIBLE_CONFIG="$SCRIPT_DIR/ansible/ansible.cfg" \
        ANSIBLE_ROLES_PATH="$SCRIPT_DIR/ansible-roles" \
        ANSIBLE_FORCE_COLOR=0 \
        ANSIBLE_NOCOLOR=1 \
        "$ANSIBLE_PLAYBOOK" "${args[@]}" > "$tmp_output" 2>&1 &
        local ansible_pid=$!

        while kill -0 "$ansible_pid" 2>/dev/null; do
            local new_count
            new_count=$(wc -l < "$tmp_output" 2>/dev/null || echo 0)
            if [[ $new_count -gt $lines_read ]]; then
                _ci_parse_lines < <(tail -n +"$(( lines_read + 1 ))" "$tmp_output")
                lines_read=$new_count
            fi
            sleep 0.2
        done

        local final_count
        final_count=$(wc -l < "$tmp_output" 2>/dev/null || echo 0)
        if [[ $final_count -gt $lines_read ]]; then
            _ci_parse_lines < <(tail -n +"$(( lines_read + 1 ))" "$tmp_output")
        fi

        wait "$ansible_pid"; echo "$?" > "$status_file"

        printf "\n  Tasks: %d  —  ok: %d  changed: %d  skipped: %d  failed: %d\n" \
            "$task_num" "$counts_ok" "$counts_changed" "$counts_skipped" "$counts_failed"
        echo "::endgroup::"

        sed 's/\x1b\[[0-9;]*[mGKHF]//g; s/\r//g' "$tmp_output" >> "$LOG"
        local status
        status=$(cat "$status_file")
        rm -f "$status_file" "$tmp_output"
        return "$status"
    fi

    local task_num=0
    local task_name=""
    local task_status=""
    local task_start=0
    local spin_i=0
    local spinners=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    local term_width
    term_width=$(tput cols 2>/dev/null || echo 80)
    local name_width=$(( term_width - 28 ))
    local status_file
    status_file=$(mktemp)

    _render_task_line() {
        local short_name="${task_name:0:$name_width}"
        [[ ${#task_name} -gt $name_width ]] && short_name="${short_name%?}…"
        local suffix=""
        case "$task_status" in
            C) suffix=" ${GREEN}✎${NC}" ;;
            F) suffix=" ${RED}✗${NC}" ;;
            .) suffix=" ${GREEN}·${NC}" ;;
            s) suffix=" ${YELLOW}–${NC}" ;;
            *)
                local elapsed=$(( $(date +%s) - task_start ))
                suffix=" ${CYAN}${spinners[$spin_i]}${NC} ${YELLOW}${elapsed}s${NC}"
                ;;
        esac
        printf "\r\033[K    ${CYAN}[%d]${NC} ${YELLOW}→${NC} %s%s" "$task_num" "$short_name" "$suffix"
    }

    printf "\n"

    local tmp_output
    tmp_output=$(mktemp)
    local lines_read=0

    ANSIBLE_CONFIG="$SCRIPT_DIR/ansible/ansible.cfg" \
    ANSIBLE_ROLES_PATH="$SCRIPT_DIR/ansible-roles" \
    ANSIBLE_FORCE_COLOR=0 \
    ANSIBLE_NOCOLOR=1 \
    "$ANSIBLE_PLAYBOOK" "${args[@]}" > "$tmp_output" 2>&1 &
    local ansible_pid=$!

    while kill -0 "$ansible_pid" 2>/dev/null; do
        local new_count
        new_count=$(wc -l < "$tmp_output" 2>/dev/null || echo 0)

        if [[ $new_count -gt $lines_read ]]; then
            while IFS= read -r line; do
                if [[ "$line" =~ ^TASK[[:space:]]\[(.+)\] ]]; then
                    ((task_num++)) || true
                    task_name="${BASH_REMATCH[1]}"
                    task_status=""
                    task_start=$(date +%s)
                elif [[ "$line" =~ ^changed: ]];         then task_status="C"
                elif [[ "$line" =~ ^ok: ]];              then task_status="."
                elif [[ "$line" =~ ^(failed|fatal): ]];  then task_status="F"
                elif [[ "$line" =~ ^skipping: ]];        then task_status="s"
                fi
            done < <(tail -n +$(( lines_read + 1 )) "$tmp_output")
            lines_read=$new_count
        fi

        spin_i=$(( (spin_i + 1) % ${#spinners[@]} ))
        [[ -n "$task_name" ]] && _render_task_line
        sleep 0.15
    done

    wait "$ansible_pid"; echo "$?" > "$status_file"
    local status
    status=$(cat "$status_file")
    sed 's/\x1b\[[0-9;]*[mGKHF]//g; s/\r//g' "$tmp_output" >> "$LOG"
    rm -f "$status_file" "$tmp_output"

    printf "\r\033[K\033[1A"
    return "$status"
}

run_parallel_phase() {
    local phase_name="$1"; shift
    local entries=("$@")
    local pids=() results_dir result_files=()
    results_dir=$(mktemp -d)

    for entry in "${entries[@]}"; do
        local pb="${entry%%:*}" label="${entry##*:}" pb_path="$SCRIPT_DIR/ansible/$pb"
        local status_f="$results_dir/${pb//\//_}.status"
        local log_f="$results_dir/${pb//\//_}.log"
        result_files+=("$status_f" "$log_f")

        if [[ "$TTY_MODE" == "false" ]]; then
            echo "::group::${label}"
        else
            printf "  ${CYAN}→${NC} %s\n" "$label"
        fi

        (
            ANSIBLE_CONFIG="$SCRIPT_DIR/ansible/ansible.cfg" \
            ANSIBLE_ROLES_PATH="$SCRIPT_DIR/ansible-roles" \
            ANSIBLE_FORCE_COLOR=0 \
            ANSIBLE_NOCOLOR=1 \
            "$ANSIBLE_PLAYBOOK" "$pb_path" "${base_args[@]}" > "$log_f" 2>&1
            echo "$?" > "$status_f"
        ) &
        pids+=("$!")
    done

    for pid in "${pids[@]}"; do wait "$pid"; done

    local phase_ok=true
    local idx=0
    for entry in "${entries[@]}"; do
        local label="${entry##*:}"
        local status_f="${result_files[$(( idx * 2 ))]}"
        local log_f="${result_files[$(( idx * 2 + 1 ))]}"
        local status
        status=$(cat "$status_f" 2>/dev/null || echo "1")

        sed 's/\x1b\[[0-9;]*[mGKHF]//g; s/\r//g' "$log_f" >> "$LOG"

        if [[ "$TTY_MODE" == "false" ]]; then
            echo "::endgroup::"
        fi

        if [[ "$status" == "0" ]]; then
            if [[ "$TTY_MODE" == "false" ]]; then
                printf "  ✓ %s\n" "$label"
            else
                printf "  ${GREEN}✓${NC} %s\n" "$label"
            fi
        else
            if [[ "$TTY_MODE" == "false" ]]; then
                printf "  ✗ %s\n" "$label"
            else
                printf "  ${RED}✗${NC} %s\n" "$label"
            fi
            log_error_details "$log_f"
            phase_ok=false
        fi
        ((idx++)) || true
    done

    rm -rf "$results_dir"
    $phase_ok || step_fail "$phase_name failed"
}

terraform_select_workspace() {
    local ws="$TF_WORKSPACE"
    # TF_WORKSPACE env var blocks workspace select/new — unset it inside the subshell.
    ( cd "$TF_DIR" && unset TF_WORKSPACE && \
        "$TERRAFORM" workspace select "$ws" 2>/dev/null || \
        "$TERRAFORM" workspace new "$ws" ) >> "$TF_LOG" 2>&1
}

terraform_init_if_needed() {
    local current_ws
    current_ws=$(cat "$TF_DIR/.terraform/environment" 2>/dev/null || echo "")
    if [[ ! -d "$TF_DIR/.terraform" ]] || [[ "$current_ws" != "$TF_WORKSPACE" ]]; then
        ( cd "$TF_DIR" && "$TERRAFORM" init -reconfigure -input=false -no-color >> "$TF_LOG" 2>&1 )
    fi
}

terraform_destroy() {
    if [[ "$TTY_MODE" == "false" ]]; then
        # CI: confirmation already validated by the workflow step via CI_DESTROY_CONFIRM
        echo "CI destroy confirmed for: $TARGET (CI_DESTROY_CONFIRM=${CI_DESTROY_CONFIRM:-})"
    elif [[ "$TARGET" == "prod" ]]; then
echo -e "\n${RED}╭──────────────────────────────────────────────────╮${NC}"
    printf "${RED}│${NC}  ${BOLD}%-48s${NC}${RED}│${NC}\n" "⚠  PRODUCTION DESTROY REQUESTED  ⚠"
    echo -e "${RED}│${NC}                                                  ${RED}│${NC}"
    printf "${RED}│${NC}  %-48s${RED}│${NC}\n" "This will PERMANENTLY DELETE:"
    printf "${RED}│${NC}    · %-44s${RED}│${NC}\n" "EC2 instance (dreamseed.online)"
    printf "${RED}│${NC}    · %-44s${RED}│${NC}\n" "Security group"
    printf "${RED}│${NC}    · %-44s${RED}│${NC}\n" "Key pair"
    echo -e "${RED}│${NC}                                                  ${RED}│${NC}"
    printf "${RED}│${NC}  ${BOLD}%-48s${NC}${RED}│${NC}\n" "THE SITE WILL GO OFFLINE."
    echo -e "${RED}╰──────────────────────────────────────────────────╯${NC}\n"

        read -rp "  Step 1/3 — Do you REALLY want to destroy PROD? [y/N] " a1
        [[ ! "${a1:-}" =~ ^[Yy]$ ]] && { echo -e "${GREEN}Good choice. Aborted.${NC}"; exit 1; }

        read -rp "  Step 2/3 — Are you absolutely sure? [y/N] " a2
        [[ ! "${a2:-}" =~ ^[Yy]$ ]] && { echo -e "${GREEN}Good choice. Aborted.${NC}"; exit 1; }

        echo -e "\n  Step 3/3 — Type ${RED}destroy prod${NC} to confirm: "
        read -rp "  > " a3
        [[ "$a3" != "destroy prod" ]] && { echo -e "${GREEN}Good choice. Aborted.${NC}"; exit 1; }

        echo -e "\n${RED}Proceeding with PRODUCTION destroy...${NC}\n"
    else
        echo -e "${YELLOW}Destroying resources for target: ${BOLD}${TARGET}${NC}"
        read -rp "Are you sure? [y/N] " answer
        [[ ! "${answer:-}" =~ ^[Yy]$ ]] && { echo -e "${RED}Aborted.${NC}"; exit 1; }
    fi

    export_tf_env

    terraform_init_if_needed || {
        log_error_details "$TF_LOG"
        echo -e "  ${RED}✗${NC} Terraform init failed  ${YELLOW}($TF_LOG)${NC}"
        return 1
    }

    ( cd "$TF_DIR" && terraform_select_workspace ) >> "$TF_LOG" 2>&1
    if ( cd "$TF_DIR" && "$TERRAFORM" show -no-color 2>/dev/null ) | grep -q "No state"; then
        echo -e "${YELLOW}No resources to destroy${NC}"; return 0
    fi
    local tf_destroy_var_arg=""
    [[ "$TF_PROVIDER" == "aws" ]] && tf_destroy_var_arg="-var=ssh_public_key_path=${SSH_PUBLIC_KEY_PATH:-/dev/null}"
    echo "  ━━━━━━━━ ✕ Destroying resources ($TARGET)"
    # TFC exits 1 when there is nothing to destroy — use || true and check log instead
    local destroy_out
    destroy_out=$(mktemp)
    # shellcheck disable=SC2086
    ( cd "$TF_DIR" && "$TERRAFORM" destroy -auto-approve -no-color $tf_destroy_var_arg 2>&1 | tee -a "$destroy_out" ) || true
    grep -q "Destroy complete" "$destroy_out" || step_fail "Terraform destroy failed (check $TF_LOG)"
    cat "$destroy_out" >> "$TF_LOG"
    rm -f "$destroy_out"
    
    local tfstate_backup_dir="$SCRIPT_DIR/secrets/tfstate-backup"
    rm -f "$tfstate_backup_dir/${TF_WORKSPACE}"_*.tfstate 2>/dev/null
    
    # Cleanup: delete workspace (non-prod only)
    # TFC may exit 1 on workspace delete even on success — use || true and check log
    if [[ "$TARGET" != "prod" ]]; then
        ( cd "$TF_DIR" && "$TERRAFORM" workspace select default 2>&1 && \
          "$TERRAFORM" workspace delete "$TF_WORKSPACE" 2>&1 ) >> "$TF_LOG" 2>&1 || true
        if grep -q "Deleted workspace\|has been deleted\|workspace.*deleted" "$TF_LOG" 2>/dev/null; then
            echo -e "  ${GREEN}✓${NC} Workspace deleted  ${YELLOW}($TF_WORKSPACE)${NC}"
        else
            echo -e "  ${YELLOW}⚠${NC} Workspace delete may have failed — check TFC UI  ${YELLOW}($TF_WORKSPACE)${NC}"
        fi
    fi
    
    echo -e "  ${GREEN}✓${NC} Destroyed  ${YELLOW}Log: $TF_LOG${NC}"
}

check_services() {
    echo -e "\n  ${CYAN}▸ Post-deploy checks${NC}"

    local web_svc="nginx"
    [[ "$WEB_SERVER" == "apache" ]] && web_svc="apache2"
    local services=("$web_svc" "php${PHP_VERSION}-fpm" "mariadb" "victoria-metrics" "grafana-server")

    local result_dir
    result_dir=$(mktemp -d)
    local pids=()

    for svc in "${services[@]}"; do
        {
            if ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 \
                -i "$SSH_KEY" "ubuntu@$SERVER_IP" "systemctl is-active $svc" &>/dev/null; then
                echo "ok" > "$result_dir/$svc"
            else
                echo "fail" > "$result_dir/$svc"
            fi
        } &
        pids+=($!)
    done

    for pid in "${pids[@]}"; do wait "$pid"; done

    local all_ok=true
    for svc in "${services[@]}"; do
        if [[ "$(cat "$result_dir/$svc")" == "ok" ]]; then
            echo -e "  ${GREEN}✓${NC} $svc"
        else
            echo -e "  ${RED}✗${NC} $svc"
            all_ok=false
        fi
    done

    rm -rf "$result_dir"
    $all_ok && echo -e "  ${GREEN}All services OK${NC}" || echo -e "  ${RED}Some services failed${NC}"
}

rotate_logs() {
    local max_logs="${MAX_LOG_FILES:-10}"
    # shellcheck disable=SC2012  # log filenames are timestamped, no spaces/newlines
    ls -1t "$LOG_DIR"/*.log 2>/dev/null | tail -n +"$((max_logs + 1))" | xargs rm -f 2>/dev/null || true
}

# --- Main ---

main() {
    parse_args "$@"
    resolve_target

    local web_playbook="playbook-02-nginx.yml:Web server (Nginx/PHP)"
    [[ "$WEB_SERVER" == "apache" ]] && web_playbook="playbook-02-apache.yml:Web server (Apache/PHP)"
    playbooks=(
        "playbook-01-base.yml:Base packages"
        "$web_playbook"
        "playbook-03-db.yml:Database & Restore"
        "playbook-04-monitor.yml:Monitoring (Exporters+VM)"
        "playbook-04.5-backup.yml:Backup & Telegram bot"
        "playbook-05-grafana.yml:Grafana"
        "playbook-06-security.yml:Security hardening"
    )

    preflight_checks
    calculate_steps

    if [[ "$DESTROY_MODE" == "true" ]]; then
        step_start "Terraform destroy ($TARGET)"
        terraform_destroy
        step_ok
        write_deploy_history "DESTROYED"
        exit 0
    fi

    echo -e "\n${CYAN}╭──────────────────────────────────────────────────────────╮${NC}"
    printf "${CYAN}│${NC}  ${BOLD}%-56s${NC}${CYAN}│${NC}\n" "DreamSeed Deploy  v${VERSION}"
    echo -e "${CYAN}├──────────────────────────────────────────────────────────┤${NC}"
    printf "${CYAN}│${NC}  Target      ${BOLD}%-44s${NC}${CYAN}│${NC}\n" "$TARGET"
    printf "${CYAN}│${NC}  Domain      ${BOLD}%-44s${NC}${CYAN}│${NC}\n" "$DEPLOY_DOMAIN"
    printf "${CYAN}│${NC}  Provider    ${BOLD}%-44s${NC}${CYAN}│${NC}\n" "$TF_PROVIDER"
    printf "${CYAN}│${NC}  Web server  ${BOLD}%-44s${NC}${CYAN}│${NC}\n" "$WEB_SERVER"
    printf "${CYAN}│${NC}  Mode        ${BOLD}%-44s${NC}${CYAN}│${NC}\n" "$([[ "$PARALLEL_MODE" == "true" ]] && echo "parallel" || echo "sequential")"
    echo -e "${CYAN}╰──────────────────────────────────────────────────────────╯${NC}"

    if [[ "$TARGET" == "prod" && "$DESTROY_MODE" == "false" ]]; then
        echo -e "\n${YELLOW}⚠  Deploying to PRODUCTION (${DEPLOY_DOMAIN})${NC}"
        if [[ "${CI:-}" == "true" ]]; then
            echo -e "  ${GREEN}CI mode — confirmation skipped${NC}"
        else
            read -rp "  Continue? [y/N] " confirm
            [[ ! "${confirm:-}" =~ ^[Yy]$ ]] && { echo -e "${RED}Aborted.${NC}"; exit 1; }
        fi
    fi

    rotate_logs

    if [[ "$SKIP_TERRAFORM" == "false" ]]; then
        step_start "Terraform init + apply"
        export_tf_env

        terraform_init_if_needed || {
            log_error_details "$TF_LOG"
            step_fail "Terraform init failed"
        }

        ( cd "$TF_DIR" && terraform_select_workspace ) || \
            step_fail "Failed to select Terraform workspace: $TF_WORKSPACE"

        local tf_apply_extra_vars=""
        [[ "$TF_PROVIDER" == "aws" ]] && tf_apply_extra_vars="-var='ssh_public_key_path=${SSH_PUBLIC_KEY_PATH:-}'"

        local tf_ok=false
        for tf_attempt in 1 2; do
            if run_with_spinner "Terraform apply" \
                bash -c "cd '$TF_DIR' && '$TERRAFORM' apply -auto-approve -no-color $tf_apply_extra_vars >> '$TF_LOG' 2>&1"; then
                tf_ok=true; break
            fi
            [[ $tf_attempt -lt 2 ]] && {
                echo -e "\n    ${YELLOW}Attempt $tf_attempt/2 failed, retrying in 10s...${NC}"
                sleep 10
            }
        done
        [[ "$tf_ok" != "true" ]] && { log_error_details "$TF_LOG"; step_fail "Terraform failed"; }

        SERVER_IP=$( cd "$TF_DIR" && "$TERRAFORM" output -raw server_ipv4 2>/dev/null ) || \
            step_fail "Could not get server_ipv4 from Terraform output"
        [[ -z "$SERVER_IP" ]] && step_fail "Empty IP from Terraform output"

        ssh-keygen -R "$SERVER_IP" > /dev/null 2>&1 || true

        local tfstate_backup_dir="$SCRIPT_DIR/secrets/tfstate-backup"
        mkdir -p "$tfstate_backup_dir"
        [[ -f "$TF_DIR/terraform.tfstate" ]] && \
            cp "$TF_DIR/terraform.tfstate" "$tfstate_backup_dir/${TF_WORKSPACE}_$(date +%Y%m%d_%H%M%S).tfstate"
        # shellcheck disable=SC2012  # tfstate filenames are timestamped, no spaces/newlines
        ls -1t "$tfstate_backup_dir/${TF_WORKSPACE}"_*.tfstate 2>/dev/null | tail -n +6 | xargs rm -f 2>/dev/null || true

        step_ok
    else
        step_start "Using existing server"
        SERVER_IP="$EXISTING_IP"
        step_ok
    fi

    if [[ "$TF_PROVIDER" == "aws" ]]; then
        SSH_ATTEMPTS="$AWS_SSH_ATTEMPTS"
        SSH_RETRY_INTERVAL="$AWS_SSH_RETRY_INTERVAL"
    fi

    step_start "Wait for SSH"
    local ssh_ready=false
    for i in $(seq 1 "$SSH_ATTEMPTS"); do
        if ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 \
            -o BatchMode=yes -i "$SSH_KEY" "ubuntu@$SERVER_IP" 'true' 2>/dev/null; then
            ssh_ready=true; break
        fi
        if [[ $i -eq $SSH_ATTEMPTS ]]; then
            step_fail "SSH not ready after ${SSH_ATTEMPTS} attempts ($(( SSH_ATTEMPTS * SSH_RETRY_INTERVAL ))s).
  Server may still be booting. Retry with:
  ${BOLD}$0 $TARGET -${WEB_SERVER:0:1} -i $SERVER_IP${NC}"
        fi
        printf "."; sleep "$SSH_RETRY_INTERVAL"
    done
    $ssh_ready && step_ok || step_fail "SSH connection failed"

    step_start "Wait for Cloud-init"
    local ci_timeout=300
    ssh -i "$SSH_KEY" "ubuntu@$SERVER_IP" "timeout $ci_timeout cloud-init status --wait" >/dev/null 2>/dev/null || {
        for i in $(seq 1 "$CLOUDINIT_ATTEMPTS"); do
            local ci_status
            ci_status=$(ssh -i "$SSH_KEY" "ubuntu@$SERVER_IP" \
                'cloud-init status 2>/dev/null || echo "unknown"' 2>/dev/null || echo "unknown")
            [[ "$ci_status" == *"status: done"* || "$ci_status" == *"No pending"* ]] && break
            [[ $i -eq $CLOUDINIT_ATTEMPTS ]] && step_fail "Cloud-init timeout ($(( CLOUDINIT_ATTEMPTS * CLOUDINIT_RETRY_INTERVAL ))s)"
            printf "."; sleep "$CLOUDINIT_RETRY_INTERVAL"
        done
    }
    step_ok

    mkdir -p "$SCRIPT_DIR/ansible/inventory"
    local INVENTORY_FILE="$SCRIPT_DIR/ansible/inventory/hosts-${TF_WORKSPACE}.yml"
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
    VAULT_TMP=$(mktemp)
    chmod 600 "$VAULT_TMP"
    {
        echo "db_pass: \"$(yaml_escape "${DB_PASS}")\""
        echo "server_ip: \"${SERVER_IP}\""
        echo "web_server: \"${WEB_SERVER}\""
        echo "domain: \"${DEPLOY_DOMAIN}\""
        echo "secrets_dir: \"${SCRIPT_DIR}/secrets\""
        echo "configs_dir: \"${SCRIPT_DIR}/configs\""
        echo "scripts_dir: \"${SCRIPT_DIR}/scripts\""
        [[ -n "${CLOUDFLARE_API_TOKEN:-}" ]] && \
            echo "cloudflare_api_token: \"$(yaml_escape "${CLOUDFLARE_API_TOKEN}")\""
        [[ -n "${GRAFANA_PASS:-}" ]] && \
            echo "grafana_admin_password: \"$(yaml_escape "${GRAFANA_PASS}")\""
        [[ -n "${SSH_PUBLIC_KEY_PATH:-}" ]] && \
            echo "ssh_public_key_path: \"${SSH_PUBLIC_KEY_PATH}\""
    } > "$VAULT_TMP"

    base_args=("-i" "$INVENTORY_FILE" "--extra-vars" "@${VAULT_TMP}")

    if [[ "$PARALLEL_MODE" == "true" ]]; then
        echo -e "\n  ${CYAN}▸ Parallel execution${NC}"

        step_start "Ansible: Base packages"
        run_ansible "$SCRIPT_DIR/ansible/playbook-01-base.yml" "${base_args[@]}" && step_ok || step_fail "Base packages failed"

        local phase2=("$web_playbook" "playbook-03-db.yml:Database & Restore" "playbook-06-security.yml:Security hardening")
        run_parallel_phase "Phase 2 (Web/DB/Security)" "${phase2[@]}"

        local phase3=("playbook-04-monitor.yml:Monitoring" "playbook-04.5-backup.yml:Backup & Telegram bot")
        run_parallel_phase "Phase 3 (Monitoring/Backup)" "${phase3[@]}"

        step_start "Ansible: Grafana"
        run_ansible "$SCRIPT_DIR/ansible/playbook-05-grafana.yml" "${base_args[@]}" && step_ok || step_fail "Grafana failed"
    else
        for entry in "${playbooks[@]}"; do
        local pb="${entry%%:*}"
        local label="${entry##*:}"
        step_start "Ansible: $label"
        if run_ansible "$SCRIPT_DIR/ansible/$pb" "${base_args[@]}"; then
            step_ok
        else
            log_error_details "$LOG"
            step_fail "$label failed"
        fi
    done
    fi

    local checks_start=$(date +%s)
    check_services
    local checks_elapsed=$(( $(date +%s) - checks_start ))
    STEP_DURATIONS+=("$checks_elapsed")
    STEP_NAMES+=("Post-deploy checks")

    local total_time=$(( $(date +%s) - DEPLOY_START ))

    print_summary

    write_deploy_history "SUCCESS"

    echo -e "\n${GREEN}╭──────────────────────────────────────────────────────────╮${NC}"
    printf "${GREEN}│${NC}  ${BOLD}%-56s${NC}${GREEN}│${NC}\n" "✓ Deployment Successful!"
    echo -e "${GREEN}├──────────────────────────────────────────────────────────┤${NC}"
    printf "${GREEN}│${NC}  Server   ${BOLD}%-47s${NC}${GREEN}│${NC}\n" "$SERVER_IP"
    printf "${GREEN}│${NC}  Site     ${BOLD}%-47s${NC}${GREEN}│${NC}\n" "https://${DEPLOY_DOMAIN}"
    printf "${GREEN}│${NC}  Grafana  ${BOLD}%-47s${NC}${GREEN}│${NC}\n" "https://${DEPLOY_DOMAIN}/grafana/"
    printf "${GREEN}│${NC}  SSH      ${BOLD}%-47s${NC}${GREEN}│${NC}\n" "ssh -i ${SSH_KEY##*/} ubuntu@${SERVER_IP}"
    printf "${GREEN}│${NC}  Time     ${BOLD}%-47s${NC}${GREEN}│${NC}\n" "$(format_time $total_time)"
    echo -e "${GREEN}╰──────────────────────────────────────────────────────────╯${NC}"
    echo -e "  Logs: ${LOG}\n"
}

main "$@"
