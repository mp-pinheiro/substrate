package policy

var (
	reJJCommitForms = compileLocaleRegexp("(^|[;&|(`][[:space:]]*)jj[[:space:]]+(commit|describe|squash)([[:space:]]|$)")
	reMessageFlag   = compileLocaleRegexp(`(-m|--message)([[:space:]=])`)
	reConventional  = compileLocaleRegexp(`(-m|--message)[[:space:]=]+["']?(feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert)(\([^)]+\))?!?:[[:space:]]`)
)

func EnforceConventionalCommits(in Input, repoRoot string) Decision {
	if !isJJRepo(repoRoot) {
		return Decision{}
	}
	cmd := in.Command
	if cmd == "" {
		return Decision{}
	}
	if !reJJCommitForms.match(cmd) {
		return Decision{}
	}
	if !reMessageFlag.match(cmd) {
		return Decision{}
	}
	if !reConventional.match(cmd) {
		return block("BLOCKED: commit message must follow Conventional Commits — 'type(scope): subject'. Types: feat, fix, docs, style, refactor, perf, test, build, ci, chore, revert (append ! for breaking). Example: jj commit -m 'feat(auth): add login'.\n")
	}
	return Decision{}
}
