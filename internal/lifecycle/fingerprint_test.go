package lifecycle

import (
	"testing"

	"github.com/mp-pinheiro/substrate/internal/canonjson"
)

// Golden values derived from the pinned jq (1.7.1): `jq -cnS --arg revision
// ... --argjson entries ... '{revision:$revision,entries:$entries}' | sha256sum`.
func TestFingerprintMatchesPinnedJQ(t *testing.T) {
	cases := []struct {
		name     string
		revision string
		entries  map[string]string
		want     string
	}{
		{
			name:     "populated",
			revision: "abc123",
			entries:  map[string]string{"foo.txt": "file:deadbeef", "bar.txt": "deleted"},
			want:     "ee32cdb3cd36f7ada0a8f922aa4ee9377f9e13a4e4632091c9b4811e21f66116",
		},
		{
			name:     "empty",
			revision: "",
			entries:  map[string]string{},
			want:     "985ee9624231426db3f8342097bb03f5d2c34ae4716b73a85ebaa336b6281b04",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			entries := canonjson.NewObject()
			for _, k := range []string{"foo.txt", "bar.txt"} {
				if v, ok := tc.entries[k]; ok {
					entries.Set(k, v)
				}
			}
			got, err := fingerprint(tc.revision, entries)
			if err != nil {
				t.Fatalf("fingerprint: %v", err)
			}
			if got != tc.want {
				t.Fatalf("fingerprint() = %q, want %q", got, tc.want)
			}
		})
	}
}
