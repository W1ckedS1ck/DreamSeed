# Home

Documentation for the DreamSeed infrastructure — a multi-cloud production deployment serving [dreamseed.online](https://dreamseed.online).

> 🗓 **Last updated:** 2026-08-18

## Pages

| Page | Description |
|------|-------------|
| [Architecture](architecture) | Deployment flow, infrastructure layers, CI/CD pipeline, project layout |
| [Operations Guide](operations-guide) | Deploy troubleshooting, alert management, incident recovery |
| [Runbook](runbook) | Incident response procedures and alert handling |
| [Prerequisites](prerequisites) | Local tooling, credentials, secrets setup |
| [Environment Guide](env-guide) | Every env var — where to get it, where it's used |
| [Secrets Reference](secrets-reference) | Complete secret inventory, scope, and rotation |
| [Linters](linters) | Local and CI linting tools and configuration |
| [Code Map](https://w1ckeds1ck.github.io/DreamSeed/) | Interactive map of the codebase — modules, edges, flows |

## Tech Stack

The authoritative stack list lives in the [repository README](https://github.com/W1ckedS1ck/DreamSeed#-tech-stack) — kept in sync with the code, not duplicated here.

In one line: **Terraform + Ansible on AWS EC2 / Hetzner Cloud**, serving **MODX** (Nginx/Apache + PHP 8.3 + MariaDB + Redis) behind **Cloudflare**, with **VictoriaMetrics + Grafana** observability, **Promtail → Loki** logs, **Faro RUM**, **multi-region** monitoring (Grafana Cloud SM from 3 continents + Better Stack from 4 regions), and **rclone → Google Drive** encrypted backups.

> 🌍 **Global by default** — the site is watched from 4 continents via two independent cloud layers, plus a local on-server Grafana stack. See the [README's Global Observability section](https://github.com/W1ckedS1ck/DreamSeed#-global-observability) for the full coverage map.

## Key Architecture Decisions

- **Terraform + Ansible**: Terraform provisions cloud resources; Ansible configures them. The `deploy.sh` orchestrator runs both in sequence, auto-generating Ansible inventory from Terraform outputs.
- **Cloudflare SSL**: Cloudflare edge terminates TLS (Full SSL). Origin servers use either restored certs, certbot DNS-Cloudflare, or self-signed certs as fallback.
- **VictoriaMetrics on-server**: Metrics are scraped locally by VictoriaMetrics (15s interval, 3mo retention) and remotely written to Grafana Cloud via vmagent. This survives server death — the cloud retains the last push.
- **Dev = Prod**: Dev environments mirror prod in every way — monitoring, backups, alerting. Dev backups upload to separate cloud paths but pull prod data on restore.
- **Ephemeral dev**: Dev-aws and dev-hetz are destroyed and rebuilt regularly. State is disposable; all persistent data comes from prod backups.
