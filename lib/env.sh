# Environment variable handling for deploy.sh
# shellcheck shell=bash
# Sourced by deploy.sh — do not execute directly.

validate_env_file() {
    local f="$1" n=0 required=("DB_PASS" "GRAFANA_PASS" "TG_TOKEN" "TG_CHAT_ID")
    while IFS= read -r line || [[ -n "$line" ]]; do
        ((n++)) || true
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || { echo "Invalid env format at $f:$n: $line" >&2; exit 1; }
    done < "$f"
    for req in "${required[@]}"; do
        source "$f" 2>/dev/null || true
        local val="${!req:-}"
        [[ -z "$val" ]] && { echo "Error: required var $req is empty or undefined in $f" >&2; exit 1; }
    done
    return 0
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
            local pk; pk="${SSH_PUBLIC_KEY_PATH/#\~/$HOME}"
            if [[ -r "$pk" ]]; then
                local pk_content; pk_content="$(<"$pk")"
                export TF_VAR_ssh_public_key="$pk_content"
            fi
        fi
    }
    export TF_VAR_environment="$TARGET"
    export TF_TOKEN_app_terraform_io="${TF_API_TOKEN:-}"
}
