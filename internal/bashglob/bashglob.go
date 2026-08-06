// Package bashglob implements bash's `case "$name" in $pattern)` matching:
// * and ? cross '/', [...] is a POSIX bracket expression, \x escapes.
package bashglob

type tokenKind uint8

const (
	tokLiteral tokenKind = iota
	tokAny
	tokStar
	tokClass
)

type member struct {
	isClass bool
	class   string
	lo, hi  rune
}

func (m member) match(r rune) bool {
	if m.isClass {
		return matchPosixClass(m.class, r)
	}
	return r >= m.lo && r <= m.hi
}

type token struct {
	kind    tokenKind
	r       rune
	negate  bool
	members []member
}

func (t token) match(r rune) bool {
	switch t.kind {
	case tokLiteral:
		return t.r == r
	case tokAny:
		return true
	case tokClass:
		found := false
		for _, m := range t.members {
			if m.match(r) {
				found = true
				break
			}
		}
		return found != t.negate
	default:
		return false
	}
}

// Bash case-pattern semantics: * and ? cross '/', the match is anchored to the
// whole string, and there is no extglob or leading-dot rule.
func Match(pattern, name string) bool {
	toks, poisoned := tokenize(pattern)
	if poisoned {
		return false
	}
	return matchTokens(toks, []rune(name))
}

func tokenize(pattern string) ([]token, bool) {
	runes := []rune(pattern)
	toks := make([]token, 0, len(runes))
	i := 0
	for i < len(runes) {
		c := runes[i]
		switch c {
		case '\\':
			if i+1 < len(runes) {
				toks = append(toks, token{kind: tokLiteral, r: runes[i+1]})
				i += 2
			} else {
				toks = append(toks, token{kind: tokLiteral, r: '\\'})
				i++
			}
		case '*':
			toks = append(toks, token{kind: tokStar})
			i++
		case '?':
			toks = append(toks, token{kind: tokAny})
			i++
		case '[':
			tok, consumed, poisoned, ok := parseBracket(runes, i)
			if poisoned {
				return nil, true
			}
			if ok {
				toks = append(toks, tok)
				i += consumed
			} else {
				toks = append(toks, token{kind: tokLiteral, r: '['})
				i++
			}
		default:
			toks = append(toks, token{kind: tokLiteral, r: c})
			i++
		}
	}
	return toks, false
}

func matchTokens(toks []token, name []rune) bool {
	i, j := 0, 0
	starIdx, starMatch := -1, -1
	for i < len(name) {
		switch {
		case j < len(toks) && toks[j].kind != tokStar && toks[j].match(name[i]):
			i++
			j++
		case j < len(toks) && toks[j].kind == tokStar:
			starIdx = j
			starMatch = i
			j++
		case starIdx != -1:
			starMatch++
			i = starMatch
			j = starIdx + 1
		default:
			return false
		}
	}
	for j < len(toks) && toks[j].kind == tokStar {
		j++
	}
	return j == len(toks)
}
