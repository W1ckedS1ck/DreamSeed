# Ansible execution helpers for deploy.sh
# shellcheck shell=bash
# Sourced by deploy.sh — do not execute directly.

_ansible_cmd() {
    # Line buffering handled by stdbuf -oL at the pipeline level (deploy.yml).
    # let the pipeline fail so its exit code can be captured — deploy.sh enables `set -e`.
    set +e
    ANSIBLE_CONFIG="$SCRIPT_DIR/ansible/ansible.cfg" \
    ANSIBLE_ROLES_PATH="$SCRIPT_DIR/ansible-roles" \
    ANSIBLE_NOCOLOR=1 \
    "$ANSIBLE_PLAYBOOK" -i "$INVENTORY_FILE" --extra-vars "@${DEPLOY_VARS_FILE}" \
        "$SCRIPT_DIR/ansible/$1" 2>&1 | tee -a "$LOG"
    local rc=${PIPESTATUS[0]}
    set -e
    return "$rc"
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
    for pid in "${pids[@]}"; do
        if ! wait "$pid"; then
            ok=false
            # A sibling playbook failed: kill and reap the remaining
            # background runners so an orphaned ansible-playbook doesn't
            # keep mutating the server after the deploy aborts.
            for other in "${pids[@]}"; do
                [[ "$other" == "$pid" ]] && continue
                kill "$other" 2>/dev/null || true
            done
        fi
    done
    [[ "$TTY" == "false" ]] && echo "::endgroup::"
    [[ "$ok" == "true" ]]
}

resolve_scripts_dir_remote() {
    local dir
    dir=$(python3 - "$SCRIPT_DIR/ansible/group_vars/all.yml" <<'PYEOF' 2>/dev/null
import yaml, sys
d = yaml.safe_load(open(sys.argv[1]))
print(d.get('scripts_dir_remote', '/home/ubuntu/Scripts'))
PYEOF
)
    dir="${dir:-/home/ubuntu/Scripts}"
    # Validate path is safe before passing to SSH remote command
    if [[ ! "$dir" =~ ^/[A-Za-z0-9/_-]+$ ]]; then
        echo "  ⚠ scripts_dir_remote has unexpected chars, using default" >&2
        dir="/home/ubuntu/Scripts"
    fi
    printf '%s' "$dir"
}

resolve_scripts_dir_remote() {
    local dir
    dir=$(python3 - "$SCRIPT_DIR/ansible/group_vars/all.yml" <<'PYEOF' 2>/dev/null
import yaml, sys
d = yaml.safe_load(open(sys.argv[1]))
print(d.get('scripts_dir_remote', '/home/ubuntu/Scripts'))
PYEOF
)
    dir="${dir:-/home/ubuntu/Scripts}"
    # Validate path is safe before passing to SSH remote command
    if [[ ! "$dir" =~ ^/[A-Za-z0-9/_-]+$ ]]; then
        echo "  ⚠ scripts_dir_remote has unexpected chars, using default" >&2
        dir="/home/ubuntu/Scripts"
    fi
    printf '%s' "$dir"
}

check_services() {
    echo ""
    echo "  ▸ Post-deploy checks"

    local scripts_dir_remote
    scripts_dir_remote="$(resolve_scripts_dir_remote)"

    local output rc
    [[ -n "${DEBUG:-}" ]] && echo "    [DEBUG] SSH to ubuntu@$SERVER_IP — running check_services.sh..."
    set +e
    output=$(ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 \
        -o LogLevel=ERROR \
        -i "$SSH_KEY" "ubuntu@$SERVER_IP" \
        "bash '${scripts_dir_remote}/check_services.sh'" 2>&1)
    rc=$?
    set -e
    [[ -n "${DEBUG:-}" ]] && echo "    [DEBUG] SSH exit code: $rc"

    echo "$output"

    if [[ "$rc" -eq 0 ]]; then
        echo "    All checks passed"
    else
        step_fail "Some checks failed (see above)"
    fi
}
