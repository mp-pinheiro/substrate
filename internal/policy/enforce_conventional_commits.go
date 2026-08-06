package policy

import "regexp"

var (
	reJJCommitForms = regexp.MustCompile("(^|[;&|(`][[:space:]]*)jj[[:space:]]+(commit|describe|squash)([[:space:]]|$)")
	reMessageFlag   = regexp.MustCompile(`(-m|--message)([[:space:]=])`)
	reConventional  = regexp.MustCompile(`(-m|--message)[[:space:]=]+["']?(feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert)(\([^)]+\))?!?:[[:space:]]`)
)

func EnforceConventionalCommits(in Input, repoRoot string) Decision {
	if !isJJRepo(repoRoot) {
		return Decision{}
	}
	cmd := in.Command
	if cmd == "" {
		return Decision{}
	}
	if !matchAnyLine(reJJCommitForms, cmd) {
		return Decision{}
	}
	if !matchAnyLine(reMessageFlag, cmd) {
		return Decision{}
	}
	if !matchAnyLine(reConventional, cmd) {
		return block("BLOCKED: commit message must follow Conventional Commits — 'type(scope): subject'. Types: feat, fix, docs, style, refactor, perf, test, build, ci, chore, revert (append ! for breaking). Example: jj commit -m 'feat(auth): add login'.\n")
	}
	return Decision{}
}
