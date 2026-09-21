package maintenance

import (
	"os"
	"path/filepath"
	"testing"
)

func TestProvisionCandidateDependencies(t *testing.T) {
	t.Parallel()

	source, candidate := dependencyRoots(t)
	sourceModules := filepath.Join(source, "frontend", "node_modules")
	if err := os.Mkdir(sourceModules, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(sourceModules, "marker"), []byte("ready"), 0o644); err != nil {
		t.Fatal(err)
	}

	links, err := provisionCandidateDependencies(source, candidate)
	if err != nil {
		t.Fatal(err)
	}
	if len(links) != 1 {
		t.Fatalf("links = %v, want one", links)
	}
	target := filepath.Join(candidate, "frontend", "node_modules")
	info, err := os.Lstat(target)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode()&os.ModeSymlink == 0 {
		t.Fatalf("%s is not a symlink", target)
	}
	marker, err := os.ReadFile(filepath.Join(target, "marker"))
	if err != nil {
		t.Fatal(err)
	}
	if string(marker) != "ready" {
		t.Fatalf("marker = %q", marker)
	}
	if err := cleanupCandidateDependencies(links); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Lstat(target); !os.IsNotExist(err) {
		t.Fatalf("candidate dependency remained after cleanup: %v", err)
	}
}

func TestProvisionCandidateDependenciesPreservesExistingDirectory(t *testing.T) {
	t.Parallel()

	source, candidate := dependencyRoots(t)
	for _, root := range []string{source, candidate} {
		if err := os.Mkdir(filepath.Join(root, "frontend", "node_modules"), 0o755); err != nil {
			t.Fatal(err)
		}
	}

	links, err := provisionCandidateDependencies(source, candidate)
	if err != nil {
		t.Fatal(err)
	}
	if len(links) != 0 {
		t.Fatalf("links = %v, want none", links)
	}
	info, err := os.Lstat(filepath.Join(candidate, "frontend", "node_modules"))
	if err != nil {
		t.Fatal(err)
	}
	if !info.IsDir() {
		t.Fatal("existing candidate dependency directory changed")
	}
}

func dependencyRoots(t *testing.T) (string, string) {
	t.Helper()
	source, candidate := t.TempDir(), t.TempDir()
	for _, root := range []string{source, candidate} {
		if err := os.MkdirAll(filepath.Join(root, "frontend"), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(root, "frontend", "bun.lock"), []byte("lock"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return source, candidate
}
