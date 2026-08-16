# Environment variable handling for deploy.sh
# shellcheck shell=bash
# Sourced by deploy.sh — do not execute directly.

# Safe .env parser: no `source`/eval → no RCE. Supports quoted/multi-line values,
# inline comments and $HOME/$UPPERCASE_VAR expansion. Rejects $()/backticks and
# dangerous var names (PATH, IFS, LD_PRELOAD, ...).
parse_env_file() {
    local f="$1" n=0 quote='' line key val
    if head -c 16 "$f" 2>/dev/null | grep -qF '$ANSIBLE_VAULT'; then
        echo "Error: File '$f' is ansible-vault encrypted." >&2
        echo "  Decrypt with: ansible-vault decrypt '$f' --vault-password-file ~/.vault_pass_dreamseed" >&2
        echo "  Or for check/dry-run only: export DRY_RUN=true / CHECK_MODE=true and skip vault" >&2
        return 1
    fi
    while IFS= read -r line || [[ -n "$line" ]]; do
        ((n++)) || true
        # Skip empty / comment lines
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

        # Inside multi-line quoted value — accumulate until closing quote
        if [[ -n "$quote" ]]; then
            if [[ "$line" == *"$quote"* ]]; then
                # Closing quote found: take everything before it, discard the rest (inline comment)
                val+=$'\n'"${line%%"$quote"*}"
                # Single-quoted values are literal (no $VAR expansion)
                local no_expand=""
                [[ "$quote" == "'" ]] && no_expand="1"
                _env_export "$f" "$n" "$key" "$val" "$no_expand" || return 1
                key=""
                val=""
                quote=""
            else
                val+=$'\n'"$line"
            fi
            continue
        fi

        # Strip optional leading "export "
        line="${line#"export "}"

        # Must be KEY=VALUE
        if [[ ! "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
            echo "Invalid env format at $f:$n: '${line:0:24}…' (truncated)" >&2
            return 1
        fi
        key="${BASH_REMATCH[1]}"
        val="${BASH_REMATCH[2]}"

        # Multi-line quoted value: opening quote without matching close on same line.
        # Trailing whitespace/comments after the closing quote are allowed.
        if [[ "$val" =~ ^\"(.*)$ && ! "$val" =~ ^\".*\"[[:space:]]*(#.*)?$ ]]; then
            quote='"'
            val="${val#\"}"
            continue
        elif [[ "$val" =~ ^\'(.*)$ && ! "$val" =~ ^\'.*\'[[:space:]]*(#.*)?$ ]]; then
            quote="'"
            val="${val#\'}"
            continue
        fi

        # Single-line: strip surrounding quotes (single layer) + inline comment after closing quote.
        # Trailing whitespace after the closing quote is allowed.
        local no_expand=""
        if [[ "$val" =~ ^\"(.*)\"[[:space:]]*(#.*)?$ ]]; then
            val="${BASH_REMATCH[1]}"
        elif [[ "$val" =~ ^\'(.*)\'[[:space:]]*(#.*)?$ ]]; then
            val="${BASH_REMATCH[1]}"
            no_expand="1" # Single-quoted values are literal (no $VAR expansion)
        else
            # Unquoted: strip inline comment (whitespace + #, but not # without preceding whitespace)
            val="${val%%[[:space:]]#*}"
            # Strip trailing whitespace left after comment removal (or trailing whitespace in general)
            val="${val%"${val##*[![:space:]]}"}"
        fi

        _env_export "$f" "$n" "$key" "$val" "$no_expand" || return 1
    done <"$f"

    if [[ -n "$quote" ]]; then
        echo "Error: unterminated quoted value for '$key' in $f (reached EOF)" >&2
        return 1
    fi
    return 0
}

# Export a single parsed env var with safety checks.
# Args: file line_num key value [no_expand]
# When no_expand is non-empty, $VAR references are kept literal (single-quoted values).
_env_export() {
    local f="$1" n="$2" key="$3" val="$4" no_expand="${5:-}"
    # Block dangerous variable names that could hijack shell behavior
    case "$key" in
        PATH | IFS | LD_PRELOAD | LD_LIBRARY_PATH | SHELL | SHELLOPTS | BASHOPTS | BASH_ENV | ENV | PS1 | PS2 | PS3 | PS4 | TMPDIR | USER | HOME | UID | GID | SHLVL | PPID | BASH_VERSION | BASH_SUBSHELL)
            echo "Error: blocked variable name '$key' in $f:$n" >&2
            return 1
            ;;
    esac
    # Reject command substitution patterns (defense-in-depth — export without
    # eval is safe, but block to prevent regressions if eval is ever introduced)
    if [[ "$val" == *'$('* || "$val" == *'`'* ]]; then
        echo "Error: command substitution detected in $f:$n (key '$key')" >&2
        return 1
    fi
    # Expand $HOME, ${HOME}, and $UPPERCASE_VAR references.
    # Only uppercase variable names are expanded — no RCE vector (indirect expansion, not eval).
    # Skipped for single-quoted values (no_expand=1) to match bash semantics.
    if [[ -z "$no_expand" ]]; then
        # Bound the expansion loop — a cyclic/self-referential value (e.g.
        # BAR='$BAR' followed by FOO=$BAR) would otherwise loop forever.
        local i=0
        while [[ "$val" =~ \$\{?([A-Z_][A-Z0-9_]*)\}? ]]; do
            local varname="${BASH_REMATCH[1]}"
            local varval="${!varname:-}"
            val="${val//\$\{$varname\}/$varval}"
            val="${val//\$$varname/$varval}"
            ((++i >= 10)) && {
                echo "Error: variable expansion limit exceeded in $f:$n (key '$key')" >&2
                return 1
            }
        done
    fi
    export "$key=$val"
}

resolve_env_file() {
    # Sets ENV_SRC (path to source) and, for vault files, ENV_DECRYPTED_TMP
    # (path to the decrypted temp copy). Call WITHOUT command substitution —
    # results are propagated via globals so cleanup() in helpers.sh can find
    # the temp file and shred it on exit.
    local f="$1"
    ENV_SRC=""
    [[ ! -f "$f" ]] && {
        echo "Error: $f not found" >&2
        exit 1
    }
    if head -c 16 "$f" 2>/dev/null | grep -qF '$ANSIBLE_VAULT'; then
        local pw="${VAULT_PASSWORD_FILE:-$HOME/.vault_pass_dreamseed}"
        [[ ! -f "$pw" ]] && {
            echo "Error: vault password file not found: $pw" >&2
            exit 1
        }
        [[ -n "${ENV_DECRYPTED_TMP:-}" && -f "${ENV_DECRYPTED_TMP:-}" ]] && rm -f "$ENV_DECRYPTED_TMP"
        local tmp
        tmp=$(mktemp)
        chmod 600 "$tmp"
        ANSIBLE_VAULT_PASSWORD_FILE="$pw" ansible-vault view "$f" >"$tmp" 2>/dev/null || {
            echo "Error: vault decrypt failed" >&2
            exit 1
        }
        [[ -s "$tmp" ]] || {
            echo "Error: vault decrypted file is empty" >&2
            exit 1
        }
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
        # ssh_public_key_path for aws_key_pair.deploy — passed via TF_VAR_ instead
        # of deploy.auto.tfvars to avoid shared-file race between workspaces.
        # /dev/null fallback for destroy (file() is evaluated at plan time even
        # for destroy; /dev/null returns empty content, safe for resource deletion).
        export TF_VAR_ssh_public_key_path="${SSH_PUBLIC_KEY_PATH:-/dev/null}"
        # Build list of additional SSH keys from ADDITIONAL_SSH_KEYS env var
        local ssh_keys
        ssh_keys="$(
            local arr=()
            while IFS= read -r k; do [[ -n "${k// /}" ]] && arr+=("$k"); done <<<"${ADDITIONAL_SSH_KEYS:-}"
            if [[ ${#arr[@]} -gt 0 ]]; then
                printf '%s\n' "${arr[@]}" | jq -R . | jq -s .
            else
                jq -n '[]'
            fi
        )" || {
            echo "Failed to build SSH keys list" >&2
            exit 1
        }
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
                done <<<"$additional"
            fi
            if [[ ${#arr[@]} -gt 0 ]]; then
                printf '%s\n' "${arr[@]}" | jq -R . | jq -s .
            else
                jq -n '[]'
            fi
        )" || {
            echo "Failed to build SSH keys list" >&2
            exit 1
        }
        export TF_VAR_additional_ssh_keys="$ssh_keys"
        # Also export ssh_public_key for TF to create CI key if needed
        # NOTE: TF_VAR_additional_ssh_keys is already set above (includes deploy key + ADDITIONAL_SSH_KEYS)
        if [[ -n "${SSH_PUBLIC_KEY_PATH:-}" ]]; then
            local pk
            pk="${SSH_PUBLIC_KEY_PATH/#\~/$HOME}"
            if [[ -r "$pk" ]]; then
                local pk_content
                pk_content="$(<"$pk")"
                export TF_VAR_ssh_public_key="$pk_content"
            fi
        fi
    }
    export TF_VAR_environment="$TARGET"
    export TF_TOKEN_app_terraform_io="${TF_API_TOKEN:-}"
}
