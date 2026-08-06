package vcs

import "strings"

func trimTrailingNewlines(s string) string {
	return strings.TrimRight(s, "\n")
}

func splitLines(s string) []string {
	if s == "" {
		return nil
	}
	return strings.Split(strings.TrimSuffix(s, "\n"), "\n")
}
