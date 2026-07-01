# Improvements Roadmap

> Tracking file for production-grade upgrades.

---

## 🔴 High — security & compliance

- [ ] **LICENSE** — add MIT license to repo root
- [ ] **SECURITY.md** — where to report vulnerabilities
- [ ] **Backup encryption** — GPG-encrypt tarballs before uploading to GDrive; decrypt on restore
- [ ] **Dependency vulnerability scanning** — `trivy filesystem` for `requirements-deploy.txt`, `requirements.yml`, Python deps in CI

## 🟡 Medium — quality of life

- [ ] **Issue templates** — `bug_report.md`, `feature_request.md`
- [ ] **PR template** — `PULL_REQUEST_TEMPLATE.md`
- [ ] **CONTRIBUTING.md** — onboarding guide
- [ ] **Cost tracking** — enable `infracost` in CI (token exists in legacy)
- [ ] **Staging deploy on Renovate PRs** — auto-deploy to dev-hetz, run checks, report in PR
- [ ] **Version pinning** — `.python-version`, `.terraform-version`

## 🟢 Low — portfolio polish

- [ ] **Structured logging (Loki)** — push logs to Grafana Cloud
- [ ] **Chaos testing** — Litmus/Chaos Mesh or simple kill-service script
- [ ] **Load testing (k6)** — benchmark t3.small/cx23 under MODX
- [x] **MODX health probe** — added `modx_cache_ok` (cache writable) to `check_site.sh.j2` + alert rule in Grafana (23 rules total)
