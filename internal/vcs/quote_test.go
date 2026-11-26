package vcs

import (
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"testing"
)

func TestJJPatternsSelectLiteralPaths(t *testing.T) {
	root := initJJRepo(t)
	files := []string{
		"src/routes/(app)/admin/+page.svelte",
		"src/routes/[...rest]/+page.svelte",
		"src/routes/[page=integer]/+page.svelte",
		"src/routes/blog/[slug]/+page.svelte",
		"src/routes/blog/[slug]/+page.ts",
		"src/routes/blog/s/+page.svelte",
		`src/quote"d/back\slash.sh`,
	}
	for _, file := range files {
		full := filepath.Join(root, file)
		if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(full, []byte("x\n"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	list := func(patterns []string) []string {
		t.Helper()
		cmd := exec.Command("jj", append([]string{"file", "list", "--"}, patterns...)...)
		cmd.Dir = root
		out, err := cmd.Output()
		if err != nil {
			t.Fatalf("jj file list %q: %v", patterns, err)
		}
		return strings.Split(strings.TrimSuffix(string(out), "\n"), "\n")
	}

	for _, file := range files {
		if got := list(JJFilePatterns([]string{file})); !slices.Equal(got, []string{file}) {
			t.Errorf("file pattern for %q selected %q", file, got)
		}
	}
	want := []string{"src/routes/blog/[slug]/+page.svelte", "src/routes/blog/[slug]/+page.ts"}
	if got := list(JJPrefixPatterns([]string{"src/routes/blog/[slug]"})); !slices.Equal(got, want) {
		t.Errorf("prefix pattern for the [slug] directory selected %q, want %q", got, want)
	}
}
