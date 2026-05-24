# Prerequisites

Tools required to work with this project locally.

## Core (required to deploy)

| Tool | Min version | Install |
|------|-------------|---------|
| Terraform | 1.5+ | https://developer.hashicorp.com/terraform/install |
| Ansible | 2.15+ | `pip install ansible` |
| Python | 3.10+ | https://python.org |
| SSH client | any | system package |

### Ansible collections

```bash
ansible-galaxy collection install community.mysql ansible.posix
```

## Cloud providers (depending on target)

| Tool | Required for |
|------|--------------|
| AWS CLI | `prod`, `dev-aws` targets (credentials in `secrets/.env`) |
| Hetzner account | `dev-hetz` target |

## Linting / CI (optional, for local checks)

```bash
# Shell
brew install shellcheck

# Python
pip install ruff

# Ansible
pip install ansible-lint

# Terraform
brew install tflint
brew install trivy
```

## Secrets setup

Copy the template and fill in your values:

```bash
cp secrets/.env.example secrets/.env
```

See `secrets/.env.example` for the full list of required variables.
