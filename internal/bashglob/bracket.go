package bashglob

// bash treats a backslash with nothing left to escape inside an
// unterminated bracket as fatal — the pattern then matches nothing at all.
func parseBracket(runes []rune, start int) (tok token, consumed int, poisoned bool, ok bool) {
	j := start + 1
	if j >= len(runes) {
		return token{}, 0, false, false
	}
	negate := false
	if runes[j] == '!' || runes[j] == '^' {
		negate = true
		j++
	}

	var members []member
	first := true
	for {
		if j >= len(runes) {
			return token{}, 0, false, false
		}
		c := runes[j]
		if c == ']' && !first {
			j++
			return token{kind: tokClass, negate: negate, members: members}, j - start, false, true
		}
		first = false

		if c == '[' && j+1 < len(runes) && runes[j+1] == ':' {
			if end := classNameEnd(runes, j+2); end >= 0 {
				members = append(members, member{isClass: true, class: string(runes[j+2 : end])})
				j = end + 2
				continue
			}
			members = append(members, member{lo: c, hi: c})
			j++
			continue
		}

		if c == '[' && j+1 < len(runes) && (runes[j+1] == '.' || runes[j+1] == '=') {
			end := markerEnd(runes, j+2, runes[j+1])
			if end < 0 {
				return token{}, 0, false, false
			}
			if sym := runes[j+2 : end]; len(sym) == 1 {
				members = append(members, member{lo: sym[0], hi: sym[0]})
			}
			j = end + 2
			continue
		}

		lo, next, bad := resolveRune(runes, j)
		if bad {
			return token{}, 0, true, false
		}
		hi := lo
		if next < len(runes) && runes[next] == '-' && next+1 < len(runes) && runes[next+1] != ']' {
			endRune, endNext, endBad := resolveRune(runes, next+1)
			if endBad {
				return token{}, 0, true, false
			}
			hi = endRune
			next = endNext
		}
		members = append(members, member{lo: lo, hi: hi})
		j = next
	}
}

func resolveRune(runes []rune, j int) (r rune, next int, bad bool) {
	if runes[j] == '\\' {
		if j+1 >= len(runes) {
			return 0, 0, true
		}
		return runes[j+1], j + 2, false
	}
	return runes[j], j + 1, false
}

func classNameEnd(runes []rune, from int) int {
	return markerEnd(runes, from, ':')
}

func markerEnd(runes []rune, from int, marker rune) int {
	for k := from; k+1 < len(runes); k++ {
		if runes[k] == marker && runes[k+1] == ']' {
			return k
		}
	}
	return -1
}
