package lifecycle

import (
	"os"
	"path/filepath"
	"testing"
)

func TestReadLedgerRejectsScalarInitialOnly(t *testing.T) {
	cases := []struct {
		name    string
		content string
		wantErr bool
	}{
		{"valid object", `{"session":"s1","initial":{"revision":"r1"}}`, false},
		{"missing initial", `{"session":"s1"}`, false},
		{"null initial", `{"session":"s1","initial":null}`, false},
		{"string initial", `{"session":"s1","initial":"x"}`, true},
		{"number initial", `{"session":"s1","initial":42}`, true},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "s1.json")
			if err := os.WriteFile(path, []byte(tc.content), 0o600); err != nil {
				t.Fatal(err)
			}
			_, err := readLedger(path)
			if (err != nil) != tc.wantErr {
				t.Errorf("readLedger(%q) err = %v, wantErr %v", tc.content, err, tc.wantErr)
			}
		})
	}
}
