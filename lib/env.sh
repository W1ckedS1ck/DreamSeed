# Environment variable handling for deploy.sh
# shellcheck shell=bash
# Sourced by deploy.sh — do not execute directly.

validate_env_file() {
    local f="$1" n=0 quote=
    if head -c 16 "$f" 2>/dev/null | grep -qF '$ANSIBLE_VAULT'; then
        echo "Error: File '$f' is ansible-vault encrypted." >&2
        echo "  Decrypt with: ansible-vault decrypt '$f' --vault-password-file ~/.vault_pass_dreamseed" >&2
        echo "  Or for check/dry-run only: export DRY_RUN=true / CHECK_MODE=true and skip vault" >&2
        exit 1
    fi
    while IFS= read -r line || [[ -n "$line" ]]; do
        ((n++)) || true
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

        # Inside multi-line quoted value — skip until closing quote
        if [[ -n "$quote" ]]; then
            [[ "$line" == *"$quote" ]] && quote=
            continue
        fi

        if [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
            local val="${line#*=}"
            # Detect opening quote without matching closing quote → multi-line value
            if [[ "$val" =~ ^\"(.*)$ ]] && [[ ! "$val" =~ ^\"(.*)\"$ ]]; then
                quote='"'
            elif [[ "$val" =~ ^\'(.*)$ ]] && [[ ! "$val" =~ ^\'(.*)\'$ ]]; then
                quote="'"
            fi
            if [[ "$val" == *'$('* || "$val" == *'`'* || "$val" == *'${'* ]]; then
                echo "Error: code injection detected in $f:$n (key '${line%%=*}')" >&2
                exit 1
            fi
        else
            echo "Invalid env format at $f:$n: '${line:0:24}…' (truncated)" >&2; exit 1
        fi
    done < "$f"
    return 0
}

resolve_env_file() {
    # Sets ENV_SRC (path to source) and, for vault files, ENV_DECRYPTED_TMP
    # (path to the decrypted temp copy). Call WITHOUT command substitution —
    # results are propagated via globals so cleanup() in helpers.sh can find
    # the temp file and shred it on exit.
    local f="$1"
    ENV_SRC=""
    [[ ! -f "$f" ]] && { echo "Error: $f not found" >&2; exit 1; }
    if head -c 16 "$f" 2>/dev/null | grep -qF '$ANSIBLE_VAULT'; then
        local pw="${VAULT_PASSWORD_FILE:-$HOME/.vault_pass_dreamseed}"
        [[ ! -f "$pw" ]] && { echo "Error: vault password file not found: $pw" >&2; exit 1; }
        [[ -n "${ENV_DECRYPTED_TMP:-}" && -f "${ENV_DECRYPTED_TMP:-}" ]] && rm -f "$ENV_DECRYPTED_TMP"
        local tmp; tmp=$(mktemp); chmod 600 "$tmp"
        ANSIBLE_VAULT_PASSWORD_FILE="$pw" ansible-vault view "$f" > "$tmp" 2>/dev/null || { echo "Error: vault decrypt failed" >&2; exit 1; }
        [[ -s "$tmp" ]] || { echo "Error: vault decrypted file is empty" >&2; exit 1; }
        ENV_DECRYPTED_TMP="$tmp"
        ENV_SRC="$tmp"
    else
        ENV_SRC="$f"
    fi
}

apply_target_vars() {
    local pfx="$TARGET_PREFIX"
    if [[ "$TF_PROVIDER" == "aws" ]]; then
        local v_key="${pfx}_ACCESS_KEY" v_sec="${pfx}_SECRET_KEY"
        local v_reg="${pfx}_REGION"
        AWS_ACCESS_KEY="${!v_key:-}"
        AWS_SECRET_KEY="${!v_sec:-}"
        AWS_REGION="${!v_reg:-us-west-1}"
        export AWS_ACCESS_KEY AWS_SECRET_KEY AWS_REGION
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
        # Build list of additional SSH keys from ADDITIONAL_SSH_KEYS env var
        local ssh_keys
        ssh_keys="$(
          local arr=()
          while IFS= read -r k; do [[ -n "${k// /}" ]] && arr+=("$k"); done <<< "${ADDITIONAL_SSH_KEYS:-}"
          if [[ ${#arr[@]} -gt 0 ]]; then
            printf '%s\n' "${arr[@]}" | jq -R . | jq -s .
          else
            jq -n '[]'
          fi
        )" || { echo "Failed to build SSH keys list" >&2; exit 1; }
        export TF_VAR_additional_ssh_keys="$ssh_keys"
    }
    [[ "$TF_PROVIDER" == "hetzner" ]] && {
        export TF_VAR_hcloud_token="${HCLOUD_TOKEN:-}"
        [[ -n "${HETZNER_SERVER_TYPE:-}" ]] && export TF_VAR_server_type="$HETZNER_SERVER_TYPE"
        [[ -n "${HETZNER_LOCATION:-}" ]] && export TF_VAR_location="$HETZNER_LOCATION"
        [[ -n "${HETZNER_SSH_KEY_NAME:-}" ]] && export TF_VAR_ssh_key_name="$HETZNER_SSH_KEY_NAME"
        [[ -n "${HETZNER_PRIMARY_IP_NAME:-}" ]] && export TF_VAR_primary_ip_name="$HETZNER_PRIMARY_IP_NAME"
        [[ -n "${HETZNER_ENABLE_PRIMARY_IP:-}" ]] && export TF_VAR_enable_primary_ip="$HETZNER_ENABLE_PRIMARY_IP"
        # Build list of additional SSH keys: deploy key + ADDITIONAL_SSH_KEYS env var
        local ssh_keys
        ssh_keys="$(
          local arr=()
          local pk_path="${SSH_PUBLIC_KEY_PATH:-}"
          if [[ -n "$pk_path" ]]; then
            pk_path="${pk_path/#\~/$HOME}"
            if [[ -r "$pk_path" ]]; then
              arr+=("$(<"$pk_path")")
            fi
          fi
          local additional="${ADDITIONAL_SSH_KEYS:-}"
          if [[ -n "$additional" ]]; then
            while IFS= read -r k; do
              k="${k// /}"
              [[ -n "$k" ]] && arr+=("$k")
            done <<< "$additional"
          fi
          if [[ ${#arr[@]} -gt 0 ]]; then
            printf '%s\n' "${arr[@]}" | jq -R . | jq -s .
          else
            jq -n '[]'
          fi
        )" || { echo "Failed to build SSH keys list" >&2; exit 1; }
        export TF_VAR_additional_ssh_keys="$ssh_keys"
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
