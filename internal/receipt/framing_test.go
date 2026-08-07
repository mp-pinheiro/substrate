package receipt

import (
	"os"
	"path/filepath"
	"testing"
)

// R2: a single field embedding both old separator bytes (0x1F/0x1E) used to
// alias two honest records' concatenated bytes — forgedRel reproduces that.
func TestFramingRecordBoundaryForgeryClosed(t *testing.T) {
	record1Raw := "evil" + string(rune(0x1F)) + "file" + string(rune(0x1F)) + "644" + string(rune(0x1F)) + "H1"
	forgedRel := record1Raw + string(rune(0x1E)) + "z"

	forgedState := [][]byte{joinFields(forgedRel, "missing")}
	honestState := [][]byte{
		joinFields("evil", "file", "644", "H1"),
		joinFields("z", "missing"),
	}

	forgedHash, err := hashRecords(forgedState)
	if err != nil {
		t.Fatalf("hashRecords(forged): %v", err)
	}
	honestHash, err := hashRecords(honestState)
	if err != nil {
		t.Fatalf("hashRecords(honest): %v", err)
	}

	if forgedHash == honestHash {
		t.Fatalf("record framing still forgeable: single record with an embedded separator "+
			"(%x) collides with two honest records at %s", forgedRel, forgedHash)
	}
}

func TestJoinFieldsRoundTripsEmbeddedSeparators(t *testing.T) {
	rel := "a" + string(rune(0x1F)) + "b" + string(rune(0x1E)) + "c"
	record := joinFields(rel, "missing")

	fields := splitRecordFields(t, record)
	if len(fields) != 2 || fields[0] != rel || fields[1] != "missing" {
		t.Fatalf("joinFields(%q, missing) round-trip = %v, want [%q missing]", rel, fields, rel)
	}
}

// R3: %o of Mode().Perm() alone masks off setuid/setgid/sticky, so chmod
// 755/4755/2755/1755 must stay four DISTINCT records, matching `stat -c '%a'`.
func TestStatPermStringIncludesSpecialBits(t *testing.T) {
	dir := t.TempDir()
	f := filepath.Join(dir, "bin")
	if err := os.WriteFile(f, []byte("body\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	cases := map[string]os.FileMode{
		"755":  0o755,
		"4755": os.ModeSetuid | 0o755,
		"2755": os.ModeSetgid | 0o755,
		"1755": os.ModeSticky | 0o755,
	}
	seen := make(map[string]string, len(cases))
	for want, mode := range cases {
		if err := os.Chmod(f, mode); err != nil {
			t.Fatal(err)
		}
		info, err := os.Lstat(f)
		if err != nil {
			t.Fatal(err)
		}
		got := statPermString(info.Mode())
		if got != want {
			t.Errorf("statPermString(%v) = %q, want %q", mode, got, want)
		}
		if other, dup := seen[got]; dup {
			t.Fatalf("mode %q collides with %q", want, other)
		}
		seen[got] = want
	}
}
