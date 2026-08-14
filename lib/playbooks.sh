# Ansible playbook execution logic for deploy.sh
# shellcheck shell=bash
# Sourced by deploy.sh — do not execute directly.

run_playbooks() {
    if [[ "$PARALLEL_MODE" == "true" ]]; then
        # Phase 1: Base (sequential — prerequisite)
        step_start "Base packages"
        run_ansible "playbook-01-base.yml" "Base packages" || step_fail "Base packages failed"
        step_ok

        # Phase 2: Web + DB
        step_start "Phase 2: Web/DB"
        run_parallel "Web/DB" \
            "$1" \
            "playbook-03-db.yml:Database & Restore" || step_fail "Phase 2 failed"
        step_ok

        # Phase 2.5: Security (sequential — requires DB + web config)
        step_start "Security hardening"
        run_ansible "playbook-04-security.yml" "Security hardening" || step_fail "Security hardening failed"
        step_ok

        # Phase 3: Monitoring + Backup + Grafana
        step_start "Phase 3: Monitoring/Backup/Grafana"
        run_parallel "Monitoring/Backup/Grafana" \
            "playbook-05-monitor.yml:Monitoring" \
            "playbook-06-backup.yml:Backup & Telegram bot" \
            "playbook-07-grafana.yml:Grafana" \
            "playbook-08-promtail.yml:Promtail" || step_fail "Phase 3 failed"
        step_ok
    else
        for entry in "${PLAYBOOK_LIST[@]}"; do
            local pb="${entry%%:*}" label="${entry##*:}"
            step_start "$label"
            run_ansible "$pb" "$label" || step_fail "$label failed"
            step_ok
        done
    fi
}
