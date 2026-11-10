# Contributing to DreamSeed

DreamSeed is the production infrastructure for [dreamseed.online](https://dreamseed.online):
Terraform, Ansible, CI/CD, observability, backups and disaster recovery.

## Before you start

- **Security issues:** do **not** open a public issue. Use GitHub private
  vulnerability reporting — see [`.github/SECURITY.md`](.github/SECURITY.md).
- **Non-trivial changes:** open an issue first to agree on the approach.
- **Small fixes:** a pull request is enough.

## Pull request process

1. Branch from `main` (or fork the repository).
2. Keep the change focused; one logical change per PR.
3. Run `make lint`, `make test` and `make test-bash` locally.
4. Open a PR against `main` using the pull request template. Direct pushes to
   `main` are blocked by the `Protect Main` ruleset.
5. All **11 required checks** must pass. PRs are **squash-merged**; history
   stays linear.
6. Production changes (`deploy`, `terraform apply`, `rollback`, Grafana Cloud)
   additionally require approval of the GitHub `production` environment.
7. Update `docs/` in the same PR — the wiki is synced from `docs/` on merge.

## Requirements for acceptable contributions

- **Style and linters:** ShellCheck, ruff (lint + format), bats, ansible-lint,
  tflint, terraform fmt, yamllint, actionlint, zizmor, markdownlint. See
  [`docs/linters.md`](docs/linters.md) and [`.editorconfig`](.editorconfig).
- **Tests:** add or update tests for behavior changes (`tests/unit` for Python,
  `tests/bats` for shell helpers, `tests/env` for the parser contract). Bug
  fixes should come with a regression test.
- **Secrets:** never commit credentials. `secrets/` is gitignored; secrets are
  stored in Ansible Vault and GitHub Secrets. Gitleaks scans full history in CI.
- **Docs:** user-visible behavior, commands and environment variables belong in
  `docs/` (see [`docs/env-guide.md`](docs/env-guide.md)).
- **Commit messages:** conventional style with a scope, e.g.
  `fix(backup): ...`, `feat(monitoring): ...`, `docs(posture): ...`.

## Local commands

```bash
make help          # list targets
make lint          # fast lint suite (ShellCheck, ruff, bats, ansible-lint, actionlint, zizmor, yamllint, ...)
make lint-full     # + terraform validate, tflint, gitleaks, Trivy, secrets audit
make fmt           # terraform fmt
make fmt-py        # ruff format
make test          # Python unit tests (pytest)
make test-bash     # Bash unit tests (bats)
make test-env      # .env parser contract + differential fuzz
make precommit     # all pre-commit hooks
```

Python test dependencies are hash-pinned and installed with uv (pip is ~10x
slower on these locks):

```bash
uv venv .venv && source .venv/bin/activate
uv pip install --require-hashes -r ci/requirements.txt
```

## Code of conduct

This project follows the [Contributor Covenant 3.0](CODE_OF_CONDUCT.md).
Report violations privately to **hello@dreamseed.online** or via GitHub to
[@W1ckedS1ck](https://github.com/W1ckedS1ck) — never in a public issue.

## Issue and pull request templates

Use the issue forms in `.github/ISSUE_TEMPLATE/` (bug, feature, docs) and the
pull request template. Security reports must go through
[private vulnerability reporting](.github/SECURITY.md), not the public tracker.

## License

By contributing, you agree that your contributions are licensed under the
[MIT License](LICENSE).
