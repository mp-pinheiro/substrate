// Package transaction implements the checkpoint and restructure transaction
// state machines (P4a), porting core/checkpoint.sh and core/restructure.sh.
package transaction

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/mp-pinheiro/substrate/internal/vcs"
	"github.com/mp-pinheiro/substrate/internal/xshell"
)

// ExitPreflight is sentinel rc 12 — the engine handler never returns 2 (reserved
// for main.go's unknown-verb default). The wrapper remaps 12→2.
const ExitPreflight = 12

// ValidateSafePath rejects absolute paths, paths containing ".." components,
// and empty strings. Used by both checkpoint and restructure.
func ValidateSafePath(path string) error {
	if path == "" {
		return errors.New("empty path")
	}
	if filepath.IsAbs(path) {
		return fmt.Errorf("absolute path not allowed: %s", path)
	}
	if strings.Contains(path, "..") {
		return fmt.Errorf("path contains ..: %s", path)
	}
	return nil
}

// NormalizePaths validates, deduplicates, and sorts a path list with
// LC_ALL=C ordering.
func NormalizePaths(paths []string) ([]string, error) {
	seen := make(map[string]bool)
	var normalized []string
	for _, p := range paths {
		if err := ValidateSafePath(p); err != nil {
			return nil, err
		}
		if !seen[p] {
			seen[p] = true
			normalized = append(normalized, p)
		}
	}
	sort.Strings(normalized)
	return normalized, nil
}

// sortLinesC sorts lines with LC_ALL=C locale.
func sortLinesC(lines []string) []string {
	sorted := make([]string, len(lines))
	copy(sorted, lines)
	sort.Strings(sorted)
	return sorted
}

// Lock acquires a mkdir-based lock at the given path. Returns an error if
// the lock is already held.
func Lock(lockPath string) error {
	if err := os.Mkdir(lockPath, 0700); err != nil {
		if os.IsExist(err) {
			return fmt.Errorf("another substrate transaction is in progress (%s exists)", lockPath)
		}
		return fmt.Errorf("cannot acquire lock %s: %w", lockPath, err)
	}
	return nil
}

// Unlock removes the lock directory.
func Unlock(lockPath string) {
	_ = os.RemoveAll(lockPath)
}

// ResolveMetadataDir resolves the metadata directory for a vcs.Repo.
func ResolveMetadataDir(ctx context.Context, repo *vcs.Repo) (string, error) {
	md, err := repo.MetadataDir(ctx)
	if err != nil {
		return "", fmt.Errorf("transaction: resolve metadata dir: %w", err)
	}
	return md, nil
}

// DetectRepo detects VCS kind at the given root.
func DetectRepo(root string) (*vcs.Repo, error) {
	r, err := vcs.Detect(root)
	if err != nil {
		return nil, fmt.Errorf("transaction: detect repo: %w", err)
	}
	return r, nil
}

// ChangedPaths returns the sorted list of pending working-copy paths,
// reproducing the bash changed_paths() function.
func ChangedPaths(ctx context.Context, repo *vcs.Repo) ([]string, error) {
	if repo.Kind == vcs.KindJJ {
		return changedPathsJJ(ctx, repo)
	}
	return changedPathsGit(ctx, repo)
}

func changedPathsJJ(ctx context.Context, repo *vcs.Repo) ([]string, error) {
	res, err := xshell.RunInC(ctx, repo.Root, "jj", "diff", "--name-only")
	if err != nil {
		return nil, fmt.Errorf("transaction: jj diff: %w", err)
	}
	return splitAndSort(string(res.Stdout)), nil
}

func changedPathsGit(ctx context.Context, repo *vcs.Repo) ([]string, error) {
	res1, err := xshell.RunInC(ctx, repo.Root, "git", "diff", "--name-only", "--diff-filter=ACDMRTUXB", "HEAD", "--")
	if err != nil {
		return nil, fmt.Errorf("transaction: git diff: %w", err)
	}
	res2, err := xshell.RunInC(ctx, repo.Root, "git", "ls-files", "--others", "--exclude-standard")
	if err != nil {
		return nil, fmt.Errorf("transaction: git ls-files: %w", err)
	}
	combined := string(res1.Stdout) + string(res2.Stdout)
	return splitAndSort(combined), nil
}

func splitAndSort(raw string) []string {
	lines := strings.Split(strings.TrimRight(raw, "\n"), "\n")
	var out []string
	for _, l := range lines {
		l = strings.TrimSpace(l)
		if l != "" {
			out = append(out, l)
		}
	}
	sort.Strings(out)
	return out
}

// SetDifference returns lines in B not present in A (comm -13).
func SetDifference(a, b []string) []string {
	set := make(map[string]bool, len(a))
	for _, s := range a {
		set[s] = true
	}
	var out []string
	for _, s := range b {
		if !set[s] {
			out = append(out, s)
		}
	}
	return out
}

// SetIntersection returns lines present in both A and B (comm -12).
func SetIntersection(a, b []string) []string {
	set := make(map[string]bool, len(a))
	for _, s := range a {
		set[s] = true
	}
	var out []string
	for _, s := range b {
		if set[s] {
			out = append(out, s)
		}
	}
	return out
}

// CommMinus23 returns lines in A not present in B (comm -23).
func CommMinus23(a, b []string) []string {
	set := make(map[string]bool, len(b))
	for _, s := range b {
		set[s] = true
	}
	var out []string
	for _, s := range a {
		if !set[s] {
			out = append(out, s)
		}
	}
	return out
}

// CurrentGateRevision returns the current gate revision (jj @- or git HEAD).
func CurrentGateRevision(ctx context.Context, repo *vcs.Repo) (string, error) {
	revision, _, err := repo.Revision(ctx)
	if err != nil {
		return "", fmt.Errorf("transaction: revision: %w", err)
	}
	return revision, nil
}

// resolveEnginePath resolves the engine binary for delegation from environment.
func resolveEnginePath() string {
	if bin := os.Getenv("SUBSTRATE_ENGINE_BIN"); bin != "" {
		return bin
	}
	return "substrate-engine"
}
