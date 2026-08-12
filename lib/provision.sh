# Terraform provisioning for deploy.sh
# shellcheck shell=bash
# Sourced by deploy.sh — do not execute directly.

run_terraform() {
    if [[ "$SKIP_TERRAFORM" == "false" ]]; then
        step_start "Terraform init + apply ($TARGET)"
        export_tf_env

        terraform_init_if_needed || { echo "Terraform init failed"; tail -30 "$DEPLOY_TF_LOG"; step_fail "Terraform init failed"; }
        terraform_select_workspace || step_fail "Failed to select workspace: $TF_WORKSPACE"
        _tf validate -no-color >> "$DEPLOY_TF_LOG" 2>&1 || step_fail "Terraform config invalid"

        TF_VARS_FILE="${TF_DIR}/deploy.auto.tfvars"
        {
            printf 'environment = "%s"\n' "$TARGET"
            [[ "$TF_PROVIDER" == "aws" ]] && printf 'ssh_public_key_path = "%s"\n' "${SSH_PUBLIC_KEY_PATH:-/dev/null}"
        } > "$TF_VARS_FILE"

        local bk="$SCRIPT_DIR/secrets/tfstate-backup"
        mkdir -p "$bk"
        if _tf state pull > "$bk/${TF_WORKSPACE}_pre.tfstate" 2>/dev/null && [[ -s "$bk/${TF_WORKSPACE}_pre.tfstate" ]]; then
            chmod 600 "$bk/${TF_WORKSPACE}_pre.tfstate"
            echo "  ✓ Pre-apply state backed up"
        else
            rm -f "$bk/${TF_WORKSPACE}_pre.tfstate" 2>/dev/null
        fi

        if _tf apply -auto-approve -no-color >> "$DEPLOY_TF_LOG" 2>&1; then
            :
        else
            tail -30 "$DEPLOY_TF_LOG"
            if [[ -f "$bk/${TF_WORKSPACE}_pre.tfstate" ]]; then
                echo "  ⚠ Apply failed. Rollback with:"
                echo "    cd ${TF_DIR} && ${TERRAFORM} state push ${bk}/${TF_WORKSPACE}_pre.tfstate -force"
            fi
            step_fail "Terraform apply failed"
        fi

        SERVER_IP=$(_tf output -raw server_ipv4 2>>"$DEPLOY_TF_LOG") || step_fail "Could not get server IP"
        [[ -z "$SERVER_IP" ]] && step_fail "Empty IP from Terraform"
        [[ "$SERVER_IP" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || step_fail "Invalid IP from Terraform: $SERVER_IP"
        export SERVER_IP

        local TF_STATE_BACKUP_TMP
        TF_STATE_BACKUP_TMP=$(mktemp); chmod 600 "$TF_STATE_BACKUP_TMP"
        if _tf state pull > "$TF_STATE_BACKUP_TMP" 2>/dev/null && [[ -s "$TF_STATE_BACKUP_TMP" ]]; then
            mv "$TF_STATE_BACKUP_TMP" "$bk/${TF_WORKSPACE}_$(date +%Y%m%d_%H%M%S).tfstate"
            TF_STATE_BACKUP_TMP=
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
