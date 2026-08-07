package receipt

import (
	"os"
	"path/filepath"
	"testing"
)

// H6/A31: bash's find|sort over a gone .substrate digests an empty record
// set into the ordinary-looking sha256(""); computeEngineHash must fail closed instead.
func TestEngineHashMissingRootErrors(t *testing.T) {
	const emptyInputDigest = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

	repoRoot := t.TempDir()
	hash, err := computeEngineHash(repoRoot)
	if err == nil {
		t.Fatalf("computeEngineHash on a repo with no .substrate returned hash %q, want an error", hash)
	}
	if hash == emptyInputDigest {
		t.Fatalf("computeEngineHash returned the empty-input digest instead of an error")
	}
}

func TestEngineHashNonDirectoryRootErrors(t *testing.T) {
	const emptyInputDigest = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

	repoRoot := t.TempDir()
	if err := os.WriteFile(filepath.Join(repoRoot, ".substrate"), []byte("oops\n"), 0o644); err != nil {
		t.Fatalf("write stray .substrate file: %v", err)
	}
	hash, err := computeEngineHash(repoRoot)
	if err == nil {
		t.Fatalf("computeEngineHash with a non-directory .substrate returned hash %q, want an error", hash)
	}
	if hash == emptyInputDigest {
		t.Fatalf("computeEngineHash returned the empty-input digest instead of an error")
	}
}

// R5: an existing, walkable, but EMPTY .substrate must also fail closed —
// hashRecords(nil) is the ordinary-looking sha256(""), not a refusal.
func TestEngineHashEmptyDirectoryErrors(t *testing.T) {
	const emptyInputDigest = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

	repoRoot := t.TempDir()
	if err := os.Mkdir(filepath.Join(repoRoot, ".substrate"), 0o755); err != nil {
		t.Fatalf("mkdir .substrate: %v", err)
	}
	hash, err := computeEngineHash(repoRoot)
	if err == nil {
		t.Fatalf("computeEngineHash on an empty .substrate returned hash %q (reusable:true), want an error", hash)
	}
	if hash == emptyInputDigest {
		t.Fatalf("computeEngineHash returned the empty-input digest instead of an error")
	}
}
