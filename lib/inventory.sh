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

    # Per-target fact cache: every inventory uses the same hostname
    # ("dreamseed"), so a shared jsonfile cache would bleed facts between
    # environments for up to fact_caching_timeout (30 min) — e.g. RAM-derived
    # FPM/innodb sizes or a cached php_version from the other machine.
    export ANSIBLE_CACHE_PLUGIN_CONNECTION="${HOME}/.ansible/facts_cache/${TF_WORKSPACE}"
    mkdir -p "$ANSIBLE_CACHE_PLUGIN_CONNECTION"
    # Old flat layout left hostname-named JSON at the cache root (the cross-env
    # bleed source) — remove now that caches live in per-workspace subdirs.
    find "${HOME}/.ansible/facts_cache" -maxdepth 1 -type f -name '*.json' -delete 2>/dev/null || true
}
