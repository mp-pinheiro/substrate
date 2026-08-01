#!/usr/bin/env bash
# Comment-slop detector. Dispatch per file via LANGMAP:
#   ast    — ast-grep comment nodes decide what counts as a comment (strings/heredocs immune)
#   line   — marker scanner extracts the comment SUBSTRING (quotes, block comments, heredocs honored)
#   exempt — another tool owns the file type
# Files claim by extension, or by shebang for extensionless executables. Unclaimed
# files are skipped here; check 05-unclaimed-source owns that policy.
# Usage:
#   check-comments.sh FILE...
#   check-comments.sh --stdin NAME      scan stdin, NAME selects dispatch and labels the report
# Exit: 0 clean, 1 findings, 3 infrastructure failure (fail closed).
# Escape hatch: append `gate:allow-comment` to a flagged line.
set -uo pipefail

: "${LANGMAP:?LANGMAP not set}"
: "${CONFIG:?CONFIG not set}"

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=gate-lib.sh
source "$SELF_DIR/gate-lib.sh"

jq -e . "$LANGMAP" >/dev/null 2>&1 || { echo "comment gate: langmap missing or corrupt: $LANGMAP" >&2; exit 3; }
jq -e . "$CONFIG" >/dev/null 2>&1 || { echo "comment gate: config missing or corrupt: $CONFIG" >&2; exit 3; }

PATTERNS_NAMES=(
    restates-code
    narration
    step-numbering
)
PATTERNS_TPL=(
    '(^|[[:space:]])%M%[[:space:]]*(fetch|get|set|create|update|delete|initialise|initialize|loop|iterate|check|validate|return|call|add|remove|handle|process|parse|build|render|start|stop|store|save|load|print|log|convert|ensure|apply|execute)[[:space:]]+[[:alnum:]]'
    "(^|[[:space:]])%M%[[:space:]]*(we[[:space:]]|let'?s[[:space:]]|now[[:space:]]|then[[:space:]]|note that|here we|this (is|will|does|function|method|block)|as (mentioned|noted|described|above))"
    '(^|[[:space:]])%M%[[:space:]]*(step[[:space:]]*[0-9]|[0-9]+\.[[:space:]]+[[:alnum:]])'
)
BANNER_TPL='^[[:space:]]*%M%[[:space:]]*[=*_~-]{3,}'
TODO_TPL='(^|[[:space:]])%M%[[:space:]]*(todo|fixme|xxx|placeholder|for now|temporar|stub[[:space:]:])'
CAUSAL_REGEX="because|so that|since[[:space:]]|otherwise|prevents|refuses|needs|requires|doesn'?t|does not|won'?t|can'?t|cannot|\("

declare -A AST_SET=()
SG=()

resolve_sg() {
    if command -v ast-grep >/dev/null 2>&1; then
        SG=(ast-grep)
    elif command -v bunx >/dev/null 2>&1; then
        SG=(bunx --yes @ast-grep/cli@0.45.0)
    fi
}

ALLOW_TAGS_REGEX=""
load_allow_tags() {
    local tags
    tags=$(jq -r '(.comment.allow_tags // ["SAFETY:","WHY:","PERF:","HACK:"]) | join("|")' "$CONFIG") || tags=""
    [ -n "$tags" ] && ALLOW_TAGS_REGEX="^[[:space:]]*(${tags})"
}

is_exempt() {
    local text="$1"
    [[ "$text" == '#!'* ]] && return 0
    [[ "$text" =~ gate:allow- ]] && return 0
    [[ "$text" =~ ^[[:space:]]*#[[:space:]]*shellcheck ]] && return 0
    [[ "$text" =~ SPDX-License-Identifier ]] && return 0
    local lower="${text,,}"
    # jj-style sanctioned deprecation marker: "TODO: remove in <version>"
    [[ "$lower" =~ todo:?[[:space:]]remove[[:space:]]in[[:space:]] ]] && return 0
    if [ -n "$ALLOW_TAGS_REGEX" ]; then
        local stripped="${text#"${text%%[!\#/\- ]*}"}"
        [[ "$stripped" =~ $ALLOW_TAGS_REGEX ]] && return 0
    fi
    return 1
}

canonical_ext() {
    case "$1" in
        bash) echo ".sh" ;;
        typescript) echo ".ts" ;;
        javascript) echo ".js" ;;
        go) echo ".go" ;;
        lua) echo ".lua" ;;
        python) echo ".py" ;;
        cpp) echo ".cpp" ;;
        yaml) echo ".yml" ;;
        *) echo ".txt" ;;
    esac
}

# populate AST_SET["path|line"] for all ast-mode files, one ast-grep pass per grammar.
# ast-grep selects files by extension, so extensionless (shebang-claimed) files are
# scanned through a canonical-extension tmp copy and mapped back.
extract_ast() {
    local -A by_lang=()
    local f entry lang
    for f in "$@"; do
        entry=$(lang_entry "$f")
        [ -n "$entry" ] || continue
        [ "$(jq -r '.mode' <<< "$entry")" = "ast" ] || continue
        lang=$(jq -r '.ast_lang' <<< "$entry")
        if [ -z "$lang" ] || [ "$lang" = "null" ]; then
            printf 'langmap: ast mode without ast_lang for %s\n' "$f" >&2
            exit 3
        fi
        by_lang[$lang]+="$f"$'\n'
    done
    [ ${#by_lang[@]} -eq 0 ] && return 0

    if [ ${#SG[@]} -eq 0 ]; then
        printf 'comment gate: ast-grep unavailable (install ast-grep, or bun for bunx) — refusing to scan AST-mode files blind\n' >&2
        exit 3
    fi

    local tmpdir
    tmpdir=$(mktemp -d)
    local -A tmpmap=()
    local rule extraction file line scanlist base t cext
    for lang in "${!by_lang[@]}"; do
        scanlist=""
        while IFS= read -r f; do
            [ -n "$f" ] || continue
            base=$(basename "$f")
            case "$base" in
                *.*) scanlist+="$f"$'\n' ;;
                *)
                    cext=$(canonical_ext "$lang")
                    t="$tmpdir/$(printf '%s' "$f" | tr '/' '_')$cext"
                    cp "$f" "$t" || { rm -rf "$tmpdir"; printf 'comment gate: tmp copy failed for %s\n' "$f" >&2; exit 3; }
                    tmpmap[$t]="$f"
                    scanlist+="$t"$'\n'
                    ;;
            esac
        done <<< "${by_lang[$lang]}"

        rule="id: c
language: $lang
rule: {kind: comment}"
        if ! extraction=$(printf '%s' "$scanlist" \
            | xargs -r "${SG[@]}" scan --inline-rules "$rule" --json=compact \
            | jq -r '.[] | "\(.file)\t\(.range.start.line + 1)"'); then
            rm -rf "$tmpdir"
            printf 'comment gate: ast-grep extraction failed for %s — refusing to scan blind\n' "$lang" >&2
            exit 3
        fi
        while IFS=$'\t' read -r file line; do
            [ -n "$file" ] || continue
            AST_SET["${tmpmap[$file]:-$file}|$line"]=1
        done <<< "$extraction"
    done
    rm -rf "$tmpdir"
}

# ---- line-mode extraction ------------------------------------------------
# Globals set per file by lm_setup: LM_MARKERS (array), LM_BO/LM_BC (block pair), LM_HEREDOC (0/1)
# Globals set per line by lm_scan: LC_TEXT (comment substring, "" when none),
# LC_FROM_BLOCK, and state LM_IN_BLOCK / LM_HD_TAG carried across lines.
LM_MARKERS=()
LM_BO=""
LM_BC=""
LM_HEREDOC=0
LM_IN_BLOCK=0
LM_HD_TAG=""
LC_TEXT=""
LC_FROM_BLOCK=0

lm_setup() {
    local entry="$1"
    mapfile -t LM_MARKERS < <(jq -r '(.markers // [])[]' <<< "$entry")
    LM_BO=$(jq -r '(.block // [])[0][0] // empty' <<< "$entry")
    LM_BC=$(jq -r '(.block // [])[0][1] // empty' <<< "$entry")
    LM_HEREDOC=$(jq -r 'if .heredoc == true then 1 else 0 end' <<< "$entry")
    LM_IN_BLOCK=0
    LM_HD_TAG=""
}

lm_scan() {
    local line="$1"
    LC_TEXT=""
    LC_FROM_BLOCK=0

    if [ -n "$LM_HD_TAG" ]; then
        local trimmed="${line#"${line%%[![:space:]]*}"}"
        [ "$trimmed" = "$LM_HD_TAG" ] && LM_HD_TAG=""
        return 0
    fi

    if [ "$LM_IN_BLOCK" -eq 1 ]; then
        LC_FROM_BLOCK=1
        case "$line" in
            *"$LM_BC"*)
                LC_TEXT="${line%%"$LM_BC"*}"
                LM_IN_BLOCK=0
                ;;
            *) LC_TEXT="$line" ;;
        esac
        return 0
    fi

    # fast path: nothing comment-, quote-, or heredoc-like on the line
    local probe=0 m
    for m in ${LM_MARKERS[@]+"${LM_MARKERS[@]}"}; do
        case "$line" in *"$m"*) probe=1 ;; esac
    done
    [ -n "$LM_BO" ] && case "$line" in *"$LM_BO"*) probe=1 ;; esac
    [ "$LM_HEREDOC" -eq 1 ] && case "$line" in *"<<"*) probe=1 ;; esac
    [ "$probe" -eq 0 ] && return 0

    local i=0 n=${#line} c in_s=0 in_d=0 mlen
    while [ "$i" -lt "$n" ]; do
        c="${line:$i:1}"
        if [ "$in_s" -eq 1 ]; then
            [ "$c" = "'" ] && in_s=0
            i=$((i + 1)); continue
        fi
        if [ "$in_d" -eq 1 ]; then
            if [ "$c" = '\' ]; then i=$((i + 2)); continue; fi
            [ "$c" = '"' ] && in_d=0
            i=$((i + 1)); continue
        fi
        case "$c" in
            "'") in_s=1; i=$((i + 1)); continue ;;
            '"') in_d=1; i=$((i + 1)); continue ;;
        esac
        if [ "$LM_HEREDOC" -eq 1 ] && [ "${line:$i:2}" = "<<" ]; then
            local rest="${line:$((i + 2))}"
            rest="${rest#-}"
            rest="${rest#"${rest%%[![:space:]]*}"}"
            rest="${rest#\"}"; rest="${rest#\'}"
            local tag="${rest%%[!A-Za-z0-9_]*}"
            if [ -n "$tag" ]; then
                LM_HD_TAG="$tag"
                return 0
            fi
            i=$((i + 2)); continue
        fi
        if [ -n "$LM_BO" ] && [ "${line:$i:${#LM_BO}}" = "$LM_BO" ]; then
            local body="${line:$((i + ${#LM_BO}))}"
            LC_FROM_BLOCK=1
            case "$body" in
                *"$LM_BC"*) LC_TEXT="${body%%"$LM_BC"*}" ;;
                *) LC_TEXT="$body"; LM_IN_BLOCK=1 ;;
            esac
            return 0
        fi
        for m in ${LM_MARKERS[@]+"${LM_MARKERS[@]}"}; do
            mlen=${#m}
            if [ "${line:$i:$mlen}" = "$m" ]; then
                LC_TEXT="${line:$i}"
                return 0
            fi
        done
        i=$((i + 1))
    done
    return 0
}

# ---- classifier ----------------------------------------------------------
build_regexes() {
    local markers_alt="$1" i
    BANNER_REGEX="${BANNER_TPL//%M%/$markers_alt}"
    TODO_REGEX="${TODO_TPL//%M%/$markers_alt}"
    PATTERNS_REGEX=()
    for i in "${!PATTERNS_TPL[@]}"; do
        PATTERNS_REGEX+=("${PATTERNS_TPL[$i]//%M%/$markers_alt}")
    done
}

scan_file() {
    local path="$1" name="$2" entry="$3"
    local mode markers_alt findings=0 lineno=0 prose_run=0 prose_start=0
    local code_seen=0 run_exempt=0 prev_fullline=0 last_code_was_funcdef=0
    local line comment ctext lower fullline i trimmed_line trimmed_comment

    mode=$(jq -r '.mode' <<< "$entry")
    [ "$mode" = "exempt" ] && return 0

    markers_alt=$(jq -r '(.markers // ["#"]) | map(select(length > 0)) | join("|") | gsub("\\*"; "\\\\*")' <<< "$entry")
    [ -n "$markers_alt" ] || markers_alt="#"
    build_regexes "($markers_alt)"
    [ "$mode" = "line" ] && lm_setup "$entry"

    while IFS= read -r line || [ -n "$line" ]; do
        lineno=$((lineno + 1))

        comment=""
        LC_FROM_BLOCK=0
        if [ "$mode" = "ast" ]; then
            [ -n "${AST_SET[$path|$lineno]:-}" ] && comment="$line"
        else
            lm_scan "$line"
            comment="$LC_TEXT"
        fi

        if [ -n "$comment" ] && is_exempt "$comment"; then
            prose_run=0
            prev_fullline=1
            continue
        fi

        fullline=0
        if [ -n "$comment" ]; then
            if [ "$mode" = "ast" ]; then
                [[ "$line" =~ ^[[:space:]]*($markers_alt) ]] && fullline=1
            else
                trimmed_line="${line#"${line%%[![:space:]]*}"}"
                trimmed_comment="${comment#"${comment%%[![:space:]]*}"}"
                [ "$trimmed_line" = "$trimmed_comment" ] && fullline=1
                [[ "$trimmed_line" =~ ^($markers_alt) ]] && fullline=1
                if [ -n "$LM_BO" ]; then
                    case "$trimmed_line" in "$LM_BO"*) fullline=1 ;; esac
                fi
            fi
        fi
        if [ "$fullline" -eq 0 ] && [[ "$line" =~ [^[:space:]] ]]; then
            code_seen=1
            last_code_was_funcdef=0
            [[ "$line" =~ ^[[:alnum:]_-]+[[:space:]]*\(\)[[:space:]]*\{ ]] && last_code_was_funcdef=1
        fi

        if [ -n "$comment" ]; then
            ctext="$comment"
            if [ "$LC_FROM_BLOCK" -eq 1 ] && [ ${#LM_MARKERS[@]} -gt 0 ]; then
                ctext="${LM_MARKERS[0]} ${comment#"${comment%%[![:space:]]*}"}"
            fi
            lower="${ctext,,}"
            if [[ "$lower" =~ $BANNER_REGEX ]] || [[ "$lower" =~ ^[[:space:]]*[=*_~-]{4,}[[:space:]]*$ ]]; then
                printf '%s:%d: banner: %s\n' "$name" "$lineno" "$line"
                findings=$((findings + 1))
            elif [[ "$lower" =~ $TODO_REGEX ]]; then
                printf '%s:%d: todo-chatter: %s\n' "$name" "$lineno" "$line"
                findings=$((findings + 1))
            elif [ "$fullline" -eq 0 ] || [ "$prev_fullline" -eq 0 ]; then
                # semantic checks skip continuation lines: wrapped prose belongs to prose-block
                for i in "${!PATTERNS_REGEX[@]}"; do
                    if [[ "$lower" =~ ${PATTERNS_REGEX[$i]} ]]; then
                        if [ "${PATTERNS_NAMES[$i]}" = "restates-code" ] && [[ "$lower" =~ $CAUSAL_REGEX ]]; then
                            continue
                        fi
                        printf '%s:%d: %s: %s\n' "$name" "$lineno" "${PATTERNS_NAMES[$i]}" "$line"
                        findings=$((findings + 1))
                        break
                    fi
                done
            fi
        fi

        if [ "$fullline" -eq 1 ] && [[ "$comment" =~ [[:alnum:]] ]]; then
            if [ "$prose_run" -eq 0 ]; then
                prose_start=$lineno
                run_exempt=0
                if [ "$code_seen" -eq 0 ] || [ "$last_code_was_funcdef" -eq 1 ]; then
                    run_exempt=1
                fi
            fi
            prose_run=$((prose_run + 1))
            if [ "$prose_run" -eq 3 ] && [ "$run_exempt" -eq 0 ]; then
                printf '%s:%d: prose-block: 3+ consecutive comment lines starting here\n' "$name" "$prose_start"
                findings=$((findings + 1))
            fi
        else
            prose_run=0
        fi
        prev_fullline=$fullline
    done < "$path"
    return "$((findings > 0 ? 1 : 0))"
}

main() {
    local rc=0
    resolve_sg
    load_allow_tags
    if [ "${1:-}" = "--stdin" ]; then
        local name="${2:-}"
        [ -n "$name" ] || return 0
        local entry
        entry=$(lang_entry "$name")
        [ -n "$entry" ] || return 0
        local tmp ext=""
        case "$(basename "$name")" in *.*) ext=".${name##*.}" ;; esac
        tmp=$(mktemp)
        if [ -n "$ext" ]; then
            mv "$tmp" "$tmp$ext"
            tmp="$tmp$ext"
        fi
        cat > "$tmp"
        extract_ast "$tmp"
        scan_file "$tmp" "$name" "$entry" || rc=$?
        rm -f "$tmp"
        [ "$rc" -ge 2 ] && exit "$rc"
    else
        local files=() entries=() f entry
        for f in "$@"; do
            [ -f "$f" ] || continue
            entry=$(lang_entry "$f")
            [ -n "$entry" ] || continue
            files+=("$f")
            entries+=("$entry")
        done
        [ ${#files[@]} -eq 0 ] && return 0
        extract_ast "${files[@]}"
        local i scan_rc
        for i in "${!files[@]}"; do
            scan_file "${files[$i]}" "${files[$i]}" "${entries[$i]}"
            scan_rc=$?
            [ "$scan_rc" -ge 2 ] && exit "$scan_rc"
            [ "$scan_rc" -eq 1 ] && rc=1
        done
    fi
    if [ "$rc" -eq 1 ]; then
        printf '\ncomment gate: remove the flagged comments or encode the fact in names/structure.\n'
        printf 'A rare, genuinely non-obvious fact may stay: append "gate:allow-comment" to the line.\n'
    fi
    return "$rc"
}

main "$@"
