# Environment variable handling for deploy.sh
# shellcheck shell=bash
# Sourced by deploy.sh — do not execute directly.

validate_env_file() {
    local f="$1" n=0 required=("DB_PASS" "GRAFANA_PASS" "TG_TOKEN" "TG_CHAT_ID") in_quote=0
    if head -c 16 "$f" 2>/dev/null | grep -qF '$ANSIBLE_VAULT'; then
        echo "Error: File '$f' is ansible-vault encrypted. Decrypt with: ansible-vault decrypt '$f' --vault-password-file ~/.vault_pass_dreamseed" >&2
        exit 1
    fi
    while IFS= read -r line || [[ -n "$line" ]]; do
        ((n++)) || true
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        if [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
            local val="${line#*=}"
            if [[ "$val" == *'$('* || "$val" == *'`'* ]]; then
                echo "Error: code injection detected in $f:$n: $line" >&2
                exit 1
            fi
            [[ "$val" =~ ^\" && ! "$val" =~ \"$ ]] && in_quote=1 || in_quote=0
        elif [[ "$in_quote" -eq 1 ]]; then
            [[ "$line" =~ \"$ ]] && in_quote=0
            continue
        else
            echo "Invalid env format at $f:$n: $line" >&2; exit 1
        fi
    done < "$f"
    source "$f" 2>/dev/null || true
    for req in "${required[@]}"; do
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
        [[ -n "${ENV_DECRYPTED_TMP:-}" && -f "${ENV_DECRYPTED_TMP:-}" ]] && rm -f "$ENV_DECRYPTED_TMP"
        local tmp; tmp=$(mktemp); chmod 600 "$tmp"
        ANSIBLE_VAULT_PASSWORD_FILE="$pw" ansible-vault view "$f" > "$tmp" 2>/dev/null || { echo "Error: vault decrypt failed" >&2; exit 1; }
        [[ -s "$tmp" ]] || { echo "Error: vault decrypted file is empty" >&2; exit 1; }
        ENV_DECRYPTED_TMP="$tmp"
        printf '%s' "$tmp"
    else
        printf '%s' "$f"
    fi
}

apply_target_vars() {
    local pfx="$TARGET_PREFIX"
    if [[ "$TF_PROVIDER" == "aws" ]]; then
        local v_key="${pfx}_ACCESS_KEY" v_sec="${pfx}_SECRET_KEY"
        local v_reg="${pfx}_REGION" v_eip="${pfx}_EIP"
        AWS_ACCESS_KEY="${!v_key:-}"
        AWS_SECRET_KEY="${!v_sec:-}"
        AWS_REGION="${!v_reg:-us-west-1}"
        AWS_EIP_ALLOCATION_ID="${!v_eip:-}"
        export AWS_ACCESS_KEY AWS_SECRET_KEY AWS_REGION AWS_EIP_ALLOCATION_ID
    fi
    if [[ "$TF_PROVIDER" == "hetzner" ]]; then
        local v_token="${pfx}_HCLOUD_TOKEN"
        local v_type="${pfx}_SERVER_TYPE"
        local v_loc="${pfx}_LOCATION"
        local v_keyname="${pfx}_SSH_KEY_NAME"
        local v_ipname="${pfx}_PRIMARY_IP_NAME"
        local v_create_ip="${pfx}_ENABLE_PRIMARY_IP"
        # Prefixed vars (e.g. PROD_HETZ_HCLOUD_TOKEN) take precedence;
        # fall back to unprefixed (e.g. HCLOUD_TOKEN) for backward compatibility
        HCLOUD_TOKEN="${!v_token:-${HCLOUD_TOKEN:-}}"
        HETZNER_SERVER_TYPE="${!v_type:-${HETZNER_SERVER_TYPE:-}}"
        HETZNER_LOCATION="${!v_loc:-${HETZNER_LOCATION:-}}"
        HETZNER_SSH_KEY_NAME="${!v_keyname:-${HETZNER_SSH_KEY_NAME:-}}"
        HETZNER_PRIMARY_IP_NAME="${!v_ipname:-${HETZNER_PRIMARY_IP_NAME:-}}"
        HETZNER_ENABLE_PRIMARY_IP="${!v_create_ip:-${HETZNER_ENABLE_PRIMARY_IP:-}}"
        export HCLOUD_TOKEN HETZNER_SERVER_TYPE HETZNER_LOCATION HETZNER_SSH_KEY_NAME HETZNER_PRIMARY_IP_NAME HETZNER_ENABLE_PRIMARY_IP
    fi
}

export_tf_env() {
    [[ "$TF_PROVIDER" == "aws" ]] && {
        export AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY"
        export AWS_SECRET_ACCESS_KEY="$AWS_SECRET_KEY"
        export AWS_DEFAULT_REGION="$AWS_REGION"
        [[ -n "${AWS_REGION:-}" ]] && export TF_VAR_aws_region="$AWS_REGION"
        [[ -n "${AWS_EIP_ALLOCATION_ID:-}" ]] && export TF_VAR_elastic_ip_allocation_id="$AWS_EIP_ALLOCATION_ID"
        # Build list of additional SSH keys from ADDITIONAL_SSH_KEYS env var
        # (CI deploy key is handled separately via aws_key_pair.deploy)
        export TF_VAR_additional_ssh_keys="$(python3 -c "
import os, json
additional = os.environ.get('ADDITIONAL_SSH_KEYS', '')
if additional:
    keys = [k.strip() for k in additional.strip().split('\n') if k.strip()]
else:
    keys = []
print(json.dumps(keys))
")"
    }
    [[ "$TF_PROVIDER" == "hetzner" ]] && {
        export TF_VAR_hcloud_token="${HCLOUD_TOKEN:-}"
        [[ -n "${HETZNER_SERVER_TYPE:-}" ]] && export TF_VAR_server_type="$HETZNER_SERVER_TYPE"
        [[ -n "${HETZNER_LOCATION:-}" ]] && export TF_VAR_location="$HETZNER_LOCATION"
        [[ -n "${HETZNER_SSH_KEY_NAME:-}" ]] && export TF_VAR_ssh_key_name="$HETZNER_SSH_KEY_NAME"
        [[ -n "${HETZNER_PRIMARY_IP_NAME:-}" ]] && export TF_VAR_primary_ip_name="$HETZNER_PRIMARY_IP_NAME"
        [[ -n "${HETZNER_ENABLE_PRIMARY_IP:-}" ]] && export TF_VAR_enable_primary_ip="$HETZNER_ENABLE_PRIMARY_IP"
        # Build list of additional SSH keys: deploy key + ADDITIONAL_SSH_KEYS env var
        export TF_VAR_additional_ssh_keys="$(python3 -c "
import os, json
keys = []
pk_path = os.environ.get('SSH_PUBLIC_KEY_PATH', '')
if pk_path:
    pk_path = os.path.expanduser(pk_path)
    if os.path.isfile(pk_path):
        with open(pk_path) as f:
            keys.append(f.read().strip())
additional = os.environ.get('ADDITIONAL_SSH_KEYS', '')
if additional:
    for k in additional.strip().split('\n'):
        k = k.strip()
        if k and k not in keys:
            keys.append(k)
print(json.dumps(keys))
")"
        # Also export ssh_public_key for TF to create CI key if needed
        # NOTE: TF_VAR_additional_ssh_keys is already set above (includes deploy key + ADDITIONAL_SSH_KEYS)
        if [[ -n "${SSH_PUBLIC_KEY_PATH:-}" ]]; then
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
