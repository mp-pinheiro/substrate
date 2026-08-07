package receipt

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

func requireJJ(t *testing.T) {
	t.Helper()
	if _, err := exec.LookPath("jj"); err != nil {
		t.Skip("jj not on PATH")
	}
}

func runJJ(t *testing.T, dir string, args ...string) string {
	t.Helper()
	cmd := exec.Command("jj", args...)
	cmd.Dir = dir
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("jj %v: %v\n%s", args, err, out)
	}
	return string(out)
}

// R1: Write must resolve the vcs backend like BuildState does, not default to
// git's zero Kind — else Revision() runs `git rev-parse HEAD` in a jj repo.
func TestWriteResolvesJJBackendNonColocated(t *testing.T) {
	requireJJ(t)
	root := t.TempDir()
	runJJ(t, root, "git", "init", "--config", "git.colocate=false")
	if err := os.WriteFile(filepath.Join(root, "substrate.json"),
		[]byte(`{"version":1,"profiles":[],"contracts":[]}`+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(root, ".git")); err == nil {
		t.Fatal("expected no .git directory in a non-colocated jj repo")
	}

	commit := runJJTrim(t, root, "log", "-r", "@-", "--no-graph", "-T", "commit_id")
	receiptJSON, err := Write(context.Background(), root, "test", commit, "jj", "", "")
	if err != nil {
		t.Fatalf("Write on a non-colocated jj repo: %v", err)
	}
	if receiptJSON == "" {
		t.Fatal("Write returned an empty receipt")
	}
}

func runJJTrim(t *testing.T, dir string, args ...string) string {
	t.Helper()
	out := runJJ(t, dir, args...)
	for len(out) > 0 && (out[len(out)-1] == '\n' || out[len(out)-1] == '\r') {
		out = out[:len(out)-1]
	}
	return out
}
