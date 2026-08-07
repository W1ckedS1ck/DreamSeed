# Preflight checks for deploy.sh
# shellcheck shell=bash
# Sourced by deploy.sh — do not execute directly.

# Guard against deploying a protected ref (main/master) into a dev env.
# A real incident shipped prod-main code to dev-aws because dispatch made no
# branch/env pairing. Dev envs must run from dev/feature branches; prod may
# come from main. Never blocks prod, never blocks destroy, never blocks unless
# the ref is main/master — and ALLOW_UNPROTECTED_REF=1 overrides if ever needed.
guard_source_ref() {
    local refs residue
    refs="${GIT_REF:-}"
    if [[ -z "$refs" ]]; then
        refs="$(git -C "${SCRIPT_DIR:-.}" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
    fi
    residue="$(basename "${refs//refs\/heads\/}")"
    [[ "$TARGET" =~ ^dev- && "$DESTROY_MODE" == "false" ]] || return 0
    case "$residue" in
        main|master)
            if [[ -n "${ALLOW_UNPROTECTED_REF:-}" ]]; then
                echo "⚠ Warning: dev env deploying from protected ref '$residue' (allowed via ALLOW_UNPROTECTED_REF)"
            else
                echo "✗ Error: TARGET=$TARGET (dev) cannot deploy from ref '$refs' (main/master)."
                echo "  Dev envs run from the dev branch; this blocks a prod ref from leaking into dev."
                echo "  To force anyway (not recommended): ALLOW_UNPROTECTED_REF=1 ./deploy.sh ..."
                exit 1
            fi
            ;;
    esac
}

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
    guard_source_ref
    check_prerequisites

    local env_src; env_src=$(resolve_env_file "$ENV_FILE")
    validate_env_file "$env_src"

    source "$env_src"
    export DB_PASS PHP_VERSION CLOUDFLARE_API_TOKEN GRAFANA_PASS DEPLOY_DOMAIN WEB_SERVER
    export SSH_PUBLIC_KEY_PATH ADDITIONAL_SSH_KEYS
    export BETTERUPTIME_API_TOKEN BETTERUPTIME_BACKUP_KEY BETTERUPTIME_GDRIVE_KEY BETTERUPTIME_REPORT_DAILY_KEY BETTERUPTIME_REPORT_WEEKLY_KEY BETTERUPTIME_VERIFY_KEY BETTERUPTIME_CHECK_SERVICES_KEY
    export TG_TOKEN TG_CHAT_ID TG_THREAD_ID
    export EMAIL_USER EMAIL_PASS SMTP_SERVER SMTP_PORT OWNER LOKI_URL LOKI_USERNAME FARO_COLLECTOR_URL FARO_APP_NAME
    export RCLONE_CRYPT_PASSWORD
    export UBUNTU_PRO_TOKEN

    # Auto-setup Better Stack heartbeats for prod if needed
    if [[ "$TARGET" =~ ^prod && -z "${BETTERUPTIME_BACKUP_KEY:-}" && -n "${BETTERUPTIME_API_TOKEN:-}" ]]; then
        if bash "$SCRIPT_DIR/scripts/setup_betteruptime.sh" --write-env; then
            env_src=$(resolve_env_file "$ENV_FILE")
            validate_env_file "$env_src"
            source "$env_src"
        else
            echo "⚠ Warning: Better Stack heartbeat setup failed. Continuing without heartbeats."
            echo "  To set up manually later, run: bash scripts/setup_betteruptime.sh --write-env"
        fi
    fi

    apply_target_vars

    # Load Grafana Cloud credentials (PROD_ for prod, DEV_ for all dev)
    local gc_pfx="DEV"
    [[ "$TARGET" =~ ^prod ]] && gc_pfx="PROD"
    local gc_url="${gc_pfx}_GRAFANA_CLOUD_URL"
    local gc_user="${gc_pfx}_GRAFANA_CLOUD_USERNAME"
    local gc_token="${gc_pfx}_GRAFANA_CLOUD_TOKEN"
    GRAFANA_CLOUD_URL="${!gc_url:-}"
    GRAFANA_CLOUD_USERNAME="${!gc_user:-}"
    GRAFANA_CLOUD_TOKEN="${!gc_token:-}"
    export GRAFANA_CLOUD_URL GRAFANA_CLOUD_USERNAME GRAFANA_CLOUD_TOKEN

    # Sanity checks — remote_write to Grafana Cloud has 3 easy ways to fail silently.
    # Cheap format hints so a bad value doesn't ship a 401-loop to the server.
    if [[ -n "$GRAFANA_CLOUD_URL" ]]; then
        if [[ "$GRAFANA_CLOUD_URL" != *"prometheus-"* ]]; then
            echo "⚠ Warning: ${gc_url}=${GRAFANA_CLOUD_URL}"
            echo "  Expected regional Prometheus URL (https://prometheus-prod-NN-<region>.grafana.net)."
            echo "  Vanity URL <stack>.grafana.net does NOT accept remote_write — will 401."
        fi
        if [[ "$GRAFANA_CLOUD_URL" == */api/prom/push ]]; then
            echo "⚠ Warning: ${gc_url} ends with /api/prom/push — template will append it again."
            echo "  Strip the suffix; the vmagent role adds it."
        fi
    fi
    if [[ -n "$GRAFANA_CLOUD_TOKEN" && "$GRAFANA_CLOUD_TOKEN" == glsa_* ]]; then
        echo "✗ Error: ${gc_token} starts with glsa_ (Service Account token)."
        echo "  vmagent needs a Cloud Access Policy token (glc_*, scope=metrics:write)."
        echo "  glsa_* tokens are for Terraform provider — belongs in ${gc_pfx}_GRAFANA_CLOUD_SA_TOKEN."
        exit 1
    fi

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
