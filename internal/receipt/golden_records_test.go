package receipt

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
)

const goldenRecordsDir = "../../test/golden/receipt/records"

func readGolden(t *testing.T, name string) []byte {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(goldenRecordsDir, name))
	if err != nil {
		t.Fatalf("read golden %s: %v", name, err)
	}
	return b
}

func assertGolden(t *testing.T, label string, got, want []byte) {
	t.Helper()
	if bytes.Equal(got, want) {
		return
	}
	n := len(got)
	if len(want) < n {
		n = len(want)
	}
	off := n
	for i := range n {
		if got[i] != want[i] {
			off = i
			break
		}
	}
	t.Errorf("%s: byte mismatch at offset %d\n got  (%d bytes): %q\n want (%d bytes): %q",
		label, off, len(got), got, len(want), want)
}

func buildRecordFixtures(t *testing.T) string {
	t.Helper()
	root := t.TempDir()

	write := func(rel, content string, mode os.FileMode) {
		p := filepath.Join(root, rel)
		if err := os.WriteFile(p, []byte(content), 0o600); err != nil {
			t.Fatalf("write fixture %s: %v", rel, err)
		}
		if err := os.Chmod(p, mode); err != nil {
			t.Fatalf("chmod fixture %s: %v", rel, err)
		}
	}

	write("café.txt", "café body\n", 0o644)
	write("space file.txt", "space body\n", 0o755)
	write("tab\tfile.txt", "tab body\n", 0o644)
	write("bad\xffname.txt", "invalid body\n", 0o644)
	if err := os.Symlink("café.txt", filepath.Join(root, "link-to-cafe")); err != nil {
		t.Fatalf("symlink fixture: %v", err)
	}
	return root
}

// H1/H2/H14: bash's printf %q escapes bytes by LC_CTYPE; v2 frames raw bytes
// instead, so this must hold byte-for-byte under both a C and UTF-8 locale.
func TestFileStateRecordGoldenVectors(t *testing.T) {
	root := buildRecordFixtures(t)

	cases := []struct {
		name   string
		rel    string
		golden string
	}{
		{"multibyte-utf8-path", "café.txt", "cafe.record"},
		{"space-in-path", "space file.txt", "space-file.record"},
		{"tab-in-path", "tab\tfile.txt", "tab-file.record"},
		{"invalid-utf8-byte-in-path", "bad\xffname.txt", "invalid-utf8.record"},
		{"symlink", "link-to-cafe", "symlink.record"},
		{"missing", "does-not-exist.txt", "missing.record"},
	}

	for _, locale := range []string{"C", "en_US.UTF-8"} {
		t.Run("LC_ALL="+locale, func(t *testing.T) {
			t.Setenv("LC_ALL", locale)
			for _, c := range cases {
				t.Run(c.name, func(t *testing.T) {
					got, err := fileStateRecord(root, c.rel)
					if err != nil {
						t.Fatalf("fileStateRecord(%q): %v", c.rel, err)
					}
					assertGolden(t, c.name, got, readGolden(t, c.golden))
				})
			}
		})
	}
}
