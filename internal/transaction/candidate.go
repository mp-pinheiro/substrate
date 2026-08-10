package transaction

import (
	"context"
	"fmt"
	"os"
	"path/filepath"

	"github.com/mp-pinheiro/substrate/internal/vcs"
	"github.com/mp-pinheiro/substrate/internal/xshell"
)

// Candidate builds an isolated tree from a base revision plus owned path
// overlays, seeds a git repo in it, and runs the gate inside it.
type Candidate struct {
	Dir     string
	Archive string
}

// NewCandidate creates a candidate tree from the base revision with the given
// owned file paths overlaid from the worktree root.
func NewCandidate(ctx context.Context, repo *vcs.Repo, base string, ownedPaths []string) (*Candidate, error) {
	dir, err := os.MkdirTemp("", "substrate-candidate-*")
	if err != nil {
		return nil, fmt.Errorf("candidate: mktemp: %w", err)
	}
	archive, err := os.CreateTemp("", "substrate-archive-*")
	if err != nil {
		_ = os.RemoveAll(dir)
		return nil, fmt.Errorf("candidate: create archive temp: %w", err)
	}
	archivePath := archive.Name()
	_ = archive.Close()

	c := &Candidate{Dir: dir, Archive: archivePath}

	if err := c.buildFromRevision(ctx, repo, base, ownedPaths); err != nil {
		c.Cleanup()
		return nil, err
	}
	return c, nil
}

func (c *Candidate) buildFromRevision(ctx context.Context, repo *vcs.Repo, base string, ownedPaths []string) error {
	// git archive the base revision into a tar, then extract into candidate dir.
	if res, err := xshell.RunIn(ctx, repo.Root, "git", "archive", "--format=tar", "--output="+c.Archive, base); err != nil || res.Code != 0 {
		return fmt.Errorf("candidate: git archive %s: %w (stderr: %s)", base, err, res.Stderr)
	}
	if res, err := xshell.Run(ctx, "tar", "-xf", c.Archive, "-C", c.Dir); err != nil || res.Code != 0 {
		return fmt.Errorf("candidate: tar extract: %w (stderr: %s)", err, res.Stderr)
	}

	// Overlay owned files from worktree into candidate.
	if err := c.overlayOwnedPaths(repo.Root, ownedPaths); err != nil {
		return err
	}

	// Seed git repo in candidate.
	if err := c.seedGitRepo(ctx); err != nil {
		return err
	}

	versionPath := filepath.Join(c.Dir, ".substrate", "VERSION")
	if _, err := os.Stat(versionPath); err != nil {
		return fmt.Errorf("candidate: revision %s does not carry the vendored substrate runtime", base)
	}

	return nil
}

func (c *Candidate) overlayOwnedPaths(worktreeRoot string, paths []string) error {
	for _, p := range paths {
		src := filepath.Join(worktreeRoot, p)
		dst := filepath.Join(c.Dir, p)

		info, err := os.Lstat(src)
		if err != nil {
			if os.IsNotExist(err) {
				_ = os.RemoveAll(dst)
				continue
			}
			return fmt.Errorf("candidate: stat %s: %w", p, err)
		}

		if err := os.MkdirAll(filepath.Dir(dst), 0755); err != nil {
			return fmt.Errorf("candidate: mkdir %s: %w", filepath.Dir(p), err)
		}

		if info.Mode()&os.ModeSymlink != 0 {
			link, err := os.Readlink(src)
			if err != nil {
				return fmt.Errorf("candidate: readlink %s: %w", p, err)
			}
			_ = os.Remove(dst)
			if err := os.Symlink(link, dst); err != nil {
				return fmt.Errorf("candidate: symlink %s: %w", p, err)
			}
		} else {
			data, err := os.ReadFile(src)
			if err != nil {
				return fmt.Errorf("candidate: read %s: %w", p, err)
			}
			if err := os.WriteFile(dst, data, info.Mode().Perm()); err != nil {
				return fmt.Errorf("candidate: write %s: %w", p, err)
			}
		}
	}
	return nil
}

func (c *Candidate) seedGitRepo(ctx context.Context) error {
	steps := []struct {
		name string
		args []string
	}{
		{"git", []string{"-C", c.Dir, "init", "-q", "--initial-branch=main"}},
		{"git", []string{"-C", c.Dir, "config", "user.name", "substrate-checkpoint"}},
		{"git", []string{"-C", c.Dir, "config", "user.email", "substrate@localhost"}},
		{"git", []string{"-C", c.Dir, "add", "-f", "-A"}},
		{"git", []string{"-C", c.Dir, "commit", "-q", "--allow-empty", "-m", "chore: seed checkpoint candidate"}},
	}
	for _, s := range steps {
		res, err := xshell.Run(ctx, s.name, s.args...)
		if err != nil || res.Code != 0 {
			return fmt.Errorf("candidate: %s: %w (stderr: %s)", s.name, err, res.Stderr)
		}
	}
	return nil
}

// RunGate runs the gate in the candidate tree with the given flags.
func (c *Candidate) RunGate(ctx context.Context, args ...string) (string, error) {
	saved := os.Getenv("SUBSTRATE_FILE_LIST")
	_ = os.Unsetenv("SUBSTRATE_FILE_LIST")
	defer func() { _ = os.Setenv("SUBSTRATE_FILE_LIST", saved); }()
	bin, err := xshell.EngineBin()
	if err != nil {
		return "", fmt.Errorf("candidate gate: %w", err)
	}
	res, err := xshell.RunIn(ctx, c.Dir, bin, append([]string{"gate"}, args...)...)
	if err != nil {
		return string(res.Stdout) + string(res.Stderr), fmt.Errorf("candidate gate: %w", err)
	}
	if res.Code != 0 {
		return string(res.Stdout) + string(res.Stderr), fmt.Errorf("candidate gate failed with code %d", res.Code)
	}
	return string(res.Stdout), nil
}

// CopyBaseline copies the candidate's substrate-baseline.json back to worktreeRoot
// if it differs, preserving the original file's mode.
func (c *Candidate) CopyBaseline(worktreeRoot string) (bool, error) {
	candidateBaseline := filepath.Join(c.Dir, "substrate-baseline.json")
	worktreeBaseline := filepath.Join(worktreeRoot, "substrate-baseline.json")

	candData, err := os.ReadFile(candidateBaseline)
	if err != nil {
		return false, fmt.Errorf("candidate: read baseline: %w", err)
	}

	wtData, err := os.ReadFile(worktreeBaseline)
	if err != nil {
		return false, fmt.Errorf("candidate: read worktree baseline: %w", err)
	}

	if string(candData) == string(wtData) {
		return false, nil
	}

	// Preserve original mode.
	info, err := os.Stat(worktreeBaseline)
	if err != nil {
		return false, fmt.Errorf("candidate: stat worktree baseline: %w", err)
	}
	if err := os.WriteFile(worktreeBaseline, candData, info.Mode().Perm()); err != nil {
		return false, fmt.Errorf("candidate: write baseline: %w", err)
	}
	return true, nil
}

// Cleanup removes temporary files and directories.
func (c *Candidate) Cleanup() {
	if c.Archive != "" {
		_ = os.Remove(c.Archive)
	}
	if c.Dir != "" {
		_ = os.RemoveAll(c.Dir)
	}
}
