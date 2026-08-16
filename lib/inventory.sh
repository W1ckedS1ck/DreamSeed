# Inventory generation for deploy.sh
# shellcheck shell=bash
# Sourced by deploy.sh — do not execute directly.

generate_inventory() {
    mkdir -p "$SCRIPT_DIR/ansible/inventory"
    INVENTORY_FILE="$SCRIPT_DIR/ansible/inventory/hosts-${TF_WORKSPACE}.yml"
    cat >"$INVENTORY_FILE" <<INVEOF
all:
  hosts:
    dreamseed:
      ansible_host: "${SERVER_IP}"
      ansible_user: ubuntu
      ansible_ssh_private_key_file: "${SSH_KEY}"
      ansible_ssh_common_args: "-o StrictHostKeyChecking=accept-new"
      server_ip: "${SERVER_IP}"
INVEOF
    chmod 600 "$INVENTORY_FILE"

    DEPLOY_VARS_TMP=$(mktemp -d)
    chmod 700 "$DEPLOY_VARS_TMP"
    DEPLOY_VARS_FILE="$DEPLOY_VARS_TMP/vars.json"
    python3 "$SCRIPT_DIR/lib/gen_vars.py" "$TARGET" "$SCRIPT_DIR" "$DEPLOY_VARS_FILE" || step_fail "gen_vars.py failed"
    [[ -f "$DEPLOY_VARS_FILE" ]] || step_fail "gen_vars.py did not produce $DEPLOY_VARS_FILE"

    # Strip Better Stack keys for non-prod (prevents env leakage to Ansible/SSH child processes)
    if [[ ! "$TARGET" =~ ^prod ]]; then
        for v in "${!BETTERUPTIME_@}"; do unset "$v"; done
    fi

    mkdir -p ~/.ansible/facts_cache
}
