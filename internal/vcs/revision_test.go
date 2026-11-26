package vcs

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"testing"
)

func initJJRepo(t *testing.T) string {
	t.Helper()
	t.Setenv("JJ_CONFIG", filepath.Join(t.TempDir(), "config.toml"))
	root := t.TempDir()
	out, err := exec.Command("jj", "git", "init", root).CombinedOutput()
	if errors.Is(err, exec.ErrNotFound) {
		t.Skip("jj not on PATH")
	}
	if err != nil {
		t.Fatalf("jj git init: %v\n%s", err, out)
	}
	return root
}

func TestJJRevisionIgnoresSnapshotWarnings(t *testing.T) {
	root := initJJRepo(t)
	if err := os.WriteFile(filepath.Join(root, "oversized.bin"), make([]byte, 2<<20), 0o644); err != nil {
		t.Fatal(err)
	}

	revision, revisionErr, err := (&Repo{Root: root, Kind: KindJJ}).Revision(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if revisionErr != "" {
		t.Fatalf("revision error = %q, want none", revisionErr)
	}
	if !regexp.MustCompile(`^[0-9a-f]{40}$`).MatchString(revision) {
		t.Fatalf("revision = %q, want a bare commit id; jj's snapshot warning must not leak into it", revision)
	}
}
