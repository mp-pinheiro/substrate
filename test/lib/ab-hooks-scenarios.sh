#!/usr/bin/env bash
pp() { printf '{"tool_input":{"file_path":"%s"}}' "$1"; }
pc() { printf '{"tool_input":{"command":%s},"session_id":"__SESSION__"}' "$1"; }
ab_known_divergence_reason() {
    case "$1" in
        lc-stop-ledger-truncated)
            printf 'structural limit: write_state now refuses an empty/non-object document, so bash'
            printf ' exits 2 and leaves the ledger byte-unchanged, matching Go on exit code and state.'
            printf ' Only stderr differs: bash leaks jq'"'"'s own diagnostic (e.g. `jq: error (at'
            printf ' <stdin>:1): Cannot index string with "revision"`), which Go has no jq subprocess'
            printf ' to emit and must not forge.'
            ;;
        *)
            return 1
            ;;
    esac
}

matrix() {
    hook_scenario pp-benign        hooks/protect-paths.sh "$(pp 'README.md')"                 jj prepare_none
    hook_scenario pp-baseline      hooks/protect-paths.sh "$(pp 'substrate-baseline.json')"   jj prepare_none
    hook_scenario pp-nested        hooks/protect-paths.sh "$(pp 'deep/substrate-baseline.json')" jj prepare_none
    hook_scenario pp-vendored      hooks/protect-paths.sh "$(pp 'substrate-engine gate')"        jj prepare_none
    hook_scenario pp-governance    hooks/protect-paths.sh "$(pp 'CLAUDE.md')"                 jj prepare_none
    hook_scenario pp-protected     hooks/protect-paths.sh "$(pp 'secrets/token.txt')"         jj prepare_none
    hook_scenario pp-symlink       hooks/protect-paths.sh "$(pp 'link.md')"                   jj prepare_symlink
    hook_scenario pp-corrupt       hooks/protect-paths.sh "$(pp 'README.md')"                 jj prepare_corrupt_config
    hook_scenario pp-nopath        hooks/protect-paths.sh '{"tool_input":{}}'                           jj prepare_none

    hook_scenario pc-benign        hooks/protect-command.sh "$(pc '"ls -la"')"                        jj prepare_none
    hook_scenario pc-commit        hooks/protect-command.sh "$(pc '"jj commit -m x"')"                jj prepare_none
    hook_scenario pc-gitcommit     hooks/protect-command.sh "$(pc '"git commit -m x"')"               jj prepare_none
    hook_scenario pc-vendored-ckpt hooks/protect-command.sh "$(pc '"substrate-engine checkpoint --x"')"  jj prepare_none
    hook_scenario pc-ckpt-nosess   hooks/protect-command.sh '{"tool_input":{"command":"substrate checkpoint --message x"}}' jj prepare_none
    hook_scenario pc-ckpt-badsess  hooks/protect-command.sh "$(pc '"substrate checkpoint --session other --message x"')" jj prepare_none
    hook_scenario pc-ckpt-ok       hooks/protect-command.sh "$(pc '"substrate checkpoint --session __SESSION__ --message x"')" jj prepare_none
    hook_scenario pc-baseline      hooks/protect-command.sh "$(pc '"echo x --update-baseline"')"      jj prepare_none
    hook_scenario pc-baseline-keyed hooks/protect-command.sh "$(pc '"substrate update --accept-regression=dup_pct"')" jj prepare_none
    hook_scenario pc-ckpt-accept     hooks/protect-command.sh "$(pc '"substrate checkpoint --session __SESSION__ --accept-regression=probe:alpha"')" jj prepare_none
    hook_scenario pc-ckpt-accept-chain hooks/protect-command.sh "$(pc '"substrate checkpoint --session __SESSION__ --accept-regression=a && substrate-engine gate --accept-regression=b"')" jj prepare_none
    hook_scenario pc-ckpt-procsub    hooks/protect-command.sh "$(pc '"substrate checkpoint --session __SESSION__ --accept-regression=a < <(substrate baseline --accept-regression)"')" jj prepare_none
    hook_scenario pc-ckpt-tighten    hooks/protect-command.sh "$(pc '"substrate checkpoint --session __SESSION__ --tighten"')" jj prepare_none
    hook_scenario pc-ckpt-trailingnl hooks/protect-command.sh "$(pc '"substrate checkpoint --session __SESSION__ --accept-regression=a\n"')" jj prepare_none
    hook_scenario pc-ckpt-u3000      hooks/protect-command.sh "$(pc '"substrate checkpoint --session __SESSION__ --accept-regression=a\u3000--tighten"')" jj prepare_none
    hook_scenario pc-verify-piped  hooks/protect-command.sh "$(pc '"substrate verify | tail -1"')"    jj prepare_none
    hook_scenario pc-verify-plain  hooks/protect-command.sh "$(pc '"substrate verify"')"              jj prepare_none
    hook_scenario pc-mutator       hooks/protect-command.sh "$(pc '"rm -rf .substrate"')"             jj prepare_none
    hook_scenario pc-redirect      hooks/protect-command.sh "$(pc '"echo x > substrate-baseline.json"')" jj prepare_none
    hook_scenario pc-redirect-argval hooks/protect-command.sh "$(pc '"gh issue comment 16 --body \"--reason=<text> mentions substrate-baseline.json in prose\""')" jj prepare_none
    hook_scenario pc-multiline     hooks/protect-command.sh "$(pc '"echo one\njj commit -m x"')"      jj prepare_none
    hook_scenario pc-multiline-ok  hooks/protect-command.sh "$(pc '"echo commit\necho jj"')"          jj prepare_none
    hook_scenario pc-corrupt       hooks/protect-command.sh "$(pc '"echo hi"')"                       jj prepare_corrupt_config

    hook_scenario jj-mutating      hooks/enforce-jj.sh "$(pc '"git add ."')"           jj prepare_none
    hook_scenario jj-readonly      hooks/enforce-jj.sh "$(pc '"git log --oneline"')"   jj prepare_none
    hook_scenario jj-push          hooks/enforce-jj.sh "$(pc '"git push origin main"')" jj prepare_none
    hook_scenario jj-push-tags     hooks/enforce-jj.sh "$(pc '"git push --tags"')"     jj prepare_none
    hook_scenario jj-git-push      hooks/enforce-jj.sh "$(pc '"jj git push"')"         jj prepare_none
    hook_scenario jj-plain-git     hooks/enforce-jj.sh "$(pc '"git add ."')"           git prepare_none

    hook_scenario cc-bad           hooks/enforce-conventional-commits.sh "$(pc '"jj commit -m \\"bad message\\""')" jj prepare_none
    hook_scenario cc-good          hooks/enforce-conventional-commits.sh "$(pc '"jj commit -m \\"fix(x): y\\""')"   jj prepare_none
    hook_scenario cc-nomessage     hooks/enforce-conventional-commits.sh "$(pc '"jj commit"')"                      jj prepare_none
    hook_scenario cc-plain-git     hooks/enforce-conventional-commits.sh "$(pc '"jj commit -m \\"bad\\""')"         git prepare_none

    hook_scenario gbp-skip         hooks/gate-before-push.sh "$(pc '"echo hi"')"            jj prepare_none
    hook_scenario gbp-remote       hooks/gate-before-push.sh "$(pc '"jj git push -R other"')" jj prepare_none
    hook_scenario gbp-blocked      hooks/gate-before-push.sh "$(pc '"jj git push"')"        jj prepare_push_stub
    hook_scenario gbp-receipt-hit  hooks/gate-before-push.sh "$(pc '"jj git push"')"        jj prepare_receipt_hit

    hook_scenario scan-clean       hooks/changed-files-scan.sh '{}' jj prepare_clean_file
    hook_scenario scan-slop        hooks/changed-files-scan.sh '{}' jj prepare_slop_file
    hook_scenario ratchet-clean    comment-ratchet.sh '' jj prepare_clean_file clean.sh
    hook_scenario ratchet-slop     comment-ratchet.sh '' jj prepare_slop_file  slop.sh
    hook_scenario ratchet-missing  comment-ratchet.sh '' jj prepare_none       nope.sh

    hook_scenario lc-start         hooks/agent-lifecycle.sh '{"session_id":"__SESSION__"}' jj prepare_none              start
    hook_scenario lc-observe-fresh hooks/agent-lifecycle.sh '{"session_id":"__SESSION__"}' jj prepare_none              observe
    hook_scenario lc-observe-owned hooks/agent-lifecycle.sh '{"session_id":"__SESSION__"}' jj prepare_lifecycle_observed observe
    hook_scenario lc-verify-none   hooks/agent-lifecycle.sh ''                             jj prepare_lifecycle_started verify ab-hooks-session
    hook_scenario lc-verify-owned  hooks/agent-lifecycle.sh ''                             jj prepare_lifecycle_observed verify ab-hooks-session
    hook_scenario lc-verify-missing hooks/agent-lifecycle.sh ''                            jj prepare_none              verify ab-hooks-session
    hook_scenario lc-complete-bad  hooks/agent-lifecycle.sh ''                             jj prepare_lifecycle_observed complete ab-hooks-session deadbeef
    hook_scenario lc-end           hooks/agent-lifecycle.sh '{"session_id":"__SESSION__"}' jj prepare_lifecycle_started end
    hook_scenario lc-usage         hooks/agent-lifecycle.sh ''                             jj prepare_none              bogus ab-hooks-session
    hook_scenario lc-badsession    hooks/agent-lifecycle.sh '{"session_id":"bad session!"}' jj prepare_none             start
    hook_scenario lc-stop-clean    hooks/agent-lifecycle.sh '{"session_id":"__SESSION__","stop_hook_active":false}' jj prepare_lifecycle_started stop
    hook_scenario lc-stop-owned    hooks/agent-lifecycle.sh '{"session_id":"__SESSION__","stop_hook_active":true}'  jj prepare_lifecycle_pending stop

    hook_scenario lc-stop-auto-ok    hooks/agent-lifecycle.sh '{"session_id":"__SESSION__","stop_hook_active":false}' jj prepare_autockpt_ok    stop
    hook_scenario lc-stop-auto-fail  hooks/agent-lifecycle.sh '{"session_id":"__SESSION__","stop_hook_active":false}' jj prepare_autockpt_fail  stop
    hook_scenario lc-stop-auto-noise hooks/agent-lifecycle.sh '{"session_id":"__SESSION__","stop_hook_active":false}' jj prepare_autockpt_noise stop

    # The langmap resolves .sh to AST mode; .zsh and .yaml route through the
    # line-mode classifier (linemode.go) instead.
    hook_scenario ratchet-zsh-slop    comment-ratchet.sh '' jj prepare_zsh_slop    slop.zsh
    hook_scenario ratchet-zsh-heredoc comment-ratchet.sh '' jj prepare_zsh_heredoc heredoc.zsh
    hook_scenario ratchet-yaml-slop   comment-ratchet.sh '' jj prepare_yaml_slop   conf.yaml
    hook_scenario scan-line-mixed     hooks/changed-files-scan.sh '{}' jj prepare_line_mixed

    hook_scenario scan-git-slop       hooks/changed-files-scan.sh '{}' git prepare_slop_file
    hook_scenario scan-git-line       hooks/changed-files-scan.sh '{}' git prepare_line_mixed
    hook_scenario lc-start-git        hooks/agent-lifecycle.sh '{"session_id":"__SESSION__"}' git prepare_none               start
    hook_scenario lc-observe-git      hooks/agent-lifecycle.sh '{"session_id":"__SESSION__"}' git prepare_lifecycle_observed observe
    hook_scenario lc-stop-auto-git    hooks/agent-lifecycle.sh '{"session_id":"__SESSION__","stop_hook_active":false}' git prepare_autockpt_ok stop

    # substrate.json as literal null/false — valid JSON that `jq -e` reads as falsy,
    # so bash's `! jq -e .` corruption check fires exactly like `not json at all` does.
    hook_scenario pp-config-null      hooks/protect-paths.sh    "$(pp 'README.md')"      jj prepare_config_null
    hook_scenario pp-config-false     hooks/protect-paths.sh    "$(pp 'README.md')"      jj prepare_config_false
    hook_scenario pc-config-null      hooks/protect-command.sh  "$(pc '"echo hi"')"      jj prepare_config_null
    # `generated/**` reaches blockIfNamed's needle regex, which RE2 rejects but GNU
    # grep accepts and matches; pp-contract-globstar covers a different code path.
    hook_scenario pc-contract-globstar hooks/protect-command.sh "$(pc '"echo hi"')" jj prepare_contract_globstar
    hook_scenario ratchet-config-null comment-ratchet.sh        ''                       jj prepare_ratchet_config_null clean.sh
    hook_scenario scan-config-null    hooks/changed-files-scan.sh '{}'                   jj prepare_scan_config_null

    # protected_paths with a non-string, an object, and a newline-containing element —
    # the newline splits `jq -r`'s NDJSON output into two case-glob lines, protecting an undeclared path.
    hook_scenario pp-protected-nonstring hooks/protect-paths.sh "$(pp 'secrets/foo.txt')"   jj prepare_protected_nonstring
    hook_scenario pp-protected-object    hooks/protect-paths.sh "$(pp 'secrets/foo.txt')"   jj prepare_protected_object
    hook_scenario pp-protected-newline   hooks/protect-paths.sh "$(pp 'secrets/token.txt')" jj prepare_protected_newline

    # contracts[].paths is matched as a literal string, not a glob — a
    # "generated/**" contract path must not swallow "generated/foo.js".
    hook_scenario pp-contract-globstar hooks/protect-paths.sh "$(pp 'generated/foo.js')" jj prepare_contract_globstar

    hook_scenario ratchet-langmap-corrupt comment-ratchet.sh '' jj prepare_ratchet_langmap_corrupt clean.sh
    hook_scenario ratchet-langmap-null    comment-ratchet.sh '' jj prepare_ratchet_langmap_null    clean.sh

    # corrupt substrate-baseline.json and a non-number metric — comment-ratchet.sh reads
    # `.metrics[$k]` directly and compares with `-gt`, where a non-number allowance actually bites.
    hook_scenario ratchet-baseline-corrupt   comment-ratchet.sh '' jj prepare_ratchet_baseline_corrupt   slop.sh
    hook_scenario ratchet-baseline-nonnumber comment-ratchet.sh '' jj prepare_ratchet_baseline_nonnumber slop.sh

    # A JSON \n / \u0000 escape is required here — a real NUL byte cannot survive a bash variable.
    hook_scenario pp-filepath-trailingnl hooks/protect-paths.sh "$(pp 'README.md\n')"             jj prepare_none
    hook_scenario pp-filepath-nul        hooks/protect-paths.sh "$(pp 'secrets\u0000token.txt')"   jj prepare_none

    hook_scenario pc-command-nul hooks/protect-command.sh "$(pc '"echo\u0000hi"')" jj prepare_none
    hook_scenario jj-command-nul hooks/enforce-jj.sh      "$(pc '"git\u0000push"')" jj prepare_none

    # Missing/null .initial is treated as empty and reaches auto-checkpoint, which blocks when its gate fails; scalar/truncated ledgers are rejected before checkpoint.
    hook_scenario lc-stop-ledger-noinitial    hooks/agent-lifecycle.sh '{"session_id":"__SESSION__","stop_hook_active":false}' jj prepare_ledger_initial_missing stop
    hook_scenario lc-stop-ledger-nullinitial  hooks/agent-lifecycle.sh '{"session_id":"__SESSION__","stop_hook_active":false}' jj prepare_ledger_initial_null    stop
    hook_scenario lc-stop-ledger-scalarinitial hooks/agent-lifecycle.sh '{"session_id":"__SESSION__","stop_hook_active":false}' jj prepare_ledger_initial_scalar stop
    hook_scenario lc-stop-ledger-truncated    hooks/agent-lifecycle.sh '{"session_id":"__SESSION__","stop_hook_active":false}' jj prepare_ledger_truncated       stop

    # Under en_US.UTF-8, GNU grep's [[:space:]] matches U+3000; under C, glibc's
    # [[:alpha:]] stops matching non-ASCII letters.
    hook_scenario jj-push-u3000  hooks/enforce-jj.sh    "$(pc '"git　push"')"     jj prepare_none
    hook_scenario pp-glob-nonascii hooks/protect-paths.sh "$(pp 'é.secret')" jj prepare_protected_posix_nonascii
}
