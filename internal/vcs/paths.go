package vcs

import (
	"context"
	"fmt"
	"sort"

	"github.com/mp-pinheiro/substrate/internal/xshell"
)

func (r *Repo) ChangedPaths(ctx context.Context) ([]string, string, error) {
	if r.Kind == KindJJ {
		return r.changedPathsJJ(ctx)
	}
	return r.changedPathsGit(ctx)
}

func (r *Repo) changedPathsJJ(ctx context.Context) ([]string, string, error) {
	res, err := xshell.RunInC(ctx, r.Root, "jj", "diff", "--name-only")
	if err != nil {
		return nil, "", fmt.Errorf("vcs: run jj diff: %w", err)
	}
	if res.Code != 0 {
		return nil, trimTrailingNewlines(string(res.Stderr)), nil
	}
	return sortUniqueLines(string(res.Stdout)), "", nil
}

// SAFETY: bash groups diff+ls-files under one 2> redirect and pipes to sort
// with pipefail; the group's exit status is ls-files' alone, so a failing
// diff with succeeding ls-files reports no error and diff's stderr is lost.
func (r *Repo) changedPathsGit(ctx context.Context) ([]string, string, error) {
	diffRes, err := xshell.RunInC(ctx, r.Root, "git", "diff", "--name-only", "--diff-filter=ACDMRTUXB", "HEAD", "--")
	if err != nil {
		return nil, "", fmt.Errorf("vcs: run git diff: %w", err)
	}
	lsRes, err := xshell.RunInC(ctx, r.Root, "git", "ls-files", "--others", "--exclude-standard")
	if err != nil {
		return nil, "", fmt.Errorf("vcs: run git ls-files: %w", err)
	}
	if lsRes.Code != 0 {
		combined := trimTrailingNewlines(string(diffRes.Stderr) + string(lsRes.Stderr))
		return nil, combined, nil
	}
	stdout := string(diffRes.Stdout) + string(lsRes.Stdout)
	return sortUniqueLines(stdout), "", nil
}

// WHY: Go's string `<` compares raw bytes, which is exactly LC_ALL=C order.
func sortUniqueLines(s string) []string {
	lines := splitLines(s)
	if len(lines) == 0 {
		return nil
	}
	sort.Strings(lines)
	out := lines[:1]
	for _, l := range lines[1:] {
		if l != out[len(out)-1] {
			out = append(out, l)
		}
	}
	return out
}
