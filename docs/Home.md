# Home

Documentation for the DreamSeed infrastructure — a multi-cloud production deployment serving [dreamseed.online](https://dreamseed.online).

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

| Layer | Tool |
|-------|------|
| Cloud | AWS EC2, Hetzner Cloud |
| Provisioning | Terraform Cloud (remote state, runs, Sentinel) |
| Configuration | Ansible (8 playbooks, 17 custom roles) |
| Web | Nginx + PHP-FPM + Redis + MariaDB |
| CMS | MODX Revolution |
| SSL | Cloudflare (Full SSL), certbot DNS-Cloudflare fallback |
| Monitoring | VictoriaMetrics + vmagent, Node/MySQLd/Redis/Nginx exporters |
| Dashboards | Grafana (on-server, 6 on Nginx / 5 on Apache, 23 alerts) |
| Remote Write | Grafana Cloud (Prometheus remote_write) |
| Logs | Promtail → Grafana Cloud Loki |
| RUM | Grafana Faro |
| Uptime | Better Stack (3 monitors, 6 heartbeats) |
| Backup | Local + rclone → Google Drive (AES-256 encrypted) |
| Secret Storage | Ansible Vault at rest, GitHub Secrets in CI |
| Docs Generator | Python (gen_codemap.py) — machine-verified flows and relationships |

## Key Architecture Decisions

- **Terraform + Ansible**: Terraform provisions cloud resources; Ansible configures them. The `deploy.sh` orchestrator runs both in sequence, auto-generating Ansible inventory from Terraform outputs.
- **Cloudflare SSL**: Cloudflare edge terminates TLS (Full SSL). Origin servers use either restored certs, certbot DNS-Cloudflare, or self-signed certs as fallback.
- **VictoriaMetrics on-server**: Metrics are scraped locally by VictoriaMetrics (15s interval, 3mo retention) and remotely written to Grafana Cloud via vmagent. This survives server death — the cloud retains the last push.
- **Dev = Prod**: Dev environments mirror prod in every way — monitoring, backups, alerting. Dev backups upload to separate cloud paths but pull prod data on restore.
- **Ephemeral dev**: Dev-aws and dev-hetz are destroyed and rebuilt regularly. State is disposable; all persistent data comes from prod backups.
