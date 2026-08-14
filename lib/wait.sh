# Server wait logic for deploy.sh
# shellcheck shell=bash
# Sourced by deploy.sh — do not execute directly.

wait_for_server() {
    # ----- Clear stale host key (prevents mismatch on IP reuse) -----
    # TOFU security note (audit 2026-08): host key is pinned into known_hosts
    # right here via ssh-keyscan on first contact, and every later SSH
    # (Ansible, check_services, post.sh) verifies against it. accept-new below
    # only applies to this very first probe. Deliberately NOT pinned to
    # pre-known host keys: servers are ephemeral (IP + key rotate on rebuild),
    # and MITM on a just-created Hetzner/AWS IP is not a realistic threat.
    ssh-keygen -R "$SERVER_IP" > /dev/null 2>&1 || true
    ssh-keyscan -H "$SERVER_IP" >> ~/.ssh/known_hosts 2>/dev/null || true

    # ----- Wait for SSH -----
    step_start "Wait for SSH ($SERVER_IP)"
    local ssh_err="" attempt=0
    for ((attempt=1; attempt<=SSH_ATTEMPTS; attempt++)); do
        ssh_err=$(ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 \
            -o BatchMode=yes -o PasswordAuthentication=no \
            -i "$SSH_KEY" "ubuntu@$SERVER_IP" 'true' 2>&1) && break
        if [[ $((attempt % 10)) -eq 1 ]] || { [[ "$ssh_err" == *"Permission denied"* ]] && [[ $attempt -eq 1 ]]; }; then
            local err_line
            err_line=$(echo "$ssh_err" | grep -iE '(Permission denied|Connection refused|Connection timed out|Could not resolve|Host key verification)' | head -1)
            if [[ -n "$err_line" ]]; then
                echo -e "\n  ⚠ $err_line"
                [[ "$err_line" == *"Permission denied"* ]] && {
                    echo "  🛠 Key: $(ssh-keygen -lf "$SSH_KEY" 2>/dev/null | awk '{print $2}')"
                    echo "  🛠 User: ubuntu@$SERVER_IP"
                    echo "  🛠 Check: server's authorized_keys for ubuntu user"
                }
            fi
        fi
        printf "."; sleep "$SSH_INTERVAL"
    done
    echo ""
    [[ $attempt -gt $SSH_ATTEMPTS ]] && step_fail "SSH not ready after $((SSH_ATTEMPTS * SSH_INTERVAL))s — $(echo "$ssh_err" | head -1)"
    step_ok

    # ----- Wait for cloud-init -----
    step_start "Wait for cloud-init"
    ssh -i "$SSH_KEY" "ubuntu@$SERVER_IP" "timeout 300 cloud-init status --wait" >/dev/null 2>/dev/null || {
        for ((i=1; i<=CLOUDINIT_ATTEMPTS; i++)); do
            local st
            st=$(ssh -i "$SSH_KEY" "ubuntu@$SERVER_IP" 'cloud-init status 2>/dev/null || echo unknown' 2>/dev/null || echo unknown)
            [[ "$st" == *"status: done"* || "$st" == *"No pending"* ]] && break
            [[ "$st" == *"status: error"* ]] && step_fail "Cloud-init failed (check /var/log/cloud-init-output.log)"
            [[ $i -eq $CLOUDINIT_ATTEMPTS ]] && step_fail "Cloud-init timeout"
            printf "."; sleep "$CLOUDINIT_INTERVAL"
        done
    }
    echo ""; step_ok

    # ----- Wait for apt lock -----
    step_start "Wait for apt lock"
    ssh -i "$SSH_KEY" "ubuntu@$SERVER_IP" \
        "while sudo fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do sleep 2; done" 2>/dev/null || true
    step_ok
}
