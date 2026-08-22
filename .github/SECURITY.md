# Security Policy

## Supported

Only the `main` branch receives security fixes. Infrastructure is re-provisioned from `main` on every deploy, so there are no long-lived release branches to support.

## Reporting a Vulnerability

**Do NOT open a public issue for security reports.**

Use GitHub's private vulnerability reporting:

1. Go to the **Security** tab of this repository
2. Click **Report a vulnerability**
3. Describe the issue, impact, and reproduction steps

You can also reach the maintainer directly via [dreamseed.online](https://dreamseed.online).

- **Response time:** within 72 hours
- **Fix target:** critical issues within 7 days, others best-effort
- **Credit:** offered by default, anonymous disclosure respected

## Scope

In scope:

- Terraform configurations (`terraform/`)
- Ansible roles and playbooks (`ansible/`, `ansible-roles/`)
- Shell/python tooling (`deploy.sh`, `lib/`, `scripts/`, `.github/`)
- CI/CD workflows and composite actions (`.github/workflows/`, `.github/actions/`)

Out of scope:

- Application code of `dreamseed.online` (MODX templates/content) — report those through the site contact
- Social engineering, brute-force, or DoS against live environments
- Findings from automated scanners without a demonstrated exploit path (the pipeline already runs Checkov, Trivy, Gitleaks, and zizmor on every push)

## Security Practices in This Repo

- All secrets live in an Ansible Vault (`secrets/.env`) or GitHub Encrypted Secrets — never in code, tfvars in git, or CI logs
- Full git history is scanned by Gitleaks on every push (pinned version, checksum-verified binary)
- GitHub Actions are SHA-pinned, run with least-privilege tokens (`persist-credentials: false`), and audited by zizmor + actionlint
- Production changes require environment-gated approval workflows; destroy requires typed confirmation strings
