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
3. Run `make lint` and `make test` locally.
4. Open a PR against `main`. Direct pushes to `main` are blocked by the
   `Protect Main` ruleset.
5. All **11 required checks** must pass. PRs are **squash-merged**; history
   stays linear.
6. Production changes (`deploy`, `terraform apply`, `rollback`, Grafana Cloud)
   additionally require approval of the GitHub `production` environment.
7. Update `docs/` in the same PR — the wiki is synced from `docs/` on merge.

## Requirements for acceptable contributions

- **Style and linters:** ShellCheck, ruff, ansible-lint, tflint, terraform fmt,
  yamllint, actionlint, zizmor, markdownlint. See
  [`docs/linters.md`](docs/linters.md) and [`.editorconfig`](.editorconfig).
- **Tests:** add or update tests for behavior changes (`tests/unit`,
  `tests/env`). Bug fixes should come with a regression test.
- **Secrets:** never commit credentials. `secrets/` is gitignored; secrets are
  stored in Ansible Vault and GitHub Secrets. Gitleaks scans full history in CI.
- **Docs:** user-visible behavior, commands and environment variables belong in
  `docs/` (see [`docs/env-guide.md`](docs/env-guide.md)).
- **Commit messages:** conventional style with a scope, e.g.
  `fix(backup): ...`, `feat(monitoring): ...`, `docs(posture): ...`.

## Local commands

```bash
make help          # list targets
make lint          # fast lint suite (ShellCheck, ruff, ansible-lint, actionlint, zizmor, yamllint, ...)
make lint-full     # + terraform validate, tflint, gitleaks, Trivy, secrets audit
make test          # unit tests (pytest)
make test-env      # .env parser contract + differential fuzz
make precommit     # all pre-commit hooks
```

Python test dependencies are hash-pinned:

```bash
pip install --require-hashes -r ci/requirements.txt
```

## License

By contributing, you agree that your contributions are licensed under the
[MIT License](LICENSE).
