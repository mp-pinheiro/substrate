package policy

import (
	"regexp"
	"strconv"
	"strings"
	"unicode/utf8"

	"github.com/mp-pinheiro/substrate/internal/config"
)

const bq = "`"

var (
	reVerifyMention  = regexp.MustCompile(`(^|[[:space:]/])substrate[[:space:]]+verify([[:space:];&|>]|$)`)
	reVerifyExact    = regexp.MustCompile(`^[[:space:]]*([^[:space:]]*/)?substrate[[:space:]]+verify[[:space:]]*$`)
	reCommitForms    = regexp.MustCompile(`(^|[;&|(` + bq + `][[:space:]]*)(jj[[:space:]]+(commit|describe|squash)|git[[:space:]]+commit)([[:space:]"\\]|$)`)
	reCheckpointSh   = regexp.MustCompile(`(^|[;&|(` + bq + `][[:space:]]*)[^[:space:]]*\.substrate/checkpoint\.sh([[:space:]"\\]|$)`)
	reCheckpointCmd  = regexp.MustCompile(`(^|[;&|][[:space:]]*|[[:space:]])substrate[[:space:]]+checkpoint([[:space:]]|$)`)
	reRestructureCmd = regexp.MustCompile(`(^|[;&|][[:space:]]*|[[:space:]])substrate[[:space:]]+restructure([[:space:]]|$)`)
	reRestructureSh  = regexp.MustCompile(`(^|[;&|(` + bq + `][[:space:]]*)[^[:space:]]*\.substrate/restructure\.sh([[:space:]"\\]|$)`)
	reBaselineFlags  = regexp.MustCompile(`(^|[[:space:]])(--update-baseline|--tighten|--accept-regression)([[:space:]]|$)`)
	reMutator        = regexp.MustCompile(`(^|[;&|][[:space:]]*|[[:space:]])(rm|mv|cp|install|chmod|chown|ln|touch|truncate|tee|dd)([[:space:]]|$)|perl([^;&|]*[[:space:]])-[^[:space:]]*i`)
	reTeeOrRedir     = regexp.MustCompile(`>>?[^;&|]*\$|tee[[:space:]][^;&|]*\$`)
)

func ProtectCommand(in Input, cfg *config.Config, configPresent, configCorrupt bool) Decision {
	cmd := in.Command
	if cmd == "" {
		return Decision{}
	}

	if matchAnyLine(reVerifyMention, cmd) && !matchAnyLine(reVerifyExact, cmd) {
		return block("BLOCKED: run substrate verify directly and unmodified; pipes, redirects, and chained commands can hide a failing verdict\n")
	}
	if matchAnyLine(reCommitForms, cmd) {
		return block("BLOCKED: commits must use the Substrate checkpoint transaction after direct verification; do not run jj commit, jj describe, jj squash, or git commit directly\n")
	}
	if matchAnyLine(reCheckpointSh, cmd) {
		return block("BLOCKED: invoke checkpoints through the harness lifecycle, not the vendored script directly\n")
	}
	if matchAnyLine(reCheckpointCmd, cmd) {
		if d, blocked := checkSessionBinding(in.SessionID, cmd, "checkpoint"); blocked {
			return d
		}
	}
	if matchAnyLine(reRestructureCmd, cmd) {
		if d, blocked := checkSessionBinding(in.SessionID, cmd, "restructure"); blocked {
			return d
		}
	}
	if matchAnyLine(reRestructureSh, cmd) {
		return block("BLOCKED: invoke restructures through the harness lifecycle, not the vendored script directly\n")
	}
	if matchAnyLine(reBaselineFlags, cmd) {
		return block("BLOCKED: baseline mutations are checkpoint-owned; initial debt or regressions require the user to run the explicit baseline command\n")
	}

	if configPresent && configCorrupt {
		return block("blocked: substrate.json is corrupt — fix it before running mutating Bash commands\n")
	}

	mutator := matchAnyLine(reMutator, cmd)

	if d, blocked := blockIfNamed(cmd, mutator, "substrate-baseline.json", "baseline — governed basename anywhere in the tree"); blocked {
		return d
	}
	if d, blocked := blockIfNamed(cmd, mutator, ".substrate", "vendored engine"); blocked {
		return d
	}
	if d, blocked := blockIfNamed(cmd, mutator, "CLAUDE.md", "governance"); blocked {
		return d
	}
	if configPresent && cfg != nil {
		for _, g := range cfg.ProtectedPaths {
			lit := literalPrefix(g)
			if lit == "" {
				continue
			}
			if d, blocked := blockIfNamed(cmd, mutator, lit, "protected_paths"); blocked {
				return d
			}
		}
		for _, c := range cfg.Contracts {
			for _, p := range c.Paths {
				if p == "" {
					continue
				}
				if d, blocked := blockIfNamed(cmd, mutator, p, "contract"); blocked {
					return d
				}
			}
		}
	}
	return Decision{}
}

func checkSessionBinding(session, cmd, kind string) (Decision, bool) {
	if !validSession(session) {
		return block("BLOCKED: Claude %s command has no valid lifecycle session\n", kind), true
	}
	if !matchAnyLine(sessionPattern(session), cmd) {
		return block("BLOCKED: Claude %s command must carry its current lifecycle session id\n", kind), true
	}
	return Decision{}, false
}

func validSession(s string) bool {
	if s == "" {
		return false
	}
	for _, r := range s {
		switch {
		case r >= 'A' && r <= 'Z', r >= 'a' && r <= 'z', r >= '0' && r <= '9', r == '.', r == '_', r == '-':
		default:
			return false
		}
	}
	return true
}

func sessionPattern(session string) *regexp.Regexp {
	return regexp.MustCompile(`--session([=[:space:]])['"]?` + regexp.QuoteMeta(session) + `(['"[:space:]]|$)`)
}

func blockIfNamed(cmd string, mutator bool, needle, label string) (Decision, bool) {
	if needle == "" {
		return Decision{}, false
	}
	if mutator && containsAnyLine(needle, cmd) {
		return block("BLOCKED: Bash command can mutate governed path %s (%s); use the protected workflow instead\n", needle, label), true
	}
	dotted := escapeDots(needle)
	if redirRe, ok := compileNeedleRegex(`>>?[[:space:]]*['"]?[^;&|]*` + dotted); ok && matchAnyLine(redirRe, cmd) {
		return block("BLOCKED: shell redirection targets governed path %s (%s)\n", needle, label), true
	}
	if assignRe, ok := compileNeedleRegex(`[A-Za-z_][A-Za-z0-9_]*=['"]?[^;&|]*` + dotted); ok && matchAnyLine(assignRe, cmd) && matchAnyLine(reTeeOrRedir, cmd) {
		return block("BLOCKED: indirect shell write resolves to governed path %s (%s)\n", needle, label), true
	}
	return Decision{}, false
}

func escapeDots(s string) string {
	return strings.ReplaceAll(s, ".", `\.`)
}

// needle is untrusted config text also matched by bash's live GNU grep -E (protect-command.sh).
// RE2 parses `x+?` as non-greedy one-or-more; GNU's stacked-repetition reading treats it as zero-or-more.
func compileNeedleRegex(pattern string) (*regexp.Regexp, bool) {
	normalized, ok := normalizeERE(pattern, true)
	if !ok {
		return nil, false
	}
	re, err := regexp.Compile(normalized)
	if err != nil {
		return nil, false
	}
	return re, true
}

// grep 3.11: a dangling repetition op (nothing to repeat) is silently dropped, but only at the top level
// (pattern start or after a top-level `|`); the same construct inside a group is a genuine parse error.
func normalizeERE(p string, topLevel bool) (string, bool) {
	var out strings.Builder
	lastAtomStart := -1
	hasRepeat := false
	i := 0
	for i < len(p) {
		c := p[i]
		if c == '|' {
			out.WriteByte('|')
			i++
			lastAtomStart = -1
			hasRepeat = false
			continue
		}
		if c == '(' {
			inner, closeIdx, ok := extractGroup(p, i)
			if !ok {
				return "", false
			}
			normInner, ok := normalizeERE(inner, false)
			if !ok {
				return "", false
			}
			start := out.Len()
			out.WriteString("(?:")
			out.WriteString(normInner)
			out.WriteByte(')')
			i = closeIdx + 1
			lastAtomStart = start
			hasRepeat = false
			continue
		}
		if op, newI, isOp, invalid := isRepeatOp(p, i); isOp {
			if invalid {
				if lastAtomStart < 0 {
					start, aNewI, ok := appendAtom(&out, p, i)
					if !ok {
						return "", false
					}
					lastAtomStart = start
					hasRepeat = false
					i = aNewI
					continue
				}
				return "", false
			}
			switch {
			case lastAtomStart < 0 && !topLevel:
				return "", false
			case lastAtomStart < 0:
				i = newI
				continue
			case hasRepeat:
				built := out.String()
				rebuilt := built[:lastAtomStart] + "(?:" + built[lastAtomStart:] + ")"
				out.Reset()
				out.WriteString(rebuilt)
				start := lastAtomStart
				out.WriteString(op)
				lastAtomStart = start
				hasRepeat = true
			default:
				out.WriteString(op)
				hasRepeat = true
			}
			i = newI
			continue
		}
		start, newI, ok := appendAtom(&out, p, i)
		if !ok {
			return "", false
		}
		lastAtomStart = start
		hasRepeat = false
		i = newI
	}
	return out.String(), true
}

func appendAtom(out *strings.Builder, p string, i int) (start, newI int, ok bool) {
	atom, ni, ok2 := nextAtom(p, i)
	if !ok2 {
		return 0, 0, false
	}
	start = out.Len()
	out.WriteString(atom)
	return start, ni, true
}

// escapes and bracket expressions are skipped so a paren inside `[()]` or `\(` doesn't shift the depth count.
func extractGroup(p string, open int) (inner string, closeIdx int, ok bool) {
	depth := 1
	i := open + 1
	for i < len(p) {
		switch p[i] {
		case '\\':
			if i+1 >= len(p) {
				return "", 0, false
			}
			i += 2
		case '[':
			end, bok := bracketEnd(p, i)
			if !bok {
				return "", 0, false
			}
			i = end
		case '(':
			depth++
			i++
		case ')':
			depth--
			if depth == 0 {
				return p[open+1 : i], i, true
			}
			i++
		default:
			i++
		}
	}
	return "", 0, false
}

// POSIX: a `]` immediately after `[` or `[^` is a literal member, not the closing bracket.
// `[:class:]`, `[.coll.]`, `[=equiv=]` sub-expressions are skipped so their inner `]` isn't read as closing.
func bracketEnd(p string, i int) (int, bool) {
	j := i + 1
	if j < len(p) && p[j] == '^' {
		j++
	}
	if j < len(p) && p[j] == ']' {
		j++
	}
	for j < len(p) {
		if p[j] == '[' && j+1 < len(p) && (p[j+1] == ':' || p[j+1] == '.' || p[j+1] == '=') {
			marker := p[j+1]
			rest := strings.Index(p[j+2:], string(marker)+"]")
			if rest < 0 {
				return 0, false
			}
			j = j + 2 + rest + 2
			continue
		}
		if p[j] == ']' {
			return j + 1, true
		}
		j++
	}
	return 0, false
}

// grep 3.11: `x{}y`,`x{2,1}y` are valid syntax but fail at match time; `x{,}y` alone acts like `x*y`.
func isRepeatOp(p string, i int) (op string, newI int, isOp bool, invalid bool) {
	switch p[i] {
	case '*', '+', '?':
		return p[i : i+1], i + 1, true, false
	case '{':
		j := i + 1
		mStart := j
		for j < len(p) && p[j] >= '0' && p[j] <= '9' {
			j++
		}
		mText := p[mStart:j]
		hasComma := j < len(p) && p[j] == ','
		nText := ""
		if hasComma {
			j++
			nStart := j
			for j < len(p) && p[j] >= '0' && p[j] <= '9' {
				j++
			}
			nText = p[nStart:j]
		}
		if j >= len(p) || p[j] != '}' {
			return "", 0, false, false
		}
		end := j + 1
		if mText == "" && !hasComma {
			return p[i:end], end, true, true
		}
		if mText != "" && nText != "" {
			m, _ := strconv.Atoi(mText)
			n, _ := strconv.Atoi(nText)
			if m > n {
				return p[i:end], end, true, true
			}
		}
		return p[i:end], end, true, false
	default:
		return "", 0, false, false
	}
}

// `\w\W\s\S\b\B` are escapes RE2/GNU agree on; other GNU letter-escapes are literal-only, rejected by RE2.
// `\d` is the exception: a digit class in RE2, literal in GNU. A stray `)` here is literal too (GNU: `ab)c`).
func nextAtom(p string, i int) (string, int, bool) {
	switch p[i] {
	case '\\':
		if i+1 >= len(p) {
			return "", 0, false
		}
		esc := p[i+1]
		if isLetter(esc) && !strings.ContainsRune("wWsSbB", rune(esc)) {
			return p[i+1 : i+2], i + 2, true
		}
		return p[i : i+2], i + 2, true
	case ')':
		return `\)`, i + 1, true
	case '[':
		end, ok := bracketEnd(p, i)
		if !ok {
			return "", 0, false
		}
		return p[i:end], end, true
	default:
		_, size := utf8.DecodeRuneInString(p[i:])
		return p[i : i+size], i + size, true
	}
}

func isLetter(b byte) bool {
	return (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z')
}

func literalPrefix(pattern string) string {
	idx := strings.IndexAny(pattern, "*?[")
	if idx < 0 {
		return pattern
	}
	return pattern[:idx]
}
