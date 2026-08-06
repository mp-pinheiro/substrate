package bashglob

import "testing"

// Expectations were verified against real bash 5.2.21 `case` matching; see
// the port report for the probe script and transcript.
func TestMatch(t *testing.T) {
	cases := []struct {
		pattern string
		name    string
		want    bool
	}{
		// star and question mark cross '/', unlike filepath.Match.
		{"*.md", "README.md", true},
		{"*.md", "docs/contracts.md", true},
		{"*.md", "a/b/c.md", true},
		{"*.md", "README.mdx", false},
		{"a?b", "a/b", true},
		{"a?b", "ab", false},
		{"a?b", "aXb", true},
		{"***", "anything/at/all", true},
		{"a**b", "aXXXb", true},

		// substrate.json unscanned/protected_paths vectors, hit and miss.
		{"**/*.md", "README.md", false},
		{"**/*.md", "docs/contracts.md", true},
		{"**/*.md", "a/b/c.md", true},
		{".omp/**", ".omp/lsp.json", true},
		{".omp/**", ".omp/agents/claude/x.md", true},
		{".omp/**", ".omprc", false},
		{".omp/**", "x/.omp/lsp.json", false},
		{".substrate/**", ".substrate/gate-lib.sh", true},
		{".substrate/**", ".substrate/checks.d/x.sh", true},
		{".substrate/**", "substrate.json", false},
		{"profiles/*/fixtures/**", "profiles/go/fixtures/a.go", true},
		{"profiles/*/fixtures/**", "profiles/go/fixtures/sub/a.go", true},
		{"profiles/*/fixtures/**", "profiles/go/templates/a.go", false},
		{"profiles/*/fixtures/**", "profiles/go/x/fixtures/a.go", true},
		{"test/golden/**", "test/golden/vectors.json", true},
		{"test/golden/**", "test/golden/sub/vectors.json", true},
		{"test/golden/**", "test/expected/vectors.json", false},
		{".env*", ".env", true},
		{".env*", ".env.local", true},
		{".env*", "x/.env", false},
		{".env*", "env", false},
		{"**/.env*", ".env", false},
		{"**/.env*", "x/.env", true},
		{"**/.env*", "x/y/.env.local", true},
		{"*.key", "server.key", true},
		{"*.key", "x/server.key", true},
		{"secrets/**", "secrets/a.txt", true},
		{"secrets/**", "secrets/sub/a.txt", true},
		{"secrets/**", "x/secrets/a.txt", false},
		{"**/secrets/**", "x/secrets/a.txt", true},
		{"**/secrets/**", "secrets/a.txt", false},
		{"**/secrets/**", "x/y/secrets/a.txt", true},
		{"Dockerfile*", "Dockerfile", true},
		{"Dockerfile*", "Dockerfile.dev", true},
		{"Dockerfile*", "x/Dockerfile", false},
		{"LICENSE*", "LICENSE", true},
		{"LICENSE*", "LICENSE.md", true},
		{"LICENSE*", "x/LICENSE", false},

		{"[a-c]", "b", true},
		{"[a-c]", "d", false},
		{"[!a]", "b", true},
		{"[!a]", "a", false},
		{"[^a]", "b", true},
		{"[^a]", "a", false},
		{"[a-cx]", "x", true},
		{"[a-cx]", "d", false},
		{"[-abc]", "-", true},
		{"[abc-]", "-", true},

		// ']' as the first bracket member is literal, even negated.
		{"[]]", "]", true},
		{"[]]", "x", false},
		{"[!]]", "]", false},
		{"[!]]", "x", true},
		{"[^]]", "]", false},
		{"[^]]", "x", true},

		{"[[:digit:]]", "5", true},
		{"[[:digit:]]", "x", false},
		{"[[:alpha:][:digit:]]", "5", true},
		{"[!0-9]", "a", true},
		{"[[:upper:]]", "A", true},
		{"[[:upper:]]", "a", false},
		{"[[:punct:]]", "!", true},
		{"[[:punct:]]", "a", false},
		{"[[:blank:]]", " ", true},
		{"[[:blank:]]", "\t", true},
		{"[[:blank:]]", "\n", false},
		{"[[:cntrl:]]", "\x01", true},
		{"[[:graph:]]", " ", false},
		{"[[:graph:]]", "x", true},
		{"[[:print:]]", " ", true},
		{"[[:xdigit:]]", "f", true},
		{"[[:xdigit:]]", "g", false},
		{"[[:digit:]abc]", "a", true},
		{"[[:digit:]abc]", "5", true},
		{"[[:digit:]abc]", "z", false},

		{"[[:word:]]", "a", true},
		{"[[:word:]]", "_", true},
		{"[[:word:]]", "9", true},
		{"[[:word:]]", "!", false},
		{"[[.a.]]", "a", true},
		{"[[.a.]]", "b", false},
		{"[[=a=]]", "a", true},
		{"[[=a=]]", "b", false},
		{"[[.ab.]]", "ab", false},
		{"[a[.b.]c]", "b", true},

		{"a\\*b", "a*b", true},
		{"a\\*b", "aXb", false},
		{"a\\?b", "a?b", true},
		{"a\\[b", "a[b", true},
		{"[\\]a]", "a", true},
		{"[\\]a]", "]", true},
		{"[\\]a]", "\\", false},
		{"[\\\\]", "\\", true},
		{"[\\\\]", "x", false},
		{"[\\a-z]", "a", true},
		{"[\\a-z]", "b", true},
		{"[\\a-z]", "z", true},
		{"[\\a-z]", "-", false},

		// a dangling trailing backslash (nothing to escape) is literal
		// outside brackets...
		{"a\\", "a\\", true},
		{"a\\", "a", false},

		// a trailing dangling backslash is poisoned (matches nothing, ever)
		// when it directly follows a run of only '*'/'?' containing a '*'.
		{"*\\", "\\", false},
		{"a*\\", "a\\", false},
		{"**\\", "\\", false},
		{"?\\", "a\\", true},
		{"*a\\", "a\\", true},

		// ...but poisons the whole pattern (matches nothing, ever) when it
		// dangles while scanning an unterminated bracket expression.
		{"a[\\", "a[\\", false},
		{"a[\\", "x", false},
		{"a[\\", "", false},
		{"a[bc\\", "a[bc\\", false},
		{"a[bc\\", "anything", false},
		{"[\\", "[\\", false},
		{"[!\\", "[!\\", false},

		// unterminated brackets (no dangling escape) fall back to a literal
		// '[' and the rest of the pattern re-tokenizes normally.
		{"a[b", "a[b", true},
		{"a[b", "ab", false},
		{"a[b*c", "a[bXXXc", true},
		{"a[b*c", "a[bc", true},
		{"a[b*c", "a[b*c", true},
		{"a[\\bc", "a[bc", true},
		{"a[\\bc", "a[\\bc", false},
		{"a[", "a[", true},
		{"a[", "a", false},
		{"[!", "[!", true},
		{"[!", "x", false},
		{"[]", "[]", true},
		{"[]", "x", false},

		{"", "", true},
		{"", "x", false},
		{"*", "", true},
		{"?", "", false},
	}

	for _, c := range cases {
		if got := Match(c.pattern, c.name); got != c.want {
			t.Errorf("Match(%q, %q) = %v, want %v", c.pattern, c.name, got, c.want)
		}
	}
}

// [[:alpha:]]/[[:alnum:]]/[[:word:]] are locale-aware: ASCII-only under C,
// but match Unicode letters under UTF-8, mirroring glibc's LC_ALL>LC_CTYPE>LANG resolution.
func TestMatchLocaleAwareClasses(t *testing.T) {
	cases := []struct {
		locale  string
		pattern string
		name    string
		want    bool
	}{
		{"C", "[[:alpha:]]", "é", false},
		{"C", "[[:alnum:]]", "ÿ", false},
		{"C", "[[:word:]]", "é", false},
		{"en_US.UTF-8", "[[:alpha:]]", "é", true},
		{"en_US.UTF-8", "[[:alnum:]]", "ÿ", true},
		{"en_US.UTF-8", "[[:word:]]", "é", true},
		{"en_US.UTF-8", "[[:alpha:]]*", "é", true},
		{"en_US.UTF-8", "[[:digit:]]", "é", false},
	}

	for _, c := range cases {
		t.Setenv("LC_ALL", c.locale)
		if got := Match(c.pattern, c.name); got != c.want {
			t.Errorf("locale=%s Match(%q, %q) = %v, want %v", c.locale, c.pattern, c.name, got, c.want)
		}
	}
}
