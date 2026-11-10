## Summary

<!-- What changed and why. Link the issue this closes. -->

Closes #

## Type of change

- [ ] Bug fix (non-breaking)
- [ ] New feature / improvement (non-breaking)
- [ ] Breaking change (deploy/state/behaviour change — describe the migration)
- [ ] Documentation only
- [ ] Refactor (no behaviour change)
- [ ] Dependency update (Renovate)

## Affected layers

- [ ] Terraform (`terraform/`)
- [ ] Ansible (`ansible/`, `ansible-roles/`)
- [ ] Orchestration (`deploy.sh`, `lib/`)
- [ ] CI/CD (`.github/workflows/`, `.github/actions/`)
- [ ] Server scripts (`scripts/`)
- [ ] Docs / wiki source (`docs/`)

## Testing

<!-- Paste the commands you ran and their result. -->

- [ ] `make lint` (ShellCheck, ruff, bats, ansible-lint, actionlint, zizmor, yamllint, …)
- [ ] `make test` (pytest)
- [ ] `make test-env` (`.env` parser contract + fuzz)
- [ ] Terraform: `terraform fmt -check` / `tflint` / `terraform validate` (if `terraform/` changed)
- [ ] Dry-run: `./deploy.sh <target> -n --dry-run` (if deploy logic changed)
- [ ] New/updated tests cover the change (bug fixes include a regression test)

## Safety checklist

- [ ] No secrets, tokens, private keys or decrypted vault values in code, logs or this PR.
- [ ] `secrets/` is not tracked; new secrets go into Ansible Vault **and** GitHub Secrets.
- [ ] Production impact is described (deploy order, rollback, downtime).
- [ ] Docs updated in the same PR (`README.md`, `docs/`, `.env.example` if variables changed).
- [ ] If a CI job was added/removed, the `Protect Main` ruleset was updated (the `check_required_checks.py` guard enforces this).

## Rollback plan

<!-- How do we undo this? e.g. revert commit + redeploy, terraform state rollback, restore from backup. -->

## Notes for reviewers

<!-- Anything non-obvious: trade-offs, follow-ups, deliberately deferred work. -->
