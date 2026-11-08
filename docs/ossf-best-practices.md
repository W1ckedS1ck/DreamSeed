# OpenSSF Best Practices Badge — worksheet

Working notes for the [OpenSSF Best Practices](https://www.bestpractices.dev/)
**passing** badge for DreamSeed. Registration and the questionnaire require a
GitHub login, so the answers below are prepared to copy into the form.

- Criteria: <https://www.bestpractices.dev/en/criteria/0>
- New project: <https://www.bestpractices.dev/en/projects/new>

The **passing** badge is self-certified: every **MUST** criterion must be
`Met` or `N/A` with a justification. `SHOULD` / `SUGGESTED` do not block it.

## Project metadata

| Field | Value |
|-------|-------|
| Name | DreamSeed |
| Description | Production infrastructure as code for dreamseed.online — Terraform (AWS + Hetzner), 17 Ansible roles, CI/CD, observability, encrypted backups and weekly DR drills. |
| Project homepage | `https://github.com/W1ckedS1ck/DreamSeed` |
| Repository | `https://github.com/W1ckedS1ck/DreamSeed` |
| License | MIT |
| Languages | Shell, Python, HCL, YAML |
| Type | Other / Infrastructure as Code |

## Answers

### Basics

| Criterion | Answer | Evidence / justification |
|-----------|--------|--------------------------|
| `description_good` | Met | README → “About the Product”. |
| `interact` | Met | README (Quick Start), GitHub Issues, [CONTRIBUTING.md](https://github.com/W1ckedS1ck/DreamSeed/blob/main/CONTRIBUTING.md). |
| `contribution` | Met | <https://github.com/W1ckedS1ck/DreamSeed/blob/main/CONTRIBUTING.md> |
| `contribution_requirements` | Met | CONTRIBUTING → “Requirements”; [docs/linters.md](https://github.com/W1ckedS1ck/DreamSeed/blob/main/docs/linters.md). |
| `floss_license` | Met | MIT. |
| `floss_license_osi` | Met | MIT is OSI-approved. |
| `license_location` | Met | <https://github.com/W1ckedS1ck/DreamSeed/blob/main/LICENSE> |
| `documentation_basics` | Met | README + `docs/` (architecture, runbook, operations, env guide). |
| `documentation_interface` | Met | [docs/env-guide.md](https://github.com/W1ckedS1ck/DreamSeed/blob/main/docs/env-guide.md) (inputs); README “Deploy Commands” (CLI); `docs/architecture.md` (outputs). |
| `sites_https` | Met | GitHub and dreamseed.online are HTTPS-only. |
| `discussion` | Met | GitHub Issues + Discussions; searchable and URL-addressable. |
| `english` | Met | Documentation and issues are in English. |
| `maintained` | Met | Commits, releases and CI activity in the last 12 months. |

### Change Control

| Criterion | Answer | Evidence / justification |
|-----------|--------|--------------------------|
| `repo_public` | Met | Public GitHub repository. |
| `repo_track` | Met | Git history records what/who/when. |
| `repo_interim` | Met | Changes land via PRs and the `dev` branch between releases. |
| `repo_distributed` | Met | Git. |
| `version_unique` | Met | Release `v1.0.0`. |
| `version_semver` | Met | `v1.0.0`. |
| `version_tags` | Met | Git tag `v1.0.0`. |
| `release_notes` | Met | <https://github.com/W1ckedS1ck/DreamSeed/releases/tag/v1.0.0> |
| `release_notes_vulns` | N/A | No publicly known runtime vulnerabilities; the site is re-provisioned from `main` (continuous delivery). |

### Reporting

| Criterion | Answer | Evidence / justification |
|-----------|--------|--------------------------|
| `report_process` | Met | GitHub Issues. |
| `report_tracker` | Met | GitHub Issues. |
| `report_responses` | N/A | No user-submitted bug reports in the last 12 months; the only open issue is Renovate’s automated Dependency Dashboard. |
| `enhancement_responses` | N/A | No enhancement requests in the window. |
| `report_archive` | Met | GitHub Issues keeps closed reports searchable. |
| `vulnerability_report_process` | Met | <https://github.com/W1ckedS1ck/DreamSeed/blob/main/.github/SECURITY.md> |
| `vulnerability_report_private` | Met | GitHub private vulnerability reporting is enabled (Security tab). |
| `vulnerability_report_response` | N/A | No vulnerability reports in the last 6 months. |

### Quality

| Criterion | Answer | Evidence / justification |
|-----------|--------|--------------------------|
| `build` | N/A | No compiled artifact: Terraform/Ansible apply the configuration. CI validates it (`terraform validate`, `ansible-lint`). |
| `build_common_tools` | N/A | Same as `build`. |
| `build_floss_tools` | N/A | Same as `build`; Terraform/Ansible are FLOSS. |
| `test` | Met | `make test` / `python3 -m pytest tests/unit -q`; CI job `.env Parser Contract`. |
| `test_invocation` | Met | `make test`; standard pytest invocation. |
| `test_most` | Met | Unit tests cover templates, bot helpers, CI guards and the posture audit; env parsers have a fixture contract + differential fuzz. |
| `test_continuous_integration` | Met | GitHub Actions runs on every PR and push to `main`/`dev`. |
| `test_policy` | Met | CONTRIBUTING requires tests for behavior changes. |
| `tests_are_added` | Met | Recent PRs add tests (posture audit, templates, bot helpers). |
| `tests_documented_added` | Met | CONTRIBUTING → “Requirements”. |
| `warnings` | Met | ShellCheck, ruff, ansible-lint, tflint. |
| `warnings_fixed` | Met | CI fails on warnings; no warning debt. |
| `warnings_strict` | Met | Linters run with strict settings in CI. |

### Security

| Criterion | Answer | Evidence / justification |
|-----------|--------|--------------------------|
| `know_secure_design` | Met | Primary developer is the CTO; threat model and controls are documented in `.github/SECURITY.md`, ADRs and the runbook. |
| `know_common_errors` | Met | OWASP/common error classes are covered by reviews, linters and the security policy (injection, secret leaks, TLS, least privilege). |
| `crypto_published` | N/A | The project does not implement cryptography; TLS is provided by Cloudflare / Let’s Encrypt. |
| `crypto_call` | N/A | Same as `crypto_published`. |
| `crypto_floss` | N/A | Same. |
| `crypto_keylength` | N/A | Same. |
| `crypto_working` | N/A | Same. |
| `crypto_weaknesses` | N/A | Same. |
| `crypto_pfs` | N/A | TLS termination and PFS are handled by Cloudflare. |
| `crypto_password_storage` | N/A | This repository does not store user passwords; MODX handles application authentication. |
| `crypto_random` | N/A | No key/nonce generation in this repository. |
| `delivery_mitm` | Met | HTTPS and SSH for all delivery. |
| `delivery_unsigned` | Met | Downloads are verified (SHA256 for actionlint/gitleaks; HTTPS; apt signatures). |
| `vulnerabilities_fixed_60_days` | Met | Dependabot, Trivy and CodeQL; no unpatched medium+ alerts known for >60 days. |
| `vulnerabilities_critical_fixed` | Met | SECURITY.md targets critical fixes in 7 days; Dependabot automates updates. |
| `no_leaked_credentials` | Met | Secret scanning + push protection + Gitleaks full-history scan. |

### Analysis

| Criterion | Answer | Evidence / justification |
|-----------|--------|--------------------------|
| `static_analysis` | Met | CodeQL, Gitleaks, ShellCheck, ansible-lint, tflint, Trivy, Checkov. |
| `static_analysis_common_vulnerabilities` | Met | CodeQL, Trivy and Checkov cover common vulnerability classes. |
| `static_analysis_fixed` | Met | Alerts are triaged; the daily posture audit tracks open findings. |
| `static_analysis_often` | Met | Runs on every push and pull request. |
| `dynamic_analysis` | Met | `tests/env/fuzz_env_parsers.py` (differential fuzz) + weekly full restore drills. |
| `dynamic_analysis_unsafe` | N/A | No memory-unsafe languages in the project. |
| `dynamic_analysis_enable_assertions` | Met | Pytest assertions and fixture contracts. |
| `dynamic_analysis_fixed` | Met | No known dynamic-analysis findings. |

## After the badge is awarded

1. Copy the badge ID from the project page.
2. Add it to `README.md` next to the Scorecard badge:

   ```markdown
   [![OpenSSF Best Practices](https://www.bestpractices.dev/projects/<ID>/badge)](https://www.bestpractices.dev/projects/<ID>)
   ```

3. The weekly Scorecard run picks it up automatically
   (`CII-Best-Practices` moves from 0/10); the posture audit needs no change.
4. Update this page with the badge ID and the date.
