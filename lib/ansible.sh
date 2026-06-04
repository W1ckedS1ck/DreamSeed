# Ansible execution helpers for deploy.sh
# shellcheck shell=bash
# Sourced by deploy.sh — do not execute directly.

_ansible_cmd() {
    local rc
    ANSIBLE_CONFIG="$SCRIPT_DIR/ansible/ansible.cfg" \
    ANSIBLE_ROLES_PATH="$SCRIPT_DIR/ansible-roles" \
    ANSIBLE_FORCE_COLOR=0 ANSIBLE_NOCOLOR=1 \
    "$ANSIBLE_PLAYBOOK" -i "$INVENTORY_FILE" --extra-vars "@${VAULT_TMP}" \
        "$SCRIPT_DIR/ansible/$1" 2>&1 | tee -a "$LOG"
    return "${PIPESTATUS[0]}"
}

run_ansible() {
    local pb="$1" label="$2"
    [[ "$TTY" == "false" ]] && echo "::group::${label}"
    echo "    ▶ ${label}"
    _ansible_cmd "$pb"
    local rc=$?
    [[ "$TTY" == "false" ]] && echo "::endgroup::"
    return "$rc"
}

run_parallel() {
    local phase="$1"; shift
    [[ "$TTY" == "false" ]] && echo "::group::${phase}"
    echo "    ▶ ${phase}"
    local pids=() ok=true
    for entry in "$@"; do
        local pb="${entry%%:*}" label="${entry##*:}"
        echo "      ├ ${label}"
        ( _ansible_cmd "$pb" ) &
        pids+=("$!")
    done
    for pid in "${pids[@]}"; do wait "$pid" || ok=false; done
    [[ "$TTY" == "false" ]] && echo "::endgroup::"
    $ok
}

check_services() {
    echo ""
    echo "  ▸ Post-deploy checks"

    local scripts_dir_remote
    scripts_dir_remote=$(python3 -c "import yaml,sys; d=yaml.safe_load(open('$SCRIPT_DIR/ansible/group_vars/all.yml')); print(d.get('scripts_dir_remote', ''))" 2>/dev/null)
    scripts_dir_remote="${scripts_dir_remote:-/home/ubuntu/Scripts}"

    local output
    output=$(ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 \
        -i "$SSH_KEY" "ubuntu@$SERVER_IP" \
        "bash ${scripts_dir_remote}/check_services.sh" 2>&1)
    local rc=$?

    echo "$output"

    if [[ "$rc" -eq 0 ]]; then
        echo "    All checks passed"
    else
        step_fail "Some checks failed (see above)"
    fi
}
