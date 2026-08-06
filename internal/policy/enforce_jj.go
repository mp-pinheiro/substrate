package policy

import (
	"os"
	"path/filepath"
	"regexp"
)

var (
	reJJGit     = regexp.MustCompile(`jj\s+git`)
	reGitMutate = regexp.MustCompile(`git[[:space:]]+(commit|add|rebase|merge|reset|restore|switch|checkout|cherry-pick|revert|stash|clean|am|apply)([[:space:]"\\]|$)`)
	reGitPush   = regexp.MustCompile(`git[[:space:]]+push`)
	reTagPush   = regexp.MustCompile(`(--tags|[[:space:]]v[0-9])`)
)

func isJJRepo(repoRoot string) bool {
	info, err := os.Stat(filepath.Join(repoRoot, ".jj"))
	return err == nil && info.IsDir()
}

// WHY: jq's oniguruma \s matches \n like RE2's, so this gsub runs on the
// whole command, not per line, before the per-line guards below.
func EnforceJJ(in Input, repoRoot string) Decision {
	if !isJJRepo(repoRoot) {
		return Decision{}
	}
	cmd := reJJGit.ReplaceAllString(in.Command, "JJ_GIT")
	if cmd == "" {
		return Decision{}
	}
	if matchAnyLine(reGitMutate, cmd) {
		return block("BLOCKED: this repo is jj-managed — use jj, not git, for VCS changes: 'jj commit -m', 'jj tug', 'jj git push' (see docs/jj-workflow.md). Read-only git (log/status/diff/show) and release 'git tag' are fine.\n")
	}
	if matchAnyLine(reGitPush, cmd) {
		if matchAnyLine(reTagPush, cmd) {
			return Decision{}
		}
		return block("BLOCKED: use 'jj git push', not 'git push', in this jj-managed repo (release tags are the exception: 'git push origin vX.Y.Z'). See docs/jj-workflow.md.\n")
	}
	return Decision{}
}
