# Terraform operations for deploy.sh
# shellcheck shell=bash
# Sourced by deploy.sh — do not execute directly.

# Terraform shortcut — runs tf in the correct provider dir
_tf() { ( cd "$TF_DIR" && "$TERRAFORM" "$@" ); }

# Clean up stale CI SSH key from Hetzner Cloud before terraform apply
# to avoid "SSH key not unique (uniqueness_error)"
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
    local org="DreamSeed" prefix="dreamseed-" ws_name="$prefix$TF_WORKSPACE"
    local auth="Authorization: Bearer $TF_API_TOKEN" api="https://app.terraform.io/api/v2"

    # Fetch or create workspace, extract ID
    local ws_id
    ws_id=$(curl -sf -H "$auth" "$api/organizations/$org/workspaces/$ws_name" | \
        python3 -c "import json,sys; print(json.load(sys.stdin).get('data',{}).get('id',''))" 2>/dev/null || echo "")
    if [[ -z "$ws_id" ]]; then
        echo "  Creating TFC workspace: $ws_name"
        ws_id=$(curl -sf -X POST "$api/organizations/$org/workspaces" \
            -H "$auth" -H "Content-Type: application/vnd.api+json" \
            -d "{\"data\":{\"type\":\"workspaces\",\"attributes\":{\"name\":\"$ws_name\"}}}" | \
            python3 -c "import json,sys; print(json.load(sys.stdin).get('data',{}).get('id',''))" 2>/dev/null || echo "")
    fi
    [[ -z "$ws_id" ]] && return 0

    # Ensure required terraform variables exist in the workspace
    local vars_json
    vars_json=$(curl -sf -H "$auth" "$api/workspaces/$ws_id/vars" | python3 -c "
import json,sys
d=json.load(sys.stdin)
for v in d.get('data',[]):
    print(f\"{v['attributes']['key']}={v['attributes']['value']}\")
" 2>/dev/null || echo "")

    local set_var
    set_var() {
        local key="$1" value="$2" cat="${3:-terraform}" hcl="${4:-false}" sens="${5:-false}"
        if ! echo "$vars_json" | grep -q "^$key="; then
            curl -sf -X POST "$api/workspaces/$ws_id/vars" \
                -H "$auth" -H "Content-Type: application/vnd.api+json" \
                -d "{\"data\":{\"type\":\"vars\",\"attributes\":{\"key\":\"$key\",\"value\":\"$value\",\"category\":\"$cat\",\"hcl\":$hcl,\"sensitive\":$sens}}}" >/dev/null 2>&1
        fi
    }

    set_var "hcloud_token" "${HCLOUD_TOKEN:-}" "terraform" "false" "true"
    set_var "environment" "${TARGET:-prod-hetz}"
    set_var "ssh_public_key" "${TF_VAR_ssh_public_key:-}" "terraform" "false" "true"
    set_var "additional_ssh_keys" "${TF_VAR_additional_ssh_keys:-[]}" "terraform" "true" "false"
    [[ -n "${HETZNER_SERVER_TYPE:-}" ]] && set_var "server_type" "$HETZNER_SERVER_TYPE"
    [[ -n "${HETZNER_LOCATION:-}" ]] && set_var "location" "$HETZNER_LOCATION"
    [[ -n "${HETZNER_SSH_KEY_NAME:-}" ]] && set_var "ssh_key_name" "$HETZNER_SSH_KEY_NAME"
    [[ -n "${HETZNER_PRIMARY_IP_NAME:-}" ]] && set_var "primary_ip_name" "$HETZNER_PRIMARY_IP_NAME"
    [[ -n "${HETZNER_ENABLE_PRIMARY_IP:-}" ]] && set_var "enable_primary_ip" "$HETZNER_ENABLE_PRIMARY_IP"
}

terraform_init_if_needed() {
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
    set +e
    _tf destroy -auto-approve -no-color $var_arg 2>&1 | tee -a "$TF_TMP_OUT"
    local tf_exit=${PIPESTATUS[0]}
    set -e
    if [[ $tf_exit -ne 0 ]]; then
        echo "  ⚠ terraform destroy exited with code $tf_exit (ignored — TFC remote backend exit 1 bug)"
    fi
    grep -q "Destroy complete" "$TF_TMP_OUT" || step_fail "Terraform destroy failed (check $DEPLOY_TF_LOG)"
    cat "$TF_TMP_OUT" >> "$DEPLOY_TF_LOG" && rm -f "$TF_TMP_OUT"

    rm -f "$SCRIPT_DIR/secrets/tfstate-backup/${TF_WORKSPACE}"_*.tfstate 2>/dev/null

    if [[ "$TARGET" != "prod" ]]; then
        local ws_del="$TF_WORKSPACE"
        ( cd "$TF_DIR" && unset TF_WORKSPACE && \
          "$TERRAFORM" workspace delete "$ws_del" 2>&1 ) >> "$DEPLOY_TF_LOG" 2>&1 || true
    fi
    echo "  ✓ Destroyed"
}
