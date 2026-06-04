# Terraform operations for deploy.sh
# shellcheck shell=bash
# Sourced by deploy.sh — do not execute directly.

# Terraform shortcut — runs tf in the correct provider dir
_tf() { ( cd "$TF_DIR" && "$TERRAFORM" "$@" ); }

# Clean up stale CI SSH key from Hetzner Cloud before terraform apply
# to avoid "SSH key not unique (uniqueness_error)"
cleanup_stale_ssh_key() {
    [[ "$TF_PROVIDER" != "hetzner" || -z "${HCLOUD_TOKEN:-}" || -n "${HETZNER_SSH_KEY_NAME:-}" ]] && return 0
    local key_name="dreamseed-ci-${TF_WORKSPACE}"
    echo "    Cleaning stale SSH key: ${key_name}"
    local key_id
    key_id=$(curl -sf -H "Authorization: Bearer $HCLOUD_TOKEN" \
        "https://api.hetzner.cloud/v1/ssh_keys?name=${key_name}" 2>/dev/null \
        | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['ssh_keys'][0]['id'] if d.get('ssh_keys') else '')" 2>/dev/null || true)
    if [[ -n "$key_id" ]]; then
        curl -sf -X DELETE -H "Authorization: Bearer $HCLOUD_TOKEN" \
            "https://api.hetzner.cloud/v1/ssh_keys/${key_id}" >/dev/null 2>&1 && \
            echo "    Deleted stale key ${key_name} (ID: ${key_id})" || \
            echo "    Warning: could not delete key ${key_name}"
    else
        echo "    No stale key found"
    fi
}

terraform_select_workspace() {
    local ws="$TF_WORKSPACE"
    (
        unset TF_WORKSPACE
        _tf workspace select "$ws" 2>/dev/null || \
        _tf workspace new "$ws"
    )
}

terraform_init_if_needed() {
    local ws
    ws=$(cat "$TF_DIR/.terraform/environment" 2>/dev/null || echo "")
    if [[ ! -d "$TF_DIR/.terraform" ]] || [[ "$ws" != "$TF_WORKSPACE" ]]; then
        TF_WORKSPACE="$TF_WORKSPACE" _tf init -reconfigure -input=false -no-color >> "$DEPLOY_TF_LOG" 2>&1
    fi
}

terraform_destroy() {
    if [[ "$TTY" == "false" ]]; then
        [[ "${CI_DESTROY_CONFIRM:-}" == "yes" ]] || { echo "Error: CI destroy requires CI_DESTROY_CONFIRM=yes"; exit 1; }
    elif [[ "$TARGET" == "prod" ]]; then
        echo ""
        echo "  ⚠  PRODUCTION DESTROY REQUESTED  ⚠"
        echo "  This will PERMANENTLY DELETE: dreamseed.online"
        echo ""
        read -rp "  Step 1/3 — Do you REALLY want to destroy PROD? [y/N] " a1
        [[ ! "${a1:-}" =~ ^[Yy]$ ]] && { echo "Aborted."; exit 0; }
        read -rp "  Step 2/3 — Are you absolutely sure? [y/N] " a2
        [[ ! "${a2:-}" =~ ^[Yy]$ ]] && { echo "Aborted."; exit 0; }
        echo "  Step 3/3 — Type 'destroy prod' to confirm: "
        read -rp "  > " a3
        [[ "$a3" != "destroy prod" ]] && { echo "Aborted."; exit 0; }
    else
        read -rp "  Destroy $TARGET? [y/N] " a
        [[ ! "${a:-}" =~ ^[Yy]$ ]] && { echo "Aborted."; exit 0; }
    fi

    export_tf_env

    # Check server reachability
    local ip; ip=$(_tf output -raw server_ipv4 2>/dev/null || true)
    [[ -n "$ip" && -n "${SSH_KEY:-}" ]] && \
        ssh -o ConnectTimeout=5 -o BatchMode=yes -i "$SSH_KEY" "ubuntu@$ip" 'true' 2>/dev/null \
            && echo "  ✓ Server $ip reachable" \
            || echo "  ⚠ Server $ip unreachable — destroying anyway"

    terraform_init_if_needed || { echo "Terraform init failed"; cat "$DEPLOY_TF_LOG"; return 1; }
    terraform_select_workspace >> "$DEPLOY_TF_LOG" 2>&1 || step_fail "Failed to select Terraform workspace: $TF_WORKSPACE"

    _tf show -no-color 2>/dev/null | grep -q "No state" && { echo "  No resources to destroy"; return 0; }

    local var_arg=""
    [[ "$TF_PROVIDER" == "aws" ]] && var_arg="-var=ssh_public_key_path=${SSH_PUBLIC_KEY_PATH:-/dev/null}"

    if [[ "$TF_PROVIDER" == "aws" ]] && [[ "$TARGET" == "prod" ]]; then
        echo "  ⚠ Removing termination protection..."
        local instance_id
        instance_id=$(_tf output -raw instance_id 2>/dev/null || true)
        if [[ -n "$instance_id" ]]; then
            aws ec2 modify-instance-attribute --instance-id "$instance_id" --no-disable-api-termination >/dev/null 2>&1 || true
        fi
    fi

    echo "  ━━━ Destroying resources ($TARGET)"

    TF_TMP_OUT=$(mktemp)
    # shellcheck disable=SC2086
    _tf destroy -auto-approve -no-color $var_arg 2>&1 | tee -a "$TF_TMP_OUT" || true
    grep -q "Destroy complete" "$TF_TMP_OUT" || step_fail "Terraform destroy failed (check $DEPLOY_TF_LOG)"
    cat "$TF_TMP_OUT" >> "$DEPLOY_TF_LOG"; rm -f "$TF_TMP_OUT"

    rm -f "$SCRIPT_DIR/secrets/tfstate-backup/${TF_WORKSPACE}"_*.tfstate 2>/dev/null

    if [[ "$TARGET" != "prod" ]]; then
        local ws_del="$TF_WORKSPACE"
        ( cd "$TF_DIR" && unset TF_WORKSPACE && \
          "$TERRAFORM" workspace delete "$ws_del" 2>&1 ) >> "$DEPLOY_TF_LOG" 2>&1 || true
    fi
    echo "  ✓ Destroyed"
}
