package hook

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strings"
)

// runMergedPush reproduces bash's `2>&1`: a shared pipe fd preserves real
// write order, which separate stdout/stderr buffers cannot.
func runMergedPush(ctx context.Context, dir, name string, args ...string) (string, int, error) {
	r, w, err := os.Pipe()
	if err != nil {
		return "", -1, fmt.Errorf("hook: open pipe: %w", err)
	}
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Dir = dir
	cmd.Stdout = w
	cmd.Stderr = w
	var buf bytes.Buffer
	done := make(chan struct{})
	go func() {
		_, _ = io.Copy(&buf, r)
		close(done)
	}()
	runErr := cmd.Run()
	_ = w.Close()
	<-done
	_ = r.Close()

	if runErr == nil {
		return buf.String(), 0, nil
	}
	var exitErr *exec.ExitError
	if errors.As(runErr, &exitErr) {
		return buf.String(), exitErr.ExitCode(), nil
	}
	return buf.String(), -1, fmt.Errorf("hook: run %s: %w", name, runErr)
}

func dispatchGateBeforePush(ctx context.Context, e env, stdin io.Reader) int {
	payload, _ := io.ReadAll(stdin)
	v, decodeFailed := decodePayload(payload)
	var cmd string
	if !decodeFailed {
		cmd, _ = jqAlt(v, "tool_input.command")
	}
	if !strings.Contains(cmd, "jj git push") && !strings.Contains(cmd, "git push") {
		return 0
	}
	if strings.Contains(cmd, "-R ") {
		return 0
	}

	script := e.substrateDir + "/push-gate.sh"
	output, code, err := runMergedPush(ctx, e.repoRoot, script)
	if err != nil {
		writeResult(nil, []byte("push blocked: fix the failing gate checks first\n"))
		return 2
	}
	if code != 0 {
		writeResult(nil, []byte(strings.TrimRight(output, "\n")+"\npush blocked: fix the failing gate checks first\n"))
		return 2
	}
	return 0
}
