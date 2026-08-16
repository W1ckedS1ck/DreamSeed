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
    if command -v tofu &>/dev/null; then
        TERRAFORM="tofu"
    elif command -v terraform &>/dev/null; then
        TERRAFORM="terraform"
    else
        echo "Error: neither tofu nor terraform found in PATH"
        exit 1
    fi
fi

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
NC=$'\033[0m'
[[ -t 1 ]] || {
    RED=''
    GREEN=''
    YELLOW=''
    NC=''
}
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
: >"$LOG"
chmod 600 "$LOG"
: >"$DEPLOY_TF_LOG"
chmod 600 "$DEPLOY_TF_LOG"

# Load modules
source "$SCRIPT_DIR/lib/helpers.sh"
source "$SCRIPT_DIR/lib/env.sh"
source "$SCRIPT_DIR/lib/preflight.sh"
source "$SCRIPT_DIR/lib/terraform.sh"
source "$SCRIPT_DIR/lib/ansible.sh"
source "$SCRIPT_DIR/lib/cli.sh"
source "$SCRIPT_DIR/lib/stages.sh"
source "$SCRIPT_DIR/lib/provision.sh"
source "$SCRIPT_DIR/lib/wait.sh"
source "$SCRIPT_DIR/lib/inventory.sh"
source "$SCRIPT_DIR/lib/playbooks.sh"
source "$SCRIPT_DIR/lib/post.sh"

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

# ----- main -----

main() {
    parse_args "$@"
    resolve_target

    acquire_lock

    local web_playbook="playbook-02-web.yml:Web server (Nginx/Apache + PHP)"

    PLAYBOOK_LIST=(
        "playbook-01-base.yml:Base packages"
        "$web_playbook"
        "playbook-03-db.yml:Database & Restore"
        "playbook-09-pro.yml:Ubuntu Pro"
        "playbook-04-security.yml:Security hardening"
        "playbook-05-monitor.yml:Monitoring"
        "playbook-06-backup.yml:Backup & Telegram bot"
        "playbook-08-promtail.yml:Promtail"
        "playbook-07-grafana.yml:Grafana"
    )

    print_env

    preflight_checks

    validate_playbooks

    # ----- Check mode (validate only) -----
    [[ "$CHECK_MODE" == "true" ]] && run_check_mode

    # ----- Dry run -----
    [[ "$DRY_RUN" == "true" ]] && run_dry_run

    # ----- Production confirmation -----
    confirm_production

    # ----- Destroy path -----
    [[ "$DESTROY_MODE" == "true" ]] && run_destroy

    rotate_logs

    # ----- Terraform -----
    run_terraform

    # ----- Wait for server -----
    wait_for_server

    # ----- Generate inventory + vars -----
    generate_inventory

    # ----- Ansible playbooks -----
    run_playbooks "$web_playbook"

    # ----- DNS update -----
    update_dns

    # ----- Post-deploy checks -----
    local chk_start
    chk_start=$(date +%s)
    check_services
    STEP_NAMES+=("Post-deploy checks")
    STEP_TIMES+=($(($(date +%s) - chk_start)))

    # ----- Record deployed commit -----
    record_deploy

    # ----- Final summary -----
    print_final_summary
}

main "$@"
