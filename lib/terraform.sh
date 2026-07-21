# Terraform operations for deploy.sh
# shellcheck shell=bash
# Sourced by deploy.sh — do not execute directly.

# Terraform shortcut — runs tf in the correct provider dir
_tf() { ( cd "$TF_DIR" && "$TERRAFORM" "$@" ); }

terraform_select_workspace() {
    local ws="$TF_WORKSPACE"
    (
        unset TF_WORKSPACE
        _tf workspace select "$ws" 2>/dev/null || \
        _tf workspace new "$ws"
    )
}

terraform_ensure_workspace() {
    [[ -z "${TF_API_TOKEN:-}" || -z "${TF_WORKSPACE:-}" ]] && return 0
    local org="DreamSeed" ws_name="dreamseed-${TF_WORKSPACE}"
    local auth="Authorization: Bearer $TF_API_TOKEN"
    local url="https://app.terraform.io/api/v2/organizations/$org/workspaces/$ws_name"
    if ! curl -sf -H "$auth" "$url" >/dev/null 2>&1; then
        echo "  Creating TFC workspace: $ws_name"
        curl -sf -X POST "https://app.terraform.io/api/v2/organizations/$org/workspaces" \
            -H "$auth" -H "Content-Type: application/vnd.api+json" \
            -d "{\"data\":{\"type\":\"workspaces\",\"attributes\":{\"name\":\"$ws_name\",\"execution-mode\":\"local\"}}}" >/dev/null 2>&1 && echo "  ✓ Workspace created" || echo "  ⚠ Failed to create workspace (will try 'terraform workspace new')"
    fi
}

terraform_init_if_needed() {
    if [[ -z "${TF_API_TOKEN:-}" ]]; then
        echo "  ✗ TF_API_TOKEN not set — required for Terraform Cloud remote backend"
        echo "    Set it in secrets/.env or export TF_API_TOKEN=..."
        return 1
    fi
    # Ensure TFC workspace exists before init (first deploy creates workspace via API)
    terraform_ensure_workspace
    local ws
    ws=$(_tf workspace show 2>/dev/null || echo "")
    if [[ ! -d "$TF_DIR/.terraform" ]] || [[ "$ws" != "$TF_WORKSPACE" ]]; then
        TF_WORKSPACE="$TF_WORKSPACE" _tf init -reconfigure -input=false -no-color >> "$DEPLOY_TF_LOG" 2>&1
    fi
}

terraform_destroy() {
    if [[ "$TTY" == "false" ]]; then
        [[ "${CI_DESTROY_CONFIRM:-}" == "yes" ]] || { echo "Error: CI destroy requires CI_DESTROY_CONFIRM=yes"; exit 1; }
    elif [[ "$TARGET" =~ ^prod ]]; then
        echo ""
        echo "  ⚠  PRODUCTION DESTROY REQUESTED  ⚠"
        echo "  This will PERMANENTLY DELETE: $DEPLOY_DOMAIN"
        echo ""
        read -rp "  Step 1/3 — Do you REALLY want to destroy $TARGET? [y/N] " a1 < /dev/tty
        [[ ! "${a1:-}" =~ ^[Yy]$ ]] && { echo "Aborted."; exit 0; }
        read -rp "  Step 2/3 — Are you absolutely sure? [y/N] " a2 < /dev/tty
        [[ ! "${a2:-}" =~ ^[Yy]$ ]] && { echo "Aborted."; exit 0; }
        echo "  Step 3/3 — Type 'destroy $TARGET' to confirm: "
        read -rp "  > " a3 < /dev/tty
        [[ "$a3" != "destroy ${TARGET}" ]] && { echo "Aborted."; exit 0; }
    else
        read -rp "  Destroy $TARGET? [y/N] " a < /dev/tty
        [[ ! "${a:-}" =~ ^[Yy]$ ]] && { echo "Aborted."; exit 0; }
    fi

    export_tf_env

    terraform_init_if_needed || { echo "Terraform init failed"; cat "$DEPLOY_TF_LOG"; return 1; }
    terraform_select_workspace >> "$DEPLOY_TF_LOG" 2>&1 || step_fail "Failed to select Terraform workspace: $TF_WORKSPACE"

    # Clean up Cloudflare DNS record regardless of state
    delete_cloudflare_dns "$DEPLOY_DOMAIN"

    _tf show -no-color 2>/dev/null | grep -q "No state" && { echo "  No resources to destroy"; return 0; }

    # TFC remote execution does not support -var flags; use auto.tfvars
    if [[ "$TF_PROVIDER" == "aws" ]] && [[ "${SSH_PUBLIC_KEY_PATH:-}" ]]; then
        TF_VARS_FILE="${TF_DIR}/deploy.auto.tfvars"
        printf 'ssh_public_key_path = "%s"\n' "$SSH_PUBLIC_KEY_PATH" > "$TF_VARS_FILE"
    fi

    if [[ "$TF_PROVIDER" == "aws" ]] && [[ "$TARGET" == "prod" ]]; then
        echo "  ⚠ Removing termination protection..."
        local instance_id
        instance_id=$(_tf output -raw instance_id 2>/dev/null || true)
        if [[ -n "$instance_id" ]]; then
            aws ec2 modify-instance-attribute --instance-id "$instance_id" --no-disable-api-termination >/dev/null 2>&1 || true
        fi
    fi

    # Backup SSL certs (restore on next deploy avoids Let's Encrypt rate limit)
    echo "  ─── Backup SSL certificates..."
    local ssl_backup_ip
    ssl_backup_ip=$(_tf output -raw server_ipv4 2>/dev/null || true)
    if [[ -n "$ssl_backup_ip" ]]; then
        local ssl_dest="$SCRIPT_DIR/secrets/ssl/letsencrypt"
        mkdir -p "$ssl_dest"
        ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
            -i "$SSH_KEY" "ubuntu@$ssl_backup_ip" \
            "sudo tar -czh -C /etc/letsencrypt live/ 2>/dev/null" > "$ssl_dest/certs.tar.gz" 2>/dev/null || true
        if tar -tzf "$ssl_dest/certs.tar.gz" 2>/dev/null | grep -q 'fullchain.pem'; then
            tar -xzf "$ssl_dest/certs.tar.gz" -C "$ssl_dest/" 2>/dev/null || true
            echo "  ✓ SSL certificates backed up"
        else
            echo "  — No Let's Encrypt certs on server"
        fi
        rm -f "$ssl_dest/certs.tar.gz"
    else
        echo "  — No server IP, skipping SSL backup"
    fi

    # Detach Ubuntu Pro before destroying (free token slots back)
    echo "  ─── Detach Ubuntu Pro..."
    local ubuntu_pro_ip
    ubuntu_pro_ip=$(_tf output -raw server_ipv4 2>/dev/null || true)
    if [[ -n "$ubuntu_pro_ip" ]]; then
        ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
            -i "$SSH_KEY" "ubuntu@$ubuntu_pro_ip" \
            "sudo pro detach --assume-yes" 2>/dev/null || true
        echo "  ✓ Ubuntu Pro detached"
    else
        echo "  — No server IP, skipping"
    fi

    echo "  ━━━ Destroying resources ($TARGET)"

    TF_TMP_OUT=$(mktemp /tmp/dreamseed_tf_XXXXXX)
    local old_opts; old_opts=$(set +o)
    _tf destroy -auto-approve -no-color 2>&1 | tee -a "$TF_TMP_OUT"
    local tf_exit=${PIPESTATUS[0]}
    eval "$old_opts"
    if [[ $tf_exit -ne 0 ]]; then
        grep -q "Destroy complete" "$TF_TMP_OUT" || step_fail "Terraform destroy failed (exit $tf_exit, check $DEPLOY_TF_LOG)"
    fi
    cat "$TF_TMP_OUT" >> "$DEPLOY_TF_LOG" && rm -f "$TF_TMP_OUT"

    rm -f "$SCRIPT_DIR/secrets/tfstate-backup/${TF_WORKSPACE}"_*.tfstate 2>/dev/null

    if [[ ! "$TARGET" =~ ^prod ]]; then
        local ws_del="$TF_WORKSPACE"
        ( cd "$TF_DIR" && unset TF_WORKSPACE && \
          "$TERRAFORM" workspace delete "$ws_del" 2>&1 ) >> "$DEPLOY_TF_LOG" 2>&1 || true
    fi
    echo "  ✓ Destroyed"
}
