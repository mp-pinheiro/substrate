package policy

import (
	"regexp"
	"strings"

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
	redirRe := regexp.MustCompile(`>>?[[:space:]]*['"]?[^;&|]*` + dotted)
	if matchAnyLine(redirRe, cmd) {
		return block("BLOCKED: shell redirection targets governed path %s (%s)\n", needle, label), true
	}
	assignRe := regexp.MustCompile(`[A-Za-z_][A-Za-z0-9_]*=['"]?[^;&|]*` + dotted)
	if matchAnyLine(assignRe, cmd) && matchAnyLine(reTeeOrRedir, cmd) {
		return block("BLOCKED: indirect shell write resolves to governed path %s (%s)\n", needle, label), true
	}
	return Decision{}, false
}

func escapeDots(s string) string {
	return strings.ReplaceAll(s, ".", `\.`)
}

func literalPrefix(pattern string) string {
	idx := strings.IndexAny(pattern, "*?[")
	if idx < 0 {
		return pattern
	}
	return pattern[:idx]
}
