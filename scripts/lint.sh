#!/bin/bash
# Unified linter for DreamSeed.
# Single source of truth — CI, deploy.sh --lint, and local dev all call this.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"

# ----- Colors (strip in CI / non-TTY) -----
RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; CYAN=$'\033[0;36m'; NC=$'\033[0m'
CI_MODE=false
[[ -t 1 ]] || { RED=''; GREEN=''; YELLOW=''; CYAN=''; NC=''; }

TOOLS=(
    "shellcheck:shellcheck:brew install shellcheck"
    "ruff:ruff:pip install ruff"
    "ansible-lint:ansible-lint:pip install ansible-lint"
    "j2lint:j2lint:pip install j2lint"
    "actionlint:actionlint:brew install actionlint"
    "tflint:tflint:brew install tflint"
    "gitleaks:gitleaks:brew install gitleaks"
    "trivy:trivy:brew install trivy"
    "terraform:terraform:brew install terraform"
    "markdownlint-cli2:markdownlint-cli2:npm install -g markdownlint-cli2"
)

FAILED=false

# ----- Helpers -----

group_start() { local n="$1"; if [[ "$CI_MODE" == "true" ]]; then echo "::group::${n}"; else echo -e "\n  ${CYAN}▶ ${n}${NC}"; fi; }
group_end()   { if [[ "$CI_MODE" == "true" ]]; then echo "::endgroup::"; fi; }

print_ok()    { echo -e "    ${GREEN}✓${NC} $1"; }
print_fail()  { echo -e "    ${RED}✗${NC} $1"; FAILED=true; }
print_skip()  { echo -e "    ${YELLOW}⊘${NC} $1"; }
print_error() { $CI_MODE && echo "::error::$1" || echo -e "  ${RED}✗${NC} $1"; }

tool_available() {
    command -v "$1" &>/dev/null
}

ci_annotation() {
    local tool="$1" result="$2"
    if [[ "$CI_MODE" != "true" ]]; then return 0; fi
    if [[ "$result" == "pass" ]]; then
        echo "  ${tool}: passed"
    else
        echo "::error title=${tool}::${tool} reported issues"
    fi
}

# ----- Linters -----

run_shellcheck() {
    group_start "ShellCheck"
    if ! tool_available shellcheck; then print_skip "shellcheck not installed"; group_end; return 0; fi

    local sh_files=()
    while IFS= read -r -d '' f; do sh_files+=("$f"); done < <(
        find . -name "*.sh" -not -path "./.git/*" -not -path "./secrets/*" -print0
    )

    if shellcheck --severity=error "${sh_files[@]}"; then
        print_ok "No errors"; ci_annotation "ShellCheck" "pass"
    else
        print_fail "Errors found"; ci_annotation "ShellCheck" "fail"
    fi
    group_end
}

run_ruff() {
    group_start "Ruff (Python)"
    if ! tool_available ruff; then print_skip "ruff not installed"; group_end; return 0; fi

    if ruff check scripts/; then
        print_ok "No issues"; ci_annotation "Ruff" "pass"
    else
        print_fail "Issues found"; ci_annotation "Ruff" "fail"
    fi
    group_end
}

run_j2lint() {
    group_start "j2lint (Jinja2 Templates)"
    if ! tool_available j2lint; then print_skip "j2lint not installed"; group_end; return 0; fi

    local j2_files=()
    while IFS= read -r -d '' f; do j2_files+=("$f"); done < <(
        find ansible-roles -name "*.j2" -print0
    )

    if j2lint --ignore single-statement-per-line jinja-variable-lower-case jinja-statements-indentation jinja-statements-delimiter -- "${j2_files[@]}"; then
        print_ok "No issues"; ci_annotation "j2lint" "pass"
    else
        print_fail "Issues found"; ci_annotation "j2lint" "fail"
    fi
    group_end
}

run_actionlint() {
    group_start "actionlint (GitHub Actions)"
    if ! tool_available actionlint; then print_skip "actionlint not installed"; group_end; return 0; fi

    if actionlint; then
        print_ok "No issues"; ci_annotation "actionlint" "pass"
    else
        print_fail "Issues found"; ci_annotation "actionlint" "fail"
    fi
    group_end
}

run_renovate_validate() {
    group_start "Renovate Config Validator"
    if ! tool_available npx; then print_skip "npx not installed"; group_end; return 0; fi

    if npx --yes @renovatebot/config-validator 2>&1; then
        print_ok "renovate.json valid"; ci_annotation "Renovate" "pass"
    else
        print_fail "renovate.json invalid"; ci_annotation "Renovate" "fail"
    fi
    group_end
}

run_ansible_lint() {
    group_start "Ansible Lint"
    if ! tool_available ansible-lint; then print_skip "ansible-lint not installed"; group_end; return 0; fi

    if (cd ansible && ansible-lint .); then
        print_ok "No issues"; ci_annotation "Ansible Lint" "pass"
    else
        print_fail "Issues found"; ci_annotation "Ansible Lint" "fail"
    fi
    group_end
}

run_tflint() {
    group_start "TFLint"
    if ! tool_available tflint; then print_skip "tflint not installed"; group_end; return 0; fi

    local tf_config="$SCRIPT_DIR/.tflint.hcl"
    for dir in aws hetzner grafana; do
        local tf_dir="terraform/$dir"
        [[ ! -d "$tf_dir" ]] && continue
        echo "    Checking $dir..."
        if tflint --chdir="$tf_dir" --config="$tf_config" --init && tflint --chdir="$tf_dir" --config="$tf_config"; then
            print_ok "$dir — clean"
        else
            print_fail "$dir — issues found"
        fi
    done
    ci_annotation "TFLint" "$([[ $FAILED == false ]] && echo pass || echo fail)"
    group_end
}

run_terraform_validate() {
    group_start "Terraform Validate"
    if ! tool_available terraform && ! tool_available tofu; then
        print_skip "terraform/tofu not installed"; group_end; return 0
    fi
    local tf
    tf=$(command -v tofu || command -v terraform)

    for dir in terraform/aws terraform/hetzner terraform/grafana; do
        [[ ! -d "$dir" ]] && continue
        echo "    Validating $dir..."
        # Use TF_VAR_ env vars (works with both terraform and tofu validate)
        if [[ "$dir" == *"grafana" ]]; then
            export TF_VAR_grafana_cloud_url="http://x"
            export TF_VAR_grafana_cloud_token="x"
            export TF_VAR_sm_access_token="x"
            export TF_VAR_sm_enabled="false"
            export TF_VAR_domain="x"
            export TF_VAR_sm_url="x"
        fi
        if "$tf" -chdir="$dir" init -backend=false 2>/dev/null && "$tf" -chdir="$dir" validate; then
            print_ok "$dir — valid"
        else
            print_fail "$dir — validation failed"
        fi
    done
    ci_annotation "Terraform Validate" "$([[ $FAILED == false ]] && echo pass || echo fail)"
    group_end
}

run_gitleaks() {
    local mode="${1:-working-tree}"
    group_start "Gitleaks (Secrets) — ${mode}"
    if ! tool_available gitleaks; then print_skip "gitleaks not installed"; group_end; return 0; fi

    local args
    if [[ "$mode" == "full-history" ]]; then
        args="--source ."
    else
        args="--source . --no-git"
    fi

    if gitleaks detect $args -v 2>&1; then
        print_ok "No secrets found"; ci_annotation "Gitleaks" "pass"
    else
        print_fail "Secrets detected"; ci_annotation "Gitleaks" "fail"
    fi
    group_end
}

run_trivy() {
    group_start "Trivy (IaC Security)"
    if ! tool_available trivy; then print_skip "trivy not installed"; group_end; return 0; fi

    if trivy config --severity HIGH,CRITICAL --exit-code 1 terraform/ 2>&1; then
        print_ok "No misconfigurations"; ci_annotation "Trivy" "pass"
    else
        print_fail "Security issues found"; ci_annotation "Trivy" "fail"
    fi
    group_end
}

run_markdownlint() {
    group_start "markdownlint (Documentation)"
    if ! tool_available markdownlint-cli2; then print_skip "markdownlint-cli2 not installed (npm install -g markdownlint-cli2)"; group_end; return 0; fi

    if markdownlint-cli2 --config .markdownlint.yml "Documentation/**/*.md" "README.md"; then
        print_ok "No issues"; ci_annotation "markdownlint" "pass"
    else
        print_fail "Issues found"; ci_annotation "markdownlint" "fail"
    fi
    group_end
}

run_secrets_audit() {
    group_start "Secrets Audit"
    local issues=0

    # .gitignore check
    if [[ ! -f .gitignore ]]; then
        print_fail ".gitignore not found"; ((issues++))
    else
        print_ok ".gitignore exists"
    fi

    # Tracked secrets
    if git ls-files 2>/dev/null | grep -q "^secrets/"; then
        print_fail "secrets/ directory is tracked in git"
        ((issues++))
    else
        print_ok "secrets/ not tracked"
    fi

    if git ls-files 2>/dev/null | grep -q "\.env$"; then
        print_fail ".env files are tracked in git"
        ((issues++))
    else
        print_ok "No .env files tracked"
    fi

    if git ls-files 2>/dev/null | grep -qE '\.(pem|key|rsa)$'; then
        print_fail "Private key files tracked in git"
        ((issues++))
    else
        print_ok "No private keys tracked"
    fi

    # Hardcoded secrets in tracked code (line-level filtering to avoid false positives)
    local patterns=("password=\"" "token=\"" "TG_TOKEN=" "AWS_SECRET_KEY=" "AWS_SECRET_ACCESS_KEY=" "api_key=" "private_key" "Authorization: Bearer")
    local found=0
    for pat in "${patterns[@]}"; do
        if git grep -n "$pat" HEAD 2>/dev/null | \
            grep -v "^HEAD:secrets/" | \
            grep -v "\.example:" | \
            grep -v "^HEAD:\.github/" | \
            grep -v "^HEAD:audit-secrets.sh:" | \
            grep -v "^HEAD:scripts/lint.sh:" | \
            grep -v "\.md:" | \
            grep -v "{{ " | \
            grep -v '\$' | \
            grep -q "." 2>/dev/null; then
            ((found++))
        fi
    done
    if [[ $found -gt 0 ]]; then
        print_fail "Potential hardcoded secrets found ($found patterns)"
        ((issues++))
    else
        print_ok "No hardcoded secrets"
    fi

    if [[ $issues -eq 0 ]]; then
        print_ok "All secrets checks passed"
        ci_annotation "Secrets Audit" "pass"
    else
        ci_annotation "Secrets Audit" "fail"
    fi
    group_end
}

# ----- Summary -----

print_summary() {
    echo ""
    if $CI_MODE; then echo "::group::Summary"; fi
    echo "  ════════════════════════════════════════════"
    if [[ "$FAILED" == "true" ]]; then
        echo "  ${RED}✗ Some linters reported issues${NC}"
        echo ""
        if $CI_MODE; then echo "::endgroup::"; fi
        return 1
    else
        echo "  ${GREEN}✓ All linters passed${NC}"
        echo ""
        if $CI_MODE; then echo "::endgroup::"; fi
        return 0
    fi
}

list_tools() {
    echo ""
    echo "  ${CYAN}Available linters:${NC}"
    echo ""
    for entry in "${TOOLS[@]}"; do
        local bin="${entry%%:*}"
        local rest="${entry#*:}"
        local name="${rest%%:*}"
        local install="${rest##*:}"
        if tool_available "$bin"; then
            echo "    ${GREEN}✓${NC} $name"
        else
            echo "    ${YELLOW}⊘${NC} $name ($install)"
        fi
    done
    echo ""
    $FAILED && return 1 || return 0
}

# ----- Main -----

usage() {
    cat << EOF
DreamSeed Unified Linter

Usage: $0 [OPTIONS]

OPTIONS:
  --fast              Quick check: shellcheck + ruff + ansible-lint (default)
  --full              All linters (fast + tflint + terraform validate + gitleaks + trivy + secrets)
  --ci                CI mode (::group::/::error:: annotations)

  --shellcheck        Run only shellcheck
  --ruff              Run only ruff
  --ansible-lint      Run only ansible-lint
  --j2lint            Run only j2lint (Jinja2 templates)
  --actionlint        Run only actionlint (GitHub Actions workflows)
  --renovate          Run only renovate config validator
  --tflint            Run only tflint
  --validate-terraform Run only terraform validate
  --gitleaks          Run only gitleaks (working tree)
  --gitleaks-full-history Run only gitleaks (full git history, slower)
  --trivy             Run only trivy
  --markdownlint      Run only markdownlint (Documentation/)
  --secrets           Run only secrets audit

  --list              Show available tools and their status
  -h, --help          Show this help

EXAMPLES:
  $0 --fast            # Before deploy
  $0 --full --ci       # Full check in GitHub Actions
  $0 --shellcheck      # Single linter
EOF
}

run_fast() {
    run_shellcheck
    run_ruff
    run_ansible_lint
    run_j2lint
    run_actionlint
    run_renovate_validate
    run_markdownlint
}

run_full() {
    run_fast
    run_tflint
    run_terraform_validate
    run_gitleaks
    run_trivy
    run_secrets_audit
}

MODE="fast"

[[ $# -eq 0 ]] && set -- --fast

while [[ $# -gt 0 ]]; do
    case "$1" in
        --fast)              MODE="fast"; shift ;;
        --full)              MODE="full"; shift ;;
        --ci)                CI_MODE=true; shift ;;
        --shellcheck)        MODE="shellcheck"; shift ;;
        --ruff)              MODE="ruff"; shift ;;
        --ansible-lint)      MODE="ansible-lint"; shift ;;
        --j2lint)            MODE="j2lint"; shift ;;
        --actionlint)        MODE="actionlint"; shift ;;
        --renovate)          MODE="renovate"; shift ;;
        --tflint)            MODE="tflint"; shift ;;
        --validate-terraform) MODE="terraform-validate"; shift ;;
        --gitleaks)          MODE="gitleaks"; shift ;;
        --gitleaks-full-history) MODE="gitleaks-full-history"; shift ;;
        --trivy)             MODE="trivy"; shift ;;
        --markdownlint)      MODE="markdownlint"; shift ;;
        --secrets)           MODE="secrets"; shift ;;
        --list)              MODE="list"; shift ;;
        -h|--help)           usage; exit 0 ;;
        *) echo "Unknown option: $1"; usage; exit 1 ;;
    esac
done

case "$MODE" in
    fast)                run_fast ;;
    full)                run_full ;;
    shellcheck)          run_shellcheck ;;
    ruff)                run_ruff ;;
    ansible-lint)        run_ansible_lint ;;
    j2lint)              run_j2lint ;;
    actionlint)          run_actionlint ;;
    renovate)            run_renovate_validate ;;
    tflint)              run_tflint ;;
    terraform-validate)  run_terraform_validate ;;
    gitleaks)            run_gitleaks ;;
    gitleaks-full-history) run_gitleaks "full-history" ;;
    trivy)               run_trivy ;;
    markdownlint)        run_markdownlint ;;
    secrets)             run_secrets_audit ;;
    list)                list_tools ;;
    *)                   echo "Unknown mode"; usage; exit 1 ;;
esac

print_summary || exit 1
