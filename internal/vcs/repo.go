package vcs

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"

	"github.com/mp-pinheiro/substrate/internal/xshell"
)

type Kind string

const (
	KindJJ  Kind = "jj"
	KindGit Kind = "git"
)

type Repo struct {
	Root string
	Kind Kind
}

func Detect(root string) (*Repo, error) {
	jjPath := filepath.Join(root, ".jj")
	_, err := os.Stat(jjPath)
	if err != nil && !errors.Is(err, fs.ErrNotExist) {
		return nil, fmt.Errorf("vcs: stat %s: %w", jjPath, err)
	}
	kind := KindGit
	if err == nil && xshell.Have("jj") {
		kind = KindJJ
	}
	return &Repo{Root: root, Kind: kind}, nil
}

func (r *Repo) MetadataDir(ctx context.Context) (string, error) {
	res, runErr := xshell.RunInC(ctx, r.Root, "git", "rev-parse", "--git-common-dir")
	if runErr == nil && res.Code == 0 {
		dir := strings.TrimRight(string(res.Stdout), "\n")
		if filepath.IsAbs(dir) {
			return dir, nil
		}
		return filepath.Join(r.Root, dir), nil
	}
	info, err := os.Stat(filepath.Join(r.Root, ".jj"))
	if err == nil && info.IsDir() {
		return filepath.Join(r.Root, ".jj"), nil
	}
	return "", errors.New("vcs: no git or jj metadata directory")
}
