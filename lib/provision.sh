# Terraform provisioning for deploy.sh
# shellcheck shell=bash
# Sourced by deploy.sh — do not execute directly.

# Encrypt a tfstate backup with ansible-vault (state contains secrets: user_data,
# keys, IPs). Plaintext fallback with warning if vault is unavailable.
_vault_encrypt_backup() {
    local f="$1"
    local pw="${VAULT_PASSWORD_FILE:-$HOME/.vault_pass_dreamseed}"
    if ansible-vault encrypt "$f" --vault-password-file "$pw" >/dev/null 2>&1; then
        return 0
    fi
    echo "  ⚠ Vault encrypt failed — backup left plaintext: $f" | tee -a "$LOG"
    return 1
}

run_terraform() {
    if [[ "$SKIP_TERRAFORM" == "false" ]]; then
        step_start "Terraform init + apply ($TARGET)"
        export_tf_env

        terraform_init_if_needed || {
            echo "Terraform init failed"
            tail -30 "$DEPLOY_TF_LOG"
            step_fail "Terraform init failed"
        }
        terraform_select_workspace || step_fail "Failed to select workspace: $TF_WORKSPACE"
        _tf validate -no-color >>"$DEPLOY_TF_LOG" 2>&1 || step_fail "Terraform config invalid"

        local bk="$SCRIPT_DIR/secrets/tfstate-backup"
        mkdir -p "$bk"
        if _tf state pull >"$bk/${TF_WORKSPACE}_pre.tfstate" 2>/dev/null && [[ -s "$bk/${TF_WORKSPACE}_pre.tfstate" ]]; then
            chmod 600 "$bk/${TF_WORKSPACE}_pre.tfstate"
            if _vault_encrypt_backup "$bk/${TF_WORKSPACE}_pre.tfstate"; then
                echo "  ✓ Pre-apply state backed up (encrypted)"
            fi
        else
            rm -f "$bk/${TF_WORKSPACE}_pre.tfstate" 2>/dev/null
        fi

        if _tf apply -auto-approve -no-color >>"$DEPLOY_TF_LOG" 2>&1; then
            :
        else
            tail -30 "$DEPLOY_TF_LOG"
            if [[ -f "$bk/${TF_WORKSPACE}_pre.tfstate" ]]; then
                echo "  ⚠ Apply failed. Rollback with:"
                echo "    cd ${TF_DIR} && ansible-vault decrypt ${bk}/${TF_WORKSPACE}_pre.tfstate --output - --vault-password-file ~/.vault_pass_dreamseed | ${TERRAFORM} state push - -force"
            fi
            step_fail "Terraform apply failed"
        fi

        SERVER_IP=$(_tf output -raw server_ipv4 2>>"$DEPLOY_TF_LOG") || step_fail "Could not get server IP"
        [[ -z "$SERVER_IP" ]] && step_fail "Empty IP from Terraform"
        [[ "$SERVER_IP" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || step_fail "Invalid IP from Terraform: $SERVER_IP"
        export SERVER_IP

        declare -g TF_STATE_BACKUP_TMP
        TF_STATE_BACKUP_TMP=$(mktemp)
        chmod 600 "$TF_STATE_BACKUP_TMP"
        if _tf state pull >"$TF_STATE_BACKUP_TMP" 2>/dev/null && [[ -s "$TF_STATE_BACKUP_TMP" ]]; then
            local post_backup
            post_backup="$bk/${TF_WORKSPACE}_$(date +%Y%m%d_%H%M%S).tfstate"
            mv "$TF_STATE_BACKUP_TMP" "$post_backup"
            TF_STATE_BACKUP_TMP=
            _vault_encrypt_backup "$post_backup" >/dev/null || true
            ls -1t "$bk"/${TF_WORKSPACE}_[0-9]*.tfstate 2>/dev/null | tail -n +6 | xargs rm -f 2>/dev/null || true
        else
            rm -f "$TF_STATE_BACKUP_TMP"
            TF_STATE_BACKUP_TMP=
            echo "  ⚠ Post-apply state backup failed (empty or error)" | tee -a "$LOG"
        fi
        step_ok
    else
        step_start "Using existing server"
        SERVER_IP="$EXISTING_IP"
        [[ "$SERVER_IP" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || step_fail "Invalid IP passed to -i: $SERVER_IP"
        export SERVER_IP
        step_ok
    fi
}
