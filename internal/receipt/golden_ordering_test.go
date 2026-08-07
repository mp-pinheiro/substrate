package receipt

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

// H3: enumeration order fed the digest directly in bash; v2 sorts before
// hashing, so any permutation of the same record set must hash identically.
func TestHashRecordsOrderingInvariant(t *testing.T) {
	const wantHash = "cfa291b5b7ef20b0acd726846674962de3439bdc3b84e0fd7a1ba940990c466f"

	alpha := joinFields("alpha", "file", "644", "hash1")
	bravo := joinFields("bravo", "file", "644", "hash2")
	charlie := joinFields("charlie", "file", "644", "hash3")

	orders := [][][]byte{
		{alpha, bravo, charlie},
		{charlie, bravo, alpha},
		{bravo, charlie, alpha},
	}

	var hashes []string
	for _, order := range orders {
		records := append([][]byte(nil), order...)
		hash, err := hashRecords(records)
		if err != nil {
			t.Fatalf("hashRecords: %v", err)
		}
		hashes = append(hashes, hash)
	}
	for i, h := range hashes {
		if h != wantHash {
			t.Errorf("order %d: hash = %s, want %s", i, h, wantHash)
		}
	}
}

func writeProfileManifest(t *testing.T, repoRoot, profile string, manifest profileManifest) {
	t.Helper()
	dir := filepath.Join(repoRoot, ".substrate", "profiles", profile)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatalf("mkdir %s: %v", dir, err)
	}
	b, err := json.Marshal(manifest)
	if err != nil {
		t.Fatalf("marshal profile manifest: %v", err)
	}
	if err := os.WriteFile(filepath.Join(dir, "profile.json"), b, 0o644); err != nil {
		t.Fatalf("write profile manifest: %v", err)
	}
}

// H4: bash hashed "./x" and "x" as two distinct files; a "./"-prefixed
// duplicate of an existing seed name must canonicalise to ONE record.
func TestConfigurationHashCanonicalizesDotSlash(t *testing.T) {
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "substrate.json"), []byte("{}\n"), 0o644); err != nil {
		t.Fatalf("write substrate.json: %v", err)
	}

	baseline, err := computeConfigurationHash(root, nil)
	if err != nil {
		t.Fatalf("computeConfigurationHash(baseline): %v", err)
	}

	writeProfileManifest(t, root, "dup", profileManifest{
		Templates: []profileTemplateEntry{{Dest: "./substrate.json"}},
	})
	withDup, err := computeConfigurationHash(root, []string{"dup"})
	if err != nil {
		t.Fatalf("computeConfigurationHash(withDup): %v", err)
	}

	if baseline != withDup {
		t.Errorf("./-prefixed duplicate produced a second record: baseline=%s withDup=%s", baseline, withDup)
	}
}
