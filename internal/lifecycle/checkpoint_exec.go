package lifecycle

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strings"

	"github.com/mp-pinheiro/substrate/internal/canonjson"
	"github.com/mp-pinheiro/substrate/internal/recovery"
	"github.com/mp-pinheiro/substrate/internal/xshell"
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

func recoveryReport(s string) (recovery.Report, bool) {
	var report recovery.Report
	found := reverseScanObjects(s, func(obj *canonjson.Object) bool {
		status, ok1 := objStringOK(obj, "status")
		code, ok2 := objStringOK(obj, "code")
		owner, ok3 := objStringOK(obj, "owner")
		retry, ok4 := objStringOK(obj, "retry")
		summary, ok5 := objStringOK(obj, "summary")
		next, ok6 := objStringOK(obj, "next")
		if !ok1 || !ok2 || !ok3 || !ok4 || !ok5 || !ok6 {
			return false
		}
		report = recovery.Report{Status: status, Code: code, Owner: owner, Retry: retry, Summary: summary, Details: objStringArrayOK(obj, "details"), Next: next}
		return true
	})
	return report, found
}

func receiptCommit(s string) string {
	var commit string
	reverseScanObjects(s, func(obj *canonjson.Object) bool {
		commit, _ = objStringOK(obj, "commit")
		return commit != ""
	})
	return commit
}

func reverseScanObjects(s string, visit func(*canonjson.Object) bool) bool {
	for _, line := range recovery.ReverseLines(strings.TrimSpace(s)) {
		val, err := canonjson.Unmarshal([]byte(line))
		if err != nil {
			continue
		}
		obj, ok := val.(*canonjson.Object)
		if !ok {
			continue
		}
		if visit(obj) {
			return true
		}
	}
	return false
}

func objStringArrayOK(obj *canonjson.Object, key string) []string {
	v, ok := obj.Get(key)
	if !ok {
		return nil
	}
	values, ok := v.([]canonjson.Value)
	if !ok {
		return nil
	}
	out := make([]string, 0, len(values))
	for _, value := range values {
		if s, ok := value.(string); ok {
			out = append(out, s)
		}
	}
	return out
}

func objStringOK(obj *canonjson.Object, key string) (string, bool) {
	v, ok := obj.Get(key)
	s, isString := v.(string)
	return s, ok && isString
}

func (e *Engine) runAutoCheckpoint(ctx context.Context, session string) (string, int, error) {
	bin, err := xshell.EngineBin()
	if err != nil {
		return "", -1, fmt.Errorf("auto-checkpoint: %w", err)
	}
	return runMerged(ctx, e.paths.RepoRoot, bin,
		"checkpoint",
		"--session", session,
		"--message", "chore(agent): checkpoint owned work at session stop",
		"--json")
}
