package vcs

import "strings"

const arrowSep = " => "

func ResolveRename(p string) string {
	if resolved, ok := resolveBraceRename(p); ok {
		return resolved
	}
	if idx := strings.LastIndex(p, arrowSep); idx >= 0 {
		return p[idx+len(arrowSep):]
	}
	if idx := strings.LastIndex(p, " -> "); idx >= 0 {
		return p[idx+len(" -> "):]
	}
	return p
}

func resolveBraceRename(p string) (string, bool) {
	braceIdx := strings.IndexByte(p, '{')
	if braceIdx < 0 {
		return "", false
	}
	rest := p[braceIdx+1:]
	arrowIdx := strings.Index(rest, arrowSep)
	if arrowIdx < 0 {
		return "", false
	}
	if !strings.Contains(rest[arrowIdx+len(arrowSep):], "}") {
		return "", false
	}
	closeIdx := strings.IndexByte(rest, '}')
	pre := p[:braceIdx]
	mid := rest[:closeIdx]
	post := rest[closeIdx+1:]
	afterArrow := mid
	if lastArrow := strings.LastIndex(mid, arrowSep); lastArrow >= 0 {
		afterArrow = mid[lastArrow+len(arrowSep):]
	}
	return strings.ReplaceAll(pre+afterArrow+post, "//", "/"), true
}
