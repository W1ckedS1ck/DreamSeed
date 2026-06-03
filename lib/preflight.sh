# Preflight checks for deploy.sh
# shellcheck shell=bash
# Sourced by deploy.sh — do not execute directly.

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
        if bash "$SCRIPT_DIR/scripts/setup_betteruptime.sh" --write-env; then
            env_src=$(resolve_env_file "$ENV_FILE")
            source "$env_src"
        else
            echo "⚠ Warning: Better Stack heartbeat setup failed. Continuing without heartbeats."
            echo "  To set up manually later, run: bash scripts/setup_betteruptime.sh --write-env"
        fi
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
