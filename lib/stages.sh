# Deploy stage helpers (lock, confirm, check, dry-run) for deploy.sh
# shellcheck shell=bash
# Sourced by deploy.sh — do not execute directly.

acquire_lock() {
    if command -v flock &>/dev/null; then
        local lock_dir="${HOME:-/tmp}/.locks"
        mkdir -p "$lock_dir" && chmod 700 "$lock_dir"
        # Lock by provider (not target) — prod and dev-aws share terraform/aws/
        # (.terraform/ dir, deploy.auto.tfvars). Concurrent same-provider deploys
        # would race on workspace selection and state. Different providers (aws
        # vs hetzner) can run in parallel — they share nothing.
        local lock_file="$lock_dir/deploy-${TF_PROVIDER}.lock"
        exec 200>"$lock_file"
        flock -w 5 200 || {
            echo "Error: another deploy already running for provider '$TF_PROVIDER' (could not acquire lock)"
            exit 1
        }
    else
        # No silent degradation: without flock two same-provider deploys race.
        echo "WARNING: flock not available — deploy lock disabled (${TF_PROVIDER:?})" >&2
    fi
}

print_env() {
    [[ "$TTY" == "false" && "$DESTROY_MODE" == "false" && "$DRY_RUN" != "true" ]] && echo "::group::Environment" || true
    echo "  Target:     $TARGET"
    echo "  Domain:     $DEPLOY_DOMAIN"
    echo "  Provider:   $TF_PROVIDER"
    echo "  Web server: ${WEB_SERVER:-}"
    echo "  Mode:       $([[ "$PARALLEL_MODE" == "true" ]] && echo "parallel" || echo "sequential")"
    [[ "$DESTROY_MODE" == "true" ]] && echo "  Action:     destroy" || true
    [[ "$TTY" == "false" && "$DESTROY_MODE" == "false" && "$DRY_RUN" != "true" ]] && echo "::endgroup::" || true
}

validate_playbooks() {
    if [[ "$DESTROY_MODE" == "false" ]]; then
        for entry in "${PLAYBOOK_LIST[@]}"; do
            local pb="${entry%%:*}"
            if [[ ! -f "$SCRIPT_DIR/ansible/$pb" ]]; then
                echo "Error: playbook not found: $SCRIPT_DIR/ansible/$pb"
                exit 1
            fi
        done
    fi
}

run_check_mode() {
    echo ""
    echo "  ══════════════════ CHECK ══════════════════"
    echo "  ✓ Preflight passed"
    echo "  ✓ All playbooks present"
    if [[ "$SKIP_TERRAFORM" == "false" ]]; then
        export_tf_env
        terraform_init_if_needed || {
            echo "Terraform init failed"
            step_fail "Terraform init failed"
        }
        if _tf validate -no-color >>"$LOG" 2>&1; then
            echo "  ✓ Terraform config valid"
        else
            echo "  ✗ Terraform config invalid (see $LOG)"
            exit 1
        fi
    fi
    for entry in "${PLAYBOOK_LIST[@]}"; do
        local pb="${entry%%:*}" label="${entry##*:}"
        if _ansible_syntax "$pb" >/dev/null 2>&1; then
            echo "  ✓ $label"
        else
            echo "  ✗ $label syntax error"
            _ansible_syntax "$pb" 2>&1
            exit 1
        fi
    done
    echo ""
    echo "  ✓ All checks passed"
    echo "  ════════════════════════════════════════════════"
    echo ""
    exit 0
}

run_dry_run() {
    echo ""
    echo "  ══════════════════ DRY RUN ══════════════════"
    if [[ "$DESTROY_MODE" == "true" ]]; then
        echo "  Action:    Destroy $TARGET"
        echo "  Provider:  $TF_PROVIDER"
        echo "  Would destroy: server, firewall, DNS, key pair"
    else
        echo "  Action:    Deploy $TARGET"
        echo "  Provider:  $TF_PROVIDER"
        echo "  Domain:    $DEPLOY_DOMAIN"
        echo "  Provision: $([[ "$SKIP_TERRAFORM" == "true" ]] && echo "skip (IP: $EXISTING_IP)" || echo "new server")"
        echo ""
        echo "  Playbooks:"
        for entry in "${PLAYBOOK_LIST[@]}"; do
            printf "    ▶ %s\n" "${entry##*:}"
        done
    fi
    echo ""
    echo "  No changes were made."
    echo "  ════════════════════════════════════════════════"
    echo ""
    write_deploy_history "DRY-RUN"
    exit 0
}

confirm_production() {
    if [[ "$TARGET" =~ ^prod && "$DESTROY_MODE" == "false" ]]; then
        echo ""
        echo "  ⚠ Deploying to PRODUCTION ($DEPLOY_DOMAIN)"
        if [[ "${CI:-}" == "true" ]]; then
            echo "  CI mode — confirmation skipped"
        else
            read -rp "  Continue? [y/N] " confirm </dev/tty 2>/dev/null || {
                echo "  Error: no TTY available. Use CI mode or --dry-run."
                exit 1
            }
            [[ ! "${confirm:-}" =~ ^[Yy]$ ]] && {
                echo "Aborted."
                exit 0
            }
        fi
    fi
}

run_destroy() {
    step_start "Terraform destroy ($TARGET)"
    terraform_destroy || step_fail "Terraform destroy failed"
    step_ok
    write_deploy_history "DESTROYED"
    exit 0
}
