package receipt

import (
	"bytes"
	"context"
	"fmt"

	"github.com/mp-pinheiro/substrate/internal/vcs"
	"github.com/mp-pinheiro/substrate/internal/xshell"
)

func computeRepositoryHash(ctx context.Context, repo *vcs.Repo) (string, error) {
	paths, err := listRepositoryPaths(ctx, repo)
	if err != nil {
		return "", err
	}
	paths = dedupeSort(paths)
	return hashItems(paths, func(rel string) ([]byte, error) {
		return fileStateRecord(repo.Root, rel)
	})
}

func listRepositoryPaths(ctx context.Context, repo *vcs.Repo) ([]string, error) {
	if repo.Kind == vcs.KindJJ {
		res, err := xshell.RunInC(ctx, repo.Root, "jj", "file", "list", "-T", `path ++ "\0"`)
		if err != nil {
			return nil, fmt.Errorf("receipt: run jj file list: %w", err)
		}
		if res.Code != 0 {
			return nil, fmt.Errorf("receipt: jj file list exited %d", res.Code)
		}
		return splitNUL(res.Stdout), nil
	}
	res, err := xshell.RunInC(ctx, repo.Root, "git", "ls-files", "-z", "--cached")
	if err != nil {
		return nil, fmt.Errorf("receipt: run git ls-files: %w", err)
	}
	if res.Code != 0 {
		return nil, fmt.Errorf("receipt: git ls-files exited %d", res.Code)
	}
	return splitNUL(res.Stdout), nil
}

func splitNUL(b []byte) []string {
	b = bytes.TrimSuffix(b, []byte{0})
	if len(b) == 0 {
		return nil
	}
	parts := bytes.Split(b, []byte{0})
	out := make([]string, len(parts))
	for i, p := range parts {
		out[i] = string(p)
	}
	return out
}
