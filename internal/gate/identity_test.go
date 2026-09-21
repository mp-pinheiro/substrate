package gate

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestVerifyEngineIdentity(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name        string
		source      string
		version     string
		revision    string
		alterEngine bool
		wantError   string
	}{
		{name: "worktree match", source: "worktree", version: "0.1.0", revision: "worktree"},
		{name: "worktree version mismatch", source: "worktree", version: "0.0.0-dev", revision: "worktree", wantError: "worktree requires"},
		{name: "trunk match", source: "trunk", version: "0.1.0", revision: strings.Repeat("a", 40)},
		{name: "trunk binary mismatch", source: "trunk", version: "0.1.0", revision: strings.Repeat("a", 40), alterEngine: true, wantError: "running engine sha256"},
		{name: "trunk revision malformed", source: "trunk", version: "0.1.0", revision: "main", wantError: "invalid trunk kitRevision"},
		{name: "release match", source: "release", version: "0.1.0+release", revision: "0.1.0"},
		{name: "release module match", source: "release", version: "0.1.0+module", revision: "0.1.0"},
		{name: "release channel mismatch", source: "release", version: "0.1.0", revision: "0.1.0", wantError: "requires"},
		{name: "source unsupported", source: "local", version: "0.1.0", revision: "local", wantError: "unsupported vendor source"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			root := t.TempDir()
			substrateDir := filepath.Join(root, ".substrate")
			if err := os.Mkdir(substrateDir, 0o755); err != nil {
				t.Fatal(err)
			}
			executable := filepath.Join(root, "substrate-engine")
			original := []byte("engine")
			if err := os.WriteFile(executable, original, 0o755); err != nil {
				t.Fatal(err)
			}
			sum := sha256.Sum256(original)
			writeJSON(t, filepath.Join(substrateDir, "vendor.json"), vendorIdentity{KitRevision: tt.revision, Source: tt.source, Version: "0.1.0"})
			writeJSON(t, filepath.Join(substrateDir, "engine.json"), engineIdentity{Version: "0.1.0", BinarySHA256: hex.EncodeToString(sum[:])})
			if tt.alterEngine {
				if err := os.WriteFile(executable, []byte("other engine"), 0o755); err != nil {
					t.Fatal(err)
				}
			}

			err := verifyEngineIdentity(root, tt.version, executable)
			if tt.wantError == "" {
				if err != nil {
					t.Fatalf("verifyEngineIdentity() error = %v", err)
				}
				return
			}
			if err == nil || !strings.Contains(err.Error(), tt.wantError) {
				t.Fatalf("verifyEngineIdentity() error = %v, want substring %q", err, tt.wantError)
			}
		})
	}
}

func writeJSON(t *testing.T, path string, value any) {
	t.Helper()
	data, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, data, 0o644); err != nil {
		t.Fatal(err)
	}
}
