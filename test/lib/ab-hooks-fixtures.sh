#!/usr/bin/env bash
prepare_none() { :; }

prepare_corrupt_config() {
    printf 'not json at all\n' > "$1/substrate.json"
}

prepare_symlink() {
    ln -s README.md "$1/link.md"
}

prepare_slop_file() {
    cat > "$1/slop.sh" <<'SH'
#!/usr/bin/env bash
printf 'setup\n'
# now we check the thing
printf 'hi\n'
SH
}

prepare_clean_file() {
    printf '#!/usr/bin/env bash\nprintf "hi\\n"\n' > "$1/clean.sh"
}

prepare_push_stub() {
    stub_push_gate "$1"
}

prepare_lifecycle_started() {
    printf '{"session_id":"%s"}\n' "$2" \
        | ( cd "$1" && bash .substrate/hooks/agent-lifecycle.sh start ) >/dev/null 2>&1
}

prepare_lifecycle_observed() {
    prepare_lifecycle_started "$@" || return 1
    printf 'printf "edited\\n"\n' >> "$1/owned.sh"
    printf '{"session_id":"%s"}\n' "$2" \
        | ( cd "$1" && bash .substrate/hooks/agent-lifecycle.sh observe ) >/dev/null 2>&1
}

prepare_lifecycle_pending() {
    prepare_lifecycle_observed "$@" || return 1
    stub_checkpoint "$1"
}

# The stub must be committed BEFORE the observe baseline (varied by env only) —
# committing after dirties the working copy, forcing AttemptCheckpoint false (internal/lifecycle/stop.go:52).
STUB_COMMIT='{"commit":"fedcba9876543210fedcba9876543210fedcba98","status":"passed"}'

seed_autockpt_stub() {
    cat > "$1/.substrate/checkpoint.sh" <<'SH'
#!/usr/bin/env bash
set -uo pipefail
if [ -n "${AB_STUB_ARGV:-}" ]; then
    mkdir -p "$(dirname "$AB_STUB_ARGV")"
    printf '%s\n' "$@" >> "$AB_STUB_ARGV"
fi
printf '%s\n' "${AB_STUB_LINE:-}"
exit "${AB_STUB_EXIT:-0}"
SH
    chmod +x "$1/.substrate/checkpoint.sh" || return 1
    (
        cd "$1" || exit 9
        if [ -d .jj ]; then
            jj commit -m 'chore: seed checkpoint stub'
        else
            git add -A && git commit -qm 'chore: seed checkpoint stub'
        fi
    ) >/dev/null 2>&1
}

# argv lands under .git/substrate so the frozen checkpoint grammar is compared
# across legs without dirtying the working copy the stop hook inspects
prepare_autockpt() {
    seed_autockpt_stub "$1" || return 1
    prepare_lifecycle_observed "$@" || return 1
    ab_watch .git/substrate/ab-argv
    ab_env "AB_STUB_ARGV=$1/.git/substrate/ab-argv"
}

prepare_autockpt_ok() {
    prepare_autockpt "$@" || return 1
    ab_env AB_STUB_EXIT=0 "AB_STUB_LINE=$STUB_COMMIT"
}

prepare_autockpt_fail() {
    prepare_autockpt "$@" || return 1
    ab_env AB_STUB_EXIT=1 'AB_STUB_LINE=gate red: 60-shellcheck.sh'
}

prepare_autockpt_noise() {
    prepare_autockpt "$@" || return 1
    ab_env AB_STUB_EXIT=0 'AB_STUB_LINE=not json at all'
}

prepare_zsh_slop() {
    cat > "$1/slop.zsh" <<'SH'
print -r -- setup
# now we check the thing
print -r -- hi
SH
}

prepare_zsh_heredoc() {
    cat > "$1/heredoc.zsh" <<'SH'
print -r -- start
cat <<'EOF'
# this hash sits inside a heredoc and is not a comment
EOF
print -r -- end
SH
}

prepare_yaml_slop() {
    cat > "$1/conf.yaml" <<'YML'
key: value
# now we set the other key
other: 2
YML
}

prepare_line_mixed() {
    prepare_zsh_slop "$1" || return 1
    prepare_yaml_slop "$1" || return 1
    prepare_zsh_heredoc "$1"
}

prepare_config_null() {
    printf 'null\n' > "$1/substrate.json"
}

prepare_config_false() {
    printf 'false\n' > "$1/substrate.json"
}

prepare_ratchet_config_null() {
    prepare_clean_file "$1" || return 1
    printf 'null\n' > "$1/substrate.json"
}

prepare_scan_config_null() {
    prepare_clean_file "$1" || return 1
    printf 'null\n' > "$1/substrate.json"
}

# the 5 prepare_* below vary only protected_paths/contracts within an
# otherwise-identical substrate.json; write_protected_config isolates that.
write_protected_config() {
    local dir="$1" protected="$2" contracts="${3:-[]}"
    {
        printf '{\n'
        printf '  "version": 1,\n'
        printf '  "profiles": ["base"],\n'
        printf '  "inventory": "auto",\n'
        printf '  "unscanned": ["*.md", "**/*.md", ".substrate/**", ".omp/**"],\n'
        printf '  "protected_paths": %s,\n' "$protected"
        printf '  "contracts": %s,\n' "$contracts"
        printf '  "comment": { "allow_tags": ["SAFETY:", "WHY:", "PERF:", "HACK:"] },\n'
        printf '  "budgets": { "max_file_lines": 500 },\n'
        printf '  "duplication": { "min_tokens": 35 },\n'
        printf '  "checks": { "disabled": [] }\n'
        printf '}\n'
    } > "$dir/substrate.json"
}

prepare_protected_nonstring() { write_protected_config "$1" '[42, "secrets/**"]'; }

prepare_protected_object() { write_protected_config "$1" '[{"pattern": "secrets/**"}]'; }

prepare_protected_newline() { write_protected_config "$1" '["evil\nsecrets/token.txt"]'; }

prepare_contract_globstar() {
    write_protected_config "$1" '[]' '[{"name": "api", "regen": "make api", "paths": ["generated/**"]}]'
}

prepare_ratchet_langmap_corrupt() {
    prepare_clean_file "$1" || return 1
    printf 'not json at all\n' > "$1/.substrate/langmap.json"
}

prepare_ratchet_langmap_null() {
    prepare_clean_file "$1" || return 1
    printf 'null\n' > "$1/.substrate/langmap.json"
}

prepare_ratchet_baseline_corrupt() {
    prepare_slop_file "$1" || return 1
    printf 'not json at all\n' > "$1/substrate-baseline.json"
}

prepare_ratchet_baseline_nonnumber() {
    prepare_slop_file "$1" || return 1
    cat > "$1/substrate-baseline.json" <<'JSON'
{
  "metrics": {"comments:slop.sh": "nope"},
  "direction": {}
}
JSON
}

prepare_ledger_mutate() {
    local repo="$1" session="$2" filter="$3" state
    prepare_lifecycle_observed "$repo" "$session" || return 1
    state="$repo/.git/substrate/agent-sessions/$session.json"
    [ -f "$state" ] || return 1
    jq -c "$filter" "$state" > "$state.tmp" && mv "$state.tmp" "$state"
}

prepare_ledger_initial_missing() { prepare_ledger_mutate "$1" "$2" 'del(.initial)'; }
prepare_ledger_initial_null()    { prepare_ledger_mutate "$1" "$2" '.initial = null'; }
prepare_ledger_initial_scalar()  { prepare_ledger_mutate "$1" "$2" '.initial = "not-an-object"'; }

prepare_ledger_truncated() {
    local state size
    prepare_lifecycle_observed "$1" "$2" || return 1
    state="$1/.git/substrate/agent-sessions/$2.json"
    [ -f "$state" ] || return 1
    size=$(wc -c < "$state") || return 1
    head -c $((size / 2)) "$state" > "$state.tmp" && mv "$state.tmp" "$state"
}

prepare_protected_posix_nonascii() { write_protected_config "$1" '["[[:alpha:]]*.secret"]'; }
