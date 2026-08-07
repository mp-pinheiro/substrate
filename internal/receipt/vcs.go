package receipt

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"

	"github.com/mp-pinheiro/substrate/internal/vcs"
	"github.com/mp-pinheiro/substrate/internal/xshell"
)

// WHY: vcs.Detect silently downgrades .jj-without-jj to git; B5/H20 refuse.
func detectBackend(repoRoot string) (*vcs.Repo, error) {
	_, err := os.Stat(filepath.Join(repoRoot, ".jj"))
	if err != nil && !errors.Is(err, fs.ErrNotExist) {
		return nil, fmt.Errorf("receipt: stat .jj: %w", err)
	}
	if err == nil && !xshell.Have("jj") {
		return nil, refuse(ReasonJJUnresolvable)
	}
	repo, err := vcs.Detect(repoRoot)
	if err != nil {
		return nil, fmt.Errorf("receipt: detect vcs: %w", err)
	}
	return repo, nil
}

// WHY: git counts untracked files, jj does not — bash parity, not an oversight.
func workingCopyClean(ctx context.Context, repo *vcs.Repo) (bool, error) {
	if repo.Kind == vcs.KindJJ {
		res, err := xshell.RunInC(ctx, repo.Root, "jj", "diff", "--name-only")
		return statusEmpty(res, err, "jj diff")
	}
	res, err := xshell.RunInC(ctx, repo.Root, "git", "status", "--porcelain=v1", "--untracked-files=all")
	return statusEmpty(res, err, "git status")
}

// statusEmpty reports whether a status/diff subprocess's output is empty,
// i.e. the working copy is clean.
func statusEmpty(res xshell.Result, runErr error, label string) (bool, error) {
	if runErr != nil {
		return false, fmt.Errorf("receipt: run %s: %w", label, runErr)
	}
	if res.Code != 0 {
		return false, nil
	}
	return strings.TrimRight(string(res.Stdout), "\n") == "", nil
}
