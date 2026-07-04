#!/bin/bash
# Security audit before pushing to GitHub

echo "🔍 DreamSeed Git Security Audit"
echo "================================"
echo ""

ISSUES=0

# 1. Check .gitignore exists and has secrets/
echo "✓ Checking .gitignore..."
if [ ! -f .gitignore ]; then
    echo "  ❌ .gitignore not found!"
    ISSUES=$((ISSUES + 1))
else
    if grep -q "^secrets/" .gitignore && grep -q "^\.env" .gitignore && grep -q "^\*\.service" .gitignore; then
        echo "  ✅ .gitignore looks good (secrets/, .env, *.service excluded)"
    else
        echo "  ⚠️  Missing some critical excludes in .gitignore"
        ISSUES=$((ISSUES + 1))
    fi
fi
echo ""

# 2. Check if secrets/ is tracked
echo "✓ Checking for tracked secrets..."
if git ls-files | grep -q "^secrets/"; then
    echo "  ❌ secrets/ directory is tracked!"
    git ls-files | grep "^secrets/"
    ISSUES=$((ISSUES + 1))
else
    echo "  ✅ secrets/ not tracked"
fi
echo ""

# 3. Check for .env files
echo "✓ Checking for .env files..."
if git ls-files | grep -q "\.env"; then
    echo "  ❌ .env files are tracked!"
    git ls-files | grep "\.env"
    ISSUES=$((ISSUES + 1))
else
    echo "  ✅ No .env files tracked"
fi
echo ""

# 4. Check for .service files (excluding .j2 templates)
echo "✓ Checking for .service files..."
if git ls-files | grep "\.service$"; then
    echo "  ❌ .service files are tracked!"
    ISSUES=$((ISSUES + 1))
elif git ls-files | grep "\.service\.j2$"; then
    echo "  ✅ Only .service.j2 templates tracked (safe)"
else
    echo "  ✅ No .service files tracked"
fi
echo ""

# 5. Check for .pem files
echo "✓ Checking for private keys..."
if git ls-files | grep -E "\.(pem|key|rsa)" | grep -v "\.tfstate"; then
    echo "  ❌ Private key files found!"
    ISSUES=$((ISSUES + 1))
else
    echo "  ✅ No private key files tracked"
fi
echo ""

# 6. Search for common patterns in committed code
echo "✓ Searching for hardcoded secrets in tracked files..."
PATTERNS=(
    "password=\"[^\"]*\""
    "\"password\":" "PASSWORD="
    "token=\"[^\"]*\""
    "_TOKEN=[A-Za-z0-9+/]{20,}"
    "_SECRET=[A-Za-z0-9+/]{20,}"
    "_KEY=[A-Za-z0-9+/]{20,}"
    "_PASS=[A-Za-z0-9+/]{20,}"
    "TG_TOKEN="
    "AWS_SECRET"
    "api_key="
    "\"secret\":"
    "private_key"
    "Authorization: Bearer"
    "-----BEGIN.*PRIVATE KEY-----"
)
FOUND_PATTERNS=0

for pattern in "${PATTERNS[@]}"; do
    matches=$(git grep -iE "$pattern" HEAD 2>/dev/null | grep -v "{{ " | grep -v "lookup('env'" | grep -v "# " || true)
    if [[ -n "$matches" ]]; then
        echo "  ⚠️  Pattern '$pattern' found:"
        echo "$matches" | head -3
        FOUND_PATTERNS=$((FOUND_PATTERNS + 1))
    fi
done

if [ $FOUND_PATTERNS -eq 0 ]; then
    echo "  ✅ No hardcoded secrets found"
else
    echo "  ⚠️  Review patterns above - some may be Ansible variables (safe)"
    ISSUES=$((ISSUES + 1))
fi
echo ""

# 7. Check CLAUDE.md
echo "✓ Checking CLAUDE.md..."
if git ls-files | grep -q "^CLAUDE.md"; then
    echo "  ❌ CLAUDE.md is tracked!"
    ISSUES=$((ISSUES + 1))
else
    echo "  ✅ CLAUDE.md not tracked"
fi
echo ""

# Summary
echo "================================"
if [ $ISSUES -eq 0 ]; then
    echo "✅ All checks passed! Safe to push."
    exit 0
else
    echo "❌ Found $ISSUES critical issue(s). Do NOT push yet."
    exit 1
fi
