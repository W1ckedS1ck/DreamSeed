# Priority Fixes — Immediate Actions (Top 20)

**Total Effort:** ~10 hours | **Priority:** URGENT (before production)

---

## 🔴 CRITICAL — Apply First (3–4 hours)

### 1. Redis Password World-Readable (15m)
**File:** `ansible-roles/monitoring/tasks/redis_exporter.yml:30`
```bash
# BEFORE:
ExecStart=/usr/local/bin/redis_exporter -redis.password {{ redis_password }}

# AFTER:
# Move to environment file
```
**Action:** Create `/etc/redis_exporter/env` with `REDIS_PASSWORD={{ redis_password }}`, mode `0600`, owner `redis_exporter:redis_exporter`. Update ExecStart to use `EnvironmentFile=/etc/redis_exporter/env` and `-redis.password $REDIS_PASSWORD`.

---

### 2. Grafana Token in Promtail Drop-In (15m)
**File:** `ansible-roles/promtail/tasks/main.yml:47-54`
**Action:** Change `/etc/systemd/system/promtail.service.d/override.conf` mode from `0644` to `0600`.
```yaml
- name: Create promtail override
  file:
    path: /etc/systemd/system/promtail.service.d
    owner: root
    group: root
    mode: '0755'
    state: directory

- name: Write promtail env
  copy:
    content: |
      [Service]
      EnvironmentFile=/etc/promtail/env
    dest: /etc/systemd/system/promtail.service.d/override.conf
    owner: root
    group: root
    mode: '0600'

- name: Promtail env with secrets
  copy:
    content: |
      LOKI_PASSWORD={{ loki_password }}
      LOKI_USERNAME={{ loki_username }}
    dest: /etc/promtail/env
    owner: promtail
    group: promtail
    mode: '0600'
```

---

### 3. Lock File Race Condition (30m)
**File:** `deploy.sh:163`
```bash
# BEFORE:
exec 200>"$LOCK_FILE"   # O_TRUNC destroys contents
if ! flock -n 200; then
    stale_pid=$(cat "$LOCK_FILE")  # already empty

# AFTER:
exec 200<>"$LOCK_FILE"  # No truncate; read-write
if ! flock -n 200; then
    stale_pid=$(cat "$LOCK_FILE")  # file still has PID

# Later, after acquiring lock:
echo $$ > "$LOCK_FILE"   # Write PID only after locked
```

---

### 4. www DNS Missing for Dev (30m)
**File:** DNS provider (Cloudflare or Hetzner DNS)
**Action:** Add DNS A records for:
- `www.hetz.vitalikuts.online` → dev-hetz IP
- `www.aws.vitalikuts.online` → dev-aws IP

Or exclude `www.` from certbot:
**File:** `terraform/cloudflare/variables.tf` or `group_vars/all.yml`
```yaml
# Exclude www subdomain for non-prod
certbot_domains: "{{ [deploy_domain] + ([deploy_domain_www] if target_env == 'prod' else []) }}"
```

---

### 5. Cloudflare Origin Restricted (1h)
**File:** `terraform/aws/main.tf:57-59` + `terraform/hetzner/main.tf:44-46`
```hcl
# BEFORE:
ingress {
  from_port   = 443
  to_port     = 443
  protocol    = "tcp"
  cidr_blocks = ["0.0.0.0/0"]
}

# AFTER:
# Fetch Cloudflare IPs and restrict
ingress {
  from_port   = 443
  to_port     = 443
  protocol    = "tcp"
  cidr_blocks = concat(
    data.http.cloudflare_ips_v4.response_body_decoded,
    data.http.cloudflare_ips_v6.response_body_decoded
  )
}

# Add data sources:
data "http" "cloudflare_ips_v4" {
  url = "https://api.cloudflare.com/client/v4/ips?networks=v4"
}
data "http" "cloudflare_ips_v6" {
  url = "https://api.cloudflare.com/client/v4/ips?networks=v6"
}
```

---

### 6. setup-secrets Action Injection (45m)
**File:** `.github/actions/setup-secrets/action.yml:23,30,38`
```yaml
# BEFORE:
- run: echo "${{ inputs.ssh-private-key }}" > ~/.ssh/deploy_key

# AFTER:
- env:
    SSH_KEY: ${{ inputs.ssh-private-key }}
    VAULT_PASS: ${{ inputs.vault-password }}
    RCLONE_CONF: ${{ inputs.rclone-config }}
  run: |
    echo "$SSH_KEY" > ~/.ssh/deploy_key
    echo "$VAULT_PASS" > ~/.vault_pass_dreamseed
    echo "$RCLONE_CONF" > ~/.config/rclone/rclone.conf
```
**Why:** GitHub expands `${{ }}` before shell, so shell metacharacters in secrets execute before assignment. Using `env:` prevents this.

---

### 7. CI Never Cleans secrets/.env (30m)
**File:** `deploy.yml:275-284` (cleanup section)
```yaml
# Add after SSH key cleanup:
- name: Clean secrets
  if: always()
  run: |
    shred -u ~/secrets/.env 2>/dev/null || true
    shred -u ~/.ssh/deploy_key 2>/dev/null || true
    shred -u ~/.vault_pass_dreamseed 2>/dev/null || true
    shred -u ~/.config/rclone/rclone.conf 2>/dev/null || true
```

---

### 8. BETTERUPTIME_CHECK_SERVICES_KEY Missing (15m)
**File:** GitHub Actions Secrets
**Action:**
1. Generate new key: `gh secret set BETTERUPTIME_CHECK_SERVICES_KEY --body "$(uuidgen)"`
2. Add to Better Stack API (or use existing)
3. Map in `deploy.yml` env:
```yaml
env:
  BETTERUPTIME_CHECK_SERVICES_KEY: ${{ secrets.BETTERUPTIME_CHECK_SERVICES_KEY }}
```

---

### 9. Playbook Names Wrong (10m)
**File:** `playbook-04-security.yml:2` through `playbook-07-grafana.yml:2`
```yaml
# BEFORE:
- name: 07 Security    # playbook-04-security.yml

# AFTER:
- name: 04 Security
```
**Fix all 4 playbooks (04→07).**

---

### 10. Promtail Ordering (1h)
**File:** `ansible/playbook-05-monitor.yml`
**Action:** Move promtail role to playbook-07 or move Grafana repo addition to playbook-05.
```yaml
# Option 1: Move promtail to playbook-07
# playbook-07-grafana.yml:
- hosts: all
  roles:
    - role: grafana-repo      # Add Grafana repo FIRST
    - role: promtail          # Then install promtail
    - role: grafana

# Option 2: Add Grafana repo earlier in playbook-05
# playbook-05-monitor.yml:
- hosts: all
  roles:
    - role: grafana-repo      # Add before promtail
    - role: promtail
    - role: monitoring
```

---

## 🟠 HIGH — Next Pass (3–4 hours)

### 11. RESTORE_ALL.sh Nullglob (20m)
**File:** `scripts/RESTORE_ALL.sh:1-5`
```bash
#!/bin/bash
set -euo pipefail
shopt -s nullglob    # ADD THIS
```

### 12. No Approval Gates on Prod (1h)
**File:** `.github/workflows/deploy.yml:1-10`
```yaml
name: Deploy
on:
  workflow_dispatch:
    inputs:
      environment:
        description: 'Target environment'
        required: true
        type: choice
        options:
          - dev-aws
          - dev-hetz
          - prod
          - prod-hetz

# ADD AT WORKFLOW ROOT:
concurrency:
  group: deployment-${{ github.ref }}
  cancel-in-progress: false

jobs:
  deploy:
    runs-on: ubuntu-latest
    environment: ${{ github.event.inputs.environment }}  # ADD THIS
    timeout-minutes: 30
```

### 13. test-restored-server.sh Missing (30m)
**File:** `.github/workflows/test-restore.yml:763`
Either:
- Create `scripts/test-restored-server.sh` with comprehensive health checks, OR
- Remove the step that calls it

### 14. Faro/Loki URLs Masked (30m)
**File:** `deploy.yml:68-95` (env section)
```yaml
# ADD before printing env:
- name: Mask sensitive env vars
  run: |
    echo "::add-mask::$(echo '${{ secrets.DEV_GRAFANA_CLOUD_VMAGENT_URL }}')"
    echo "::add-mask::$(echo '${{ secrets.DEV_LOKI_URL }}')"
    echo "::add-mask::$(echo '${{ secrets.DEV_LOKI_USERNAME }}')"
```

### 15. deploy.sh TTY Hang (30m)
**File:** `deploy.sh:277`
```bash
# BEFORE:
read -rp "  Continue? [y/N] " confirm < /dev/tty

# AFTER:
if [[ -t 0 ]]; then
  read -rp "  Continue? [y/N] " confirm < /dev/tty
else
  # CI mode or piped; use timeout
  confirm="y"
  timeout 5 bash -c 'read -rp "  Continue? [y/N] " c < /dev/tty && confirm="$c"' || true
fi
```

---

## 🟡 MEDIUM — Within 1 Week (2–3 hours)

### 16. MySQL Binlog Enable (1h)
**File:** `ansible-roles/mariadb/templates/99-optimizations.cnf.j2`
```ini
[mysqld]
log_bin = /var/log/mysql/mysql-bin
binlog_format = ROW
expire_logs_days = 7
```
Plus update restore procedure to use `mysqlbinlog` for PITR.

### 17. Backup Freshness Check (30m)
**File:** `scripts/verify_backups.sh:23-61`
```bash
# Add after each backup check:
PROJ_AGE=$(( $(date +%s) - $(stat -c '%Y' "$PROJ_BACKUP") ))
if [[ "$PROJ_AGE" -gt 7200 ]]; then
  echo "⚠️ Project backup is ${PROJ_AGE}s old (> 2 hours)"
  # Push metric
fi
```

### 18. Curl | Tar Checksum (30m)
**File:** `ansible-roles/monitoring/tasks/_install_binary.yml:34`
```yaml
- name: Download and verify binary
  block:
    - name: Fetch binary
      get_url:
        url: "{{ binary_url }}"
        dest: /tmp/binary
        checksum: "sha256:{{ binary_checksum }}"
    - name: Extract
      shell: tar -xzf /tmp/binary -C /usr/local/bin
```

### 19. Monitoring User Separate Password (30m)
**File:** `ansible-roles/mariadb/tasks/main.yml:93`
```yaml
- name: Create monitoring user
  community.mysql.mysql_user:
    name: monitoring
    password: "{{ db_monitoring_pass }}"  # Separate password
```
Generate `db_monitoring_pass` in `gen_vars.py`.

### 20. Redis RDB Integrity (30m)
**File:** `scripts/smart_backup.sh:126-131`
```bash
# After copying RDB:
redis-check-rdb "$REDIS_BACKUP" 2>&1 | grep -q "RDB looks OK!" || {
  REDIS_STATUS="❌ RDB integrity check failed"
  # Alert
}
```

---

## Checklist for Implementation

- [ ] **Security (Fixes 1–10):** 3–4 hours
  - [ ] 1. Redis password → env file
  - [ ] 2. Promtail token → 0600
  - [ ] 3. Lock file race → exec 200<>
  - [ ] 4. www DNS → add records
  - [ ] 5. Cloudflare IP restrict
  - [ ] 6. setup-secrets → env: block
  - [ ] 7. CI cleanup → shred
  - [ ] 8. Better Stack key → GitHub Secrets
  - [ ] 9. Playbook names → fix labels
  - [ ] 10. Promtail ordering → reorder

- [ ] **High-Priority (Fixes 11–15):** 3–4 hours
  - [ ] 11. nullglob → add to RESTORE_ALL.sh
  - [ ] 12. Approval gates → environment: block
  - [ ] 13. test-restored-server.sh → create/remove
  - [ ] 14. Faro/Loki → ::add-mask::
  - [ ] 15. TTY hang → add guard

- [ ] **Medium (Fixes 16–20):** 2–3 hours
  - [ ] 16. Binlog → enable
  - [ ] 17. Backup freshness → age check
  - [ ] 18. curl | tar → checksum verify
  - [ ] 19. Monitoring password → separate
  - [ ] 20. Redis RDB → integrity check

**Total:** ~10 hours of focused work | **Testing:** 2–3 hours on dev-hetz, then 1 prod deploy
