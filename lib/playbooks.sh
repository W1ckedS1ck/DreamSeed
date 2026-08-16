# Ansible playbook execution logic for deploy.sh
# shellcheck shell=bash
# Sourced by deploy.sh — do not execute directly.

run_playbooks() {
    if [[ "$PARALLEL_MODE" == "true" ]]; then
        # Phase 1: Base (sequential — prerequisite)
        step_start "Base packages"
        run_ansible "playbook-01-base.yml" "Base packages" || step_fail "Base packages failed"
        step_ok

        # Phase 2: Web + DB + Ubuntu Pro (parallel)
        step_start "Phase 2: Web/DB"
        run_parallel "Web/DB" \
            "$1" \
            "playbook-03-db.yml:Database & Restore" \
            "playbook-09-pro.yml:Ubuntu Pro" || step_fail "Phase 2 failed"
        step_ok

        # Phase 2.5: Security (sequential — requires DB + web config)
        step_start "Security hardening"
        run_ansible "playbook-04-security.yml" "Security hardening" || step_fail "Security hardening failed"
        step_ok

        # Phase 3: Monitoring + Backup + Promtail (parallel) + Grafana (parallel fallback)
        step_start "Phase 3: Monitoring/Backup"
        run_parallel "Monitoring/Backup" \
            "playbook-05-monitor.yml:Monitoring" \
            "playbook-06-backup.yml:Backup & Telegram bot" \
            "playbook-08-promtail.yml:Promtail" \
            "~playbook-07-grafana.yml:Grafana (fallback)" || step_fail "Phase 3 failed"
        step_ok
    else
        for entry in "${PLAYBOOK_LIST[@]}"; do
            local pb="${entry%%:*}" label="${entry##*:}"
            step_start "$label"
            if [[ "$pb" == "playbook-07-grafana.yml" ]]; then
                # Grafana = fallback: never fail the deploy on its error.
                run_ansible "$pb" "$label" || {
                    echo "  ⚠ Grafana failed — continuing (fallback, non-fatal)"
                    echo "  ⚠ GRAFANA_FALLBACK_FAILED=true"
                }
            else
                run_ansible "$pb" "$label" || step_fail "$label failed"
                step_ok
            fi
        done
    fi
}
