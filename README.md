# DreamSeed

![CI](https://github.com/W1ckedS1ck/DreamSeed/actions/workflows/ci.yml/badge.svg)

Infrastructure-as-Code for automated web server deployment on AWS and Hetzner.

**Stack:** Terraform · Ansible · Nginx/Apache · MariaDB · Prometheus/Grafana · Let's Encrypt

## Quick start

```bash
./deploy.sh prod -n        # AWS + Nginx
./deploy.sh dev-hetz -n    # Hetzner + Nginx
./deploy.sh prod -x        # Destroy
```

## Structure

```
terraform/      # Infrastructure (AWS, Hetzner, Cloud.ru)
ansible/        # Playbooks
ansible-roles/  # Reusable roles
scripts/        # Backup, monitoring, restore
```
