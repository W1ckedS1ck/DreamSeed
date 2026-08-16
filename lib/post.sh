# Post-deploy operations (DNS, commit marker, summary) for deploy.sh
# shellcheck shell=bash
# Sourced by deploy.sh — do not execute directly.

update_dns() {
    if [[ "$SKIP_DNS" == "false" ]]; then
        step_start "Cloudflare DNS update"
        update_cloudflare_dns "$DEPLOY_DOMAIN" "$SERVER_IP" || step_fail "Cloudflare DNS update failed"
        # Grey-cloud (no proxy) — for direct SSH without Cloudflare (dev only)
        if [[ ! "$TARGET" =~ ^prod ]]; then
            update_cloudflare_dns_direct "ssh.${DEPLOY_DOMAIN}" "$SERVER_IP" ||
                echo "  ⚠ SSH DNS update failed (non-fatal)"
        fi
        step_ok
    else
        echo "  — Cloudflare DNS update skipped (--no-dns)"
    fi
}

record_deploy() {
    if [[ -n "${GITHUB_SHA:-}" && "$DRY_RUN" == "false" ]]; then
        step_start "Record deployed commit"
        # Marker written to record the exact commit deployed, readable via:
        #   ssh dream "cat <scripts_dir_remote>/.deployed_commit"
        local marker_dir
        marker_dir="$(resolve_scripts_dir_remote)"
        if ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 \
            -o LogLevel=ERROR \
            -i "$SSH_KEY" "ubuntu@$SERVER_IP" \
            "printf '%s %s %s\\n' '$GITHUB_SHA' '$DEPLOY_DOMAIN' '$(date -u +%Y-%m-%dT%H:%M:%SZ)' > '${marker_dir}/.deployed_commit'" 2>/dev/null; then
            step_ok
        else
            echo "  ⚠ Could not write deploy commit marker (non-fatal)"
            local d=$(($(date +%s) - STEP_START))
            STEP_NAMES+=("$STEP_LABEL")
            STEP_TIMES+=("$d")
        fi
    fi
}

print_final_summary() {
    print_summary
    write_deploy_history "SUCCESS"
    local total=$(($(date +%s) - DEPLOY_START))
    echo ""
    echo "  ✓ Deployment Successful!"
    echo "  Server   $SERVER_IP"
    echo "  Site     https://${DEPLOY_DOMAIN}"
    echo "  Grafana  https://${DEPLOY_DOMAIN}/grafana/"
    echo "  SSH      ssh -i ${SSH_KEY##*/} ubuntu@${SERVER_IP}"
    echo "  Time     $(format_time $total)"
    echo ""
    echo "  Log: $LOG"
}
