package maintenance

import (
	"context"
	"fmt"
	"os"
	"path/filepath"

	"github.com/mp-pinheiro/substrate/internal/vcs"
	"github.com/mp-pinheiro/substrate/internal/xshell"
)

func MetadataDir() (string, error) {
	repo, err := vcs.Detect(".")
	if err != nil {
		return "", fmt.Errorf("metadata: detect vcs: %w", err)
	}
	ctx := context.Background()
	result, gitErr := xshell.Run(ctx, "git", "rev-parse", "--git-common-dir")
	if gitErr == nil {
		return absPath(trimLine(string(result.Stdout)))
	}
	if repo.Kind == vcs.KindJJ {
		abs, err := absPath(".jj")
		if err != nil {
			return "", fmt.Errorf("metadata: resolve .jj: %w", err)
		}
		return abs, nil
	}
	return "", fmt.Errorf("repository metadata is unavailable")
}

func Revision(ctx context.Context) (string, error) {
	vcsKind, err := detectVCS()
	if err != nil {
		return "", err
	}
	if vcsKind == "jj" {
		result, err := xshell.Run(ctx, "jj", "log", "-r", "@-", "--no-graph", "-T", "commit_id")
		if err != nil {
			return "", nil
		}
		return trimLine(string(result.Stdout)), nil
	}
	result, err := xshell.Run(ctx, "git", "rev-parse", "--verify", "HEAD")
	if err != nil {
		return "", nil
	}
	return trimLine(string(result.Stdout)), nil
}

func WriteJSON(path string, content string) error {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0755); err != nil {
		return fmt.Errorf("write_json: mkdir: %w", err)
	}
	f, err := os.CreateTemp(dir, filepath.Base(path)+".*")
	if err != nil {
		return fmt.Errorf("write_json: mktemp: %w", err)
	}
	stagedPath := f.Name()
	if _, err := f.WriteString(content); err != nil {
		_ = f.Close()
		_ = os.Remove(stagedPath)
		return fmt.Errorf("write_json: write: %w", err)
	}
	if err := f.Close(); err != nil {
		_ = os.Remove(stagedPath)
		return fmt.Errorf("write_json: close: %w", err)
	}
	if err := os.Chmod(stagedPath, 0600); err != nil {
		_ = os.Remove(stagedPath)
		return fmt.Errorf("write_json: chmod: %w", err)
	}
	if err := os.Rename(stagedPath, path); err != nil {
		_ = os.Remove(stagedPath)
		return fmt.Errorf("write_json: rename: %w", err)
	}
	return nil
}

func LockPath(metaDir string) string {
	return filepath.Join(metaDir, "substrate", "maintenance.lock")
}

func StablePath(metaDir string) string {
	return filepath.Join(metaDir, "substrate", "maintenance-receipt.json")
}

func absPath(p string) (string, error) {
	if filepath.IsAbs(p) {
		return p, nil
	}
	wd, err := os.Getwd()
	if err != nil {
		return "", fmt.Errorf("maintenance: getwd: %w", err)
	}
	return filepath.Clean(filepath.Join(wd, p)), nil
}

func trimLine(s string) string {
	if len(s) > 0 && s[len(s)-1] == '\n' {
		s = s[:len(s)-1]
	}
	if len(s) > 0 && s[len(s)-1] == '\r' {
		s = s[:len(s)-1]
	}
	return s
}
