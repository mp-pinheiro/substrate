package vcs

import (
	"context"
	"fmt"

	"github.com/mp-pinheiro/substrate/internal/xshell"
)

func (r *Repo) Revision(ctx context.Context) (string, string, error) {
	if r.Kind == KindJJ {
		return r.probeRevision(ctx, "jj", "log", "-r", "@-", "--no-graph", "-T", "commit_id")
	}
	return r.probeRevision(ctx, "git", "rev-parse", "HEAD")
}

func (r *Repo) probeRevision(ctx context.Context, name string, args ...string) (string, string, error) {
	res, err := xshell.RunInC(ctx, r.Root, name, args...)
	if err != nil {
		return "", "", fmt.Errorf("vcs: run %s: %w", name, err)
	}
	combined := trimTrailingNewlines(string(res.Stdout) + string(res.Stderr))
	if res.Code != 0 {
		return combined, combined, nil
	}
	return combined, "", nil
}

func (r *Repo) ChangeIDFor(ctx context.Context, commit string) (string, error) {
	res, err := xshell.RunInC(ctx, r.Root, "jj", "log", "-r", commit, "--no-graph", "-T", "change_id")
	if err != nil || res.Code != 0 {
		return "", nil
	}
	return trimTrailingNewlines(string(res.Stdout)), nil
}
