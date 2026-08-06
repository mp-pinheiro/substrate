package xshell

import "strings"

// CleanCommandSubst mirrors bash's $(...) substitution: it drops embedded NUL
// bytes and trims only trailing newlines, not all trailing whitespace.
func CleanCommandSubst(s string) string {
	s = strings.ReplaceAll(s, "\x00", "")
	return strings.TrimRight(s, "\n")
}
