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

# Syntax-check a playbook with the same config as a real run. check mode
# previously invoked ansible-playbook WITHOUT ANSIBLE_CONFIG/ROLES_PATH, so
# every playbook failed with "role not found" and `deploy.sh -c` was broken.
_ansible_syntax() {
    ANSIBLE_CONFIG="$SCRIPT_DIR/ansible/ansible.cfg" \
        ANSIBLE_ROLES_PATH="$SCRIPT_DIR/ansible-roles" \
        ANSIBLE_NOCOLOR=1 \
        "$ANSIBLE_PLAYBOOK" --syntax-check "$SCRIPT_DIR/ansible/$1"
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
    local phase="$1"
    shift
    [[ "$TTY" == "false" ]] && echo "::group::${phase}"
    echo "    ▶ ${phase}"
    local pids=() ok=true
    for entry in "$@"; do
        local pb="${entry%%:*}" label="${entry##*:}"
        local fallback=false
        [[ "$pb" == "~"* ]] && { fallback=true; pb="${pb#\~}"; }
        echo "      ├ ${label}"
        if [[ "$fallback" == "true" ]]; then
            ( _ansible_cmd "$pb" || {
                echo "  ⚠ ${label} failed — continuing (fallback, non-fatal)"
                echo "  ⚠ GRAFANA_FALLBACK_FAILED=true"
              } ) &
        else
            (_ansible_cmd "$pb") &
        fi
        pids+=("$!")
    done
    for pid in "${pids[@]}"; do
        if ! wait "$pid"; then
            ok=false
            # A sibling playbook failed: kill the remaining background runners so
            # an orphaned ansible-playbook doesn't keep mutating the server after
            # the deploy aborts. $other is a SUBSHELL pid — kill its children
            # (ansible-playbook | tee) first, then the subshell itself.
            for other in "${pids[@]}"; do
                [[ "$other" == "$pid" ]] && continue
                pkill -P "$other" 2>/dev/null || true
                kill "$other" 2>/dev/null || true
            done
        fi
    done
    [[ "$TTY" == "false" ]] && echo "::endgroup::"
    [[ "$ok" == "true" ]]
}

resolve_scripts_dir_remote() {
    local dir
    dir=$(
        python3 - "$SCRIPT_DIR/ansible/group_vars/all.yml" <<'PYEOF' 2>/dev/null
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
    # Clear the deploy-in-progress marker (written by playbook-01) so this
    # final authoritative check runs and the 5-min timer resumes immediately.
    # sudo: playbook-01 creates the marker as root in sticky /tmp, so an
    # unprivileged rm would fail with EPERM (silently swallowed below) and the
    # final check would skip with a false-green "All checks passed".
    ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 \
        -o LogLevel=ERROR \
        -i "$SSH_KEY" "ubuntu@$SERVER_IP" \
        "sudo rm -f /tmp/.dreamseed_deploying" 2>/dev/null || true
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
        # The script's own verdict line (✅/❌) is already in $output — don't
        # append a blanket "All checks passed": TIER-2 failures exit 0 with a
        # "Critical checks passed (warnings above)" verdict, and the extra line
        # made that look like a full pass.
        :
    else
        step_fail "Some checks failed (see above)"
    fi
}
