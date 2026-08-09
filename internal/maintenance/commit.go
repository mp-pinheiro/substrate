package maintenance

import (
	"context"
	"fmt"
	"os"
	"strings"

	"github.com/mp-pinheiro/substrate/internal/xshell"
)

type commitFailError struct{}

func (e *commitFailError) Error() string { return "injected maintenance commit failure" }

func CommitExact(ctx context.Context, unitsFile string, txID string, c *Context) (string, error) {
	if os.Getenv("SUBSTRATE_MAINTENANCE_FAIL_COMMIT") == "1" {
		fmt.Fprintf(os.Stderr, "injected maintenance commit failure\n")
		return "", &commitFailError{}
	}

	data, err := os.ReadFile(unitsFile)
	if err != nil {
		return "", fmt.Errorf("commit: read units file: %w", err)
	}
	lines := strings.Split(strings.TrimSpace(string(data)), "\n")
	units := make([]string, 0, len(lines))
	for _, line := range lines {
		line = strings.TrimSpace(line)
		if line != "" {
			units = append(units, line)
		}
	}
	if len(units) == 0 {
		return "", fmt.Errorf("commit: no units to commit")
	}

	prev := os.Getenv("SUBSTRATE_MAINTENANCE_ID")
	_ = os.Setenv("SUBSTRATE_MAINTENANCE_ID", txID)
	defer func() { _ = os.Setenv("SUBSTRATE_MAINTENANCE_ID", prev) }()

	if c.VCS == "jj" {
		return commitExactJJ(ctx, c, units)
	}
	return commitExactGit(ctx, c, units)
}

func commitExactJJ(ctx context.Context, c *Context, units []string) (string, error) {
	args := []string{"commit", "--message", c.Message, "--"}
	args = append(args, units...)
	if _, err := xshell.RunIn(ctx, c.RepoRoot, "jj", args...); err != nil {
		return "", fmt.Errorf("commit: jj commit: %w", err)
	}

	result, err := xshell.RunIn(ctx, c.RepoRoot, "jj", "log", "-r", "@-", "--no-graph", "-T", "commit_id")
	if err != nil {
		return "", fmt.Errorf("commit: jj log: %w", err)
	}
	return trimLine(string(result.Stdout)), nil
}

func commitExactGit(ctx context.Context, c *Context, units []string) (string, error) {
	f, err := os.CreateTemp("", "substrate-git-index-")
	if err != nil {
		return "", fmt.Errorf("commit: temp index: %w", err)
	}
	tempIndex := f.Name()
	_ = f.Close()
	_ = os.Remove(tempIndex)

	prevIndex := os.Getenv("GIT_INDEX_FILE")
	_ = os.Setenv("GIT_INDEX_FILE", tempIndex)
	defer func() {
		_ = os.Setenv("GIT_INDEX_FILE", prevIndex)
		_ = os.Remove(tempIndex)
	}()

	hasHead := true
	if _, err := xshell.RunIn(ctx, c.RepoRoot, "git", "rev-parse", "--verify", "HEAD"); err != nil {
		hasHead = false
	}

	if hasHead {
		if _, err := xshell.RunIn(ctx, c.RepoRoot, "git", "read-tree", "HEAD"); err != nil {
			return "", fmt.Errorf("commit: git read-tree: %w", err)
		}
	} else {
		if _, err := xshell.RunIn(ctx, c.RepoRoot, "git", "read-tree", "--empty"); err != nil {
			return "", fmt.Errorf("commit: git read-tree --empty: %w", err)
		}
	}

	addArgs := []string{"add", "-f", "-A", "--"}
	addArgs = append(addArgs, units...)
	if _, err := xshell.RunIn(ctx, c.RepoRoot, "git", addArgs...); err != nil {
		return "", fmt.Errorf("commit: git add: %w", err)
	}

	if _, err := xshell.RunIn(ctx, c.RepoRoot, "git", "commit", "-m", c.Message); err != nil {
		return "", fmt.Errorf("commit: git commit: %w", err)
	}

	result, err := xshell.RunIn(ctx, c.RepoRoot, "git", "rev-parse", "HEAD")
	if err != nil {
		return "", fmt.Errorf("commit: git rev-parse: %w", err)
	}
	hash := trimLine(string(result.Stdout))

	resetArgs := []string{"reset", "--quiet", "HEAD", "--"}
	resetArgs = append(resetArgs, units...)
	if _, err := xshell.RunIn(ctx, c.RepoRoot, "git", resetArgs...); err != nil {
		return "", fmt.Errorf("commit: git reset: %w", err)
	}

	return hash, nil
}
