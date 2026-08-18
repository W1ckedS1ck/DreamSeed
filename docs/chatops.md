# ChatOps Deploy

Trigger deploys and destroys from any GitHub issue/PR comment — no Actions UI, no local `deploy.sh`.

> 🗓 **Last updated:** 2026-08-18

```
/deploy dev-hetz -p
```

The bot replies with the dispatch result. All commands are authorized by GitHub collaborator
permissions (see [Permissions](#permissions)).

## How it works

```
issue comment ──▶ [chatops] Deploy workflow ──▶ parse.py ──▶ dispatch deploy.yml ──▶ real deploy
```

1. **Trigger** — any new `issue_comment` on any issue/PR.
2. **Parse** — `parse.py` classifies the comment:
   - `none` — not a `/deploy` or `/destroy` command → **silently ignored** (green run, no reply, no reaction)
   - `invalid` — an unrecognized `/...` command → reply `Unknown command`, never deploys
   - `deploy` / `destroy` / `help` / `status` — handled
3. **Permission gate** — author must be `OWNER`/`MEMBER`/`COLLABORATOR` with `write` or `admin`;
   **prod targets require `admin`**.
4. **Dispatch** — runs `deploy.yml` via `gh workflow run --ref main` (always from `main`, the
   stable branch — never from the comment's branch).

## Commands

| Command | Action |
|---------|--------|
| `/deploy <target>` | Deploy the target (Nginx, sequential by default) |
| `/deploy <target> -a` | Deploy with Apache |
| `/deploy <target> -p` | Parallel playbook execution (3 phases) |
| `/deploy <target> -i <ip>` | Skip Terraform — reconfigure an existing server IP |
| `/destroy <target>` | Destroy the environment (with confirmation) |
| `/deploy status` | Show the 5 most recent `deploy.yml` runs |
| `/deploy help` | Print this command reference |

### Flags

| Flag | Meaning |
|------|---------|
| `-n` | Nginx (default web server) |
| `-a` | Apache |
| `-p` | Parallel playbook execution |
| `-i <ipv4>` | Skip Terraform, redeploy onto the given IP |

## Targets

| Target | Provider | Notes |
|--------|----------|-------|
| `prod` | AWS | Production; **admin only** |
| `prod-hetz` | Hetzner | Production; **admin only** |
| `dev-aws` | AWS | Dev |
| `dev-hetz` | Hetzner | Dev |

## Permissions

- Author must be `OWNER`, `MEMBER` or `COLLABORATOR` (GitHub association).
- Deploy/destroy requires `write` or `admin` collaborator permission.
- **Prod targets (`prod`, `prod-hetz`) additionally require `admin`** — otherwise the bot
  refuses with a clear message and the run fails.
- Non-authorized authors get a `-1` reaction and nothing else happens.

## Examples

```
/deploy help
/deploy status
/deploy dev-hetz -p            # dev Hetzner, parallel, Nginx
/deploy dev-aws -a -p          # dev AWS, Apache, parallel
/deploy prod-hetz -n -p        # prod Hetzner (admin only), parallel
/deploy dev-hetz -i 1.2.3.4    # reconfigure existing dev server (skip Terraform)
/destroy dev-aws               # destroy dev AWS
```

## Non-commands are ignored

Any comment that is not a slash command (e.g. "Closed — will recreate a clean PR later")
is **ignored silently**: the workflow completes green, no reaction, no reply, no deploy.
Only `/deploy` and `/destroy` prefixed comments are treated as commands.

## Where the code lives

| File | Purpose |
|------|---------|
| `.github/workflows/chatops-deploy.yml` | Orchestration: parse → gate → dispatch |
| `.github/actions/chatops/parse.py` | Command parsing (`none`/`invalid`/`deploy`/`destroy`/`help`/`status`) |
| `.github/actions/chatops/post_help.py` | `/deploy help` reply |
| `.github/actions/chatops/post_status.py` | `/deploy status` reply |
| `.github/workflows/deploy.yml` | The actual deploy/destroy workflow (dispatched with `--ref main`) |

## Adding a target

1. Add the target to the parser regex in `parse.py` (`prod-hetz|dev-aws|dev-hetz|prod`).
2. Add it to the `environment` choices in `deploy.yml`.
3. Add a row to the [Targets](#targets) table.
4. If it's production — ensure the admin gate (`TARGET =~ ^prod`) still covers it.

## Troubleshooting

- **Red run with "Unknown command"** — the comment started with `/` but wasn't recognized. Run `/deploy help`.
- **"Production deploy requires admin"** — your role is below `admin`; prod is intentionally gated.
- **Nothing happened on my non-command comment** — correct: non-commands are ignored by design.
