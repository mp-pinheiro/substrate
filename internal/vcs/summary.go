package vcs

import (
	"context"
	"fmt"
	"strings"

	"github.com/mp-pinheiro/substrate/internal/xshell"
)

type Change struct {
	Status string
	Path   string
}

func (r *Repo) ChangedSummary(ctx context.Context) ([]Change, error) {
	if r.Kind == KindJJ {
		return r.changedSummaryJJ(ctx)
	}
	return r.changedSummaryGit(ctx)
}

// WHY: bash drops "D" rows in the calling script, not in this collection
// step; every row is returned here so callers apply their own filter.
func (r *Repo) changedSummaryJJ(ctx context.Context) ([]Change, error) {
	res, err := xshell.RunInC(ctx, r.Root, "jj", "diff", "--summary", "--no-pager")
	if err != nil {
		return nil, fmt.Errorf("vcs: run jj diff --summary: %w", err)
	}
	var out []Change
	for _, line := range splitLines(string(res.Stdout)) {
		if line == "" {
			continue
		}
		status, path := splitStatusPath(line)
		out = append(out, Change{Status: status, Path: ResolveRename(path)})
	}
	return out, nil
}

func (r *Repo) changedSummaryGit(ctx context.Context) ([]Change, error) {
	res, err := xshell.RunInC(ctx, r.Root, "git", "status", "--porcelain", "-uall")
	if err != nil {
		return nil, fmt.Errorf("vcs: run git status: %w", err)
	}
	var out []Change
	for _, line := range splitLines(string(res.Stdout)) {
		if len(line) < 3 {
			continue
		}
		out = append(out, Change{Status: line[:2], Path: ResolveRename(line[3:])})
	}
	return out, nil
}

func splitStatusPath(line string) (string, string) {
	idx := strings.IndexByte(line, ' ')
	if idx < 0 {
		return line, line
	}
	return line[:idx], line[idx+1:]
}
