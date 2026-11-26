package vcs

import "testing"

func TestHasParentSegment(t *testing.T) {
	cases := map[string]bool{
		"src/routes/[...rest]/+page.svelte": false,
		"docs/v1..v2/notes.md":              false,
		"..":                                true,
		"../outside":                        true,
		"src/..":                            true,
		"src/../../outside":                 true,
	}
	for path, want := range cases {
		if got := HasParentSegment(path); got != want {
			t.Errorf("HasParentSegment(%q) = %v, want %v", path, got, want)
		}
	}
}
