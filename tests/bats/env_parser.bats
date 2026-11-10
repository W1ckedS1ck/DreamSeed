#!/usr/bin/env bats
# Unit tests for lib/env.sh parse_env_file. The same fixtures are used by the
# cross-parser contract (scripts/check_env_contract.sh); these tests pin the
# deploy-side behaviour directly, without needing the other two parsers.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    # shellcheck source=/dev/null
    source "$REPO_ROOT/lib/env.sh"
    FIXTURES="$REPO_ROOT/tests/env"
}

# Run parse_env_file in a subshell and print one variable so `run` can assert
# on it. Exports made by parse_env_file never leak into the test process.
parse_and_print() {
    local file="$1" var="$2"
    parse_env_file "$file" || return $?
    printf '%s' "${!var-}"
}

@test "basic fixture: unquoted, quoted, exported, comment and hash values" {
    run parse_and_print "$FIXTURES/basic.env" EC_PLAIN
    [ "$status" -eq 0 ]
    [ "$output" = "hello" ]

    run parse_and_print "$FIXTURES/basic.env" EC_QUOTED
    [ "$output" = "world # not a comment" ]

    run parse_and_print "$FIXTURES/basic.env" EC_EXPORTED
    [ "$output" = "yes" ]

    run parse_and_print "$FIXTURES/basic.env" EC_COMMENT
    [ "$output" = "abc" ]

    run parse_and_print "$FIXTURES/basic.env" EC_TRAIL
    [ "$output" = "spaced" ]

    run parse_and_print "$FIXTURES/basic.env" EC_HASH
    [ "$output" = "a#b" ]

    run parse_and_print "$FIXTURES/basic.env" EC_EMPTY
    [ "$output" = "" ]
}

@test "single quotes stay literal, double quotes expand \$HOME" {
    run parse_and_print "$FIXTURES/basic.env" EC_SINGLE
    [ "$output" = 'literal $NOTEXPANDED' ]

    run parse_and_print "$FIXTURES/expansion.env" EC_HOME_REF
    [ "$output" = "$HOME" ]

    run parse_and_print "$FIXTURES/expansion.env" EC_HOME_BRACED
    [ "$output" = "$HOME" ]
}

@test "expansion follows previous keys but leaves lowercase refs alone" {
    run parse_and_print "$FIXTURES/expansion.env" EC_SECOND
    [ "$output" = "base" ]

    run parse_and_print "$FIXTURES/expansion.env" EC_THIRD
    [ "$output" = "base/ext" ]

    run parse_and_print "$FIXTURES/expansion.env" EC_UNDEF_REF
    [ "$output" = "" ]

    run parse_and_print "$FIXTURES/expansion.env" EC_LOWER_REF
    [ "$output" = '$lower_stays_literal' ]
}

@test "multi-line quoted values keep embedded newlines" {
    run parse_and_print "$FIXTURES/multiline.env" EC_MULTI_D
    [ "$output" = $'line1\nline2' ]

    run parse_and_print "$FIXTURES/multiline.env" EC_MULTI_S
    [ "$output" = $'alpha\nbeta' ]

    run parse_and_print "$FIXTURES/multiline.env" EC_MULTI_C
    [ "$output" = $'x\ny' ]

    run parse_and_print "$FIXTURES/multiline.env" EC_AFTER
    [ "$output" = "tail" ]
}

@test "blocked variable names fail loudly" {
    run parse_env_file "$FIXTURES/blocked.env"
    [ "$status" -ne 0 ]
    [[ "$output" == *"blocked variable name 'PATH'"* ]]
}

@test "malformed lines fail loudly" {
    run parse_env_file "$FIXTURES/malformed.env"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Invalid env format"* ]]
}

@test "command substitution is rejected (direct and after expansion)" {
    run parse_env_file "$FIXTURES/inject.env"
    [ "$status" -ne 0 ]
    [[ "$output" == *"command substitution detected"* ]]

    export EC_INJECT_SRC='$(id)'
    run parse_env_file "$FIXTURES/inject_indirect.env"
    [ "$status" -ne 0 ]
    [[ "$output" == *"command substitution detected"* ]]
}

@test "unterminated quotes are rejected" {
    run parse_env_file "$FIXTURES/unterminated.env"
    [ "$status" -ne 0 ]
    [[ "$output" == *"unterminated quoted value"* ]]
}

@test "self-referential expansion is capped" {
    export EC_CYCLE_A='$EC_CYCLE_A'
    run parse_env_file "$FIXTURES/cycle.env"
    [ "$status" -ne 0 ]
    [[ "$output" == *"variable expansion limit exceeded"* ]]
}

@test "vault-encrypted files are rejected with a helpful message" {
    local vault="$BATS_TEST_TMPDIR/vault.env"
    printf '%s\n' '$ANSIBLE_VAULT;1.1;AES256' 'deadbeef' >"$vault"

    run parse_env_file "$vault"
    [ "$status" -ne 0 ]
    [[ "$output" == *"ansible-vault encrypted"* ]]
}
