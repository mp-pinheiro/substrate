package lifecycle

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/mp-pinheiro/substrate/internal/canonjson"
)

// runMerged reproduces bash's `2>&1`: a shared pipe fd preserves real write
// order, which separate xshell.Result buffers cannot (os/exec copies each pipe through its own goroutine, losing interleaving).
func runMerged(ctx context.Context, dir, name string, args ...string) (string, int, error) {
	r, w, err := os.Pipe()
	if err != nil {
		return "", -1, fmt.Errorf("lifecycle: open pipe: %w", err)
	}
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Dir = dir
	cmd.Env = os.Environ()
	cmd.Stdout = w
	cmd.Stderr = w

	if err := cmd.Start(); err != nil {
		_ = w.Close()
		_ = r.Close()
		return "", -1, fmt.Errorf("lifecycle: start %s: %w", name, err)
	}
	_ = w.Close()

	out, readErr := io.ReadAll(r)
	_ = r.Close()
	waitErr := cmd.Wait()
	if readErr != nil {
		return string(out), -1, readErr
	}

	var exitErr *exec.ExitError
	switch {
	case waitErr == nil:
		return string(out), 0, nil
	case errors.As(waitErr, &exitErr):
		return string(out), exitErr.ExitCode(), nil
	default:
		return string(out), -1, waitErr
	}
}

func lastLine(s string) string {
	trimmed := trimTrailingNewlines(s)
	if trimmed == "" {
		return ""
	}
	parts := strings.Split(trimmed, "\n")
	return parts[len(parts)-1]
}

func commitFieldOf(line string) string {
	if line == "" {
		return ""
	}
	val, err := canonjson.Unmarshal([]byte(line))
	if err != nil {
		return ""
	}
	obj, ok := val.(*canonjson.Object)
	if !ok {
		return ""
	}
	return objString(obj, "commit")
}

func (e *Engine) runAutoCheckpoint(ctx context.Context, session string) (string, int, error) {
	checkpointPath := filepath.Join(e.paths.SubstrateDir, "checkpoint.sh")
	return runMerged(ctx, e.paths.RepoRoot, checkpointPath,
		"--session", session,
		"--message", "chore(agent): checkpoint owned work at session stop",
		"--json")
}
