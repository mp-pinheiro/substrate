package vcs

import "strings"

func UnquotePath(s string) string {
	if len(s) < 2 || s[0] != '"' || s[len(s)-1] != '"' {
		return s
	}
	inner := s[1 : len(s)-1]
	var b strings.Builder
	b.Grow(len(inner))
	for i := 0; i < len(inner); i++ {
		c := inner[i]
		if c != '\\' || i == len(inner)-1 {
			b.WriteByte(c)
			continue
		}
		i++
		if n, ok := decodeEscape(inner[i]); ok {
			b.WriteByte(n)
			continue
		}
		if inner[i] >= '0' && inner[i] <= '7' {
			v, consumed := decodeOctal(inner[i:])
			b.WriteByte(v)
			i += consumed - 1
			continue
		}
		b.WriteByte('\\')
		b.WriteByte(inner[i])
	}
	return b.String()
}

func decodeEscape(c byte) (byte, bool) {
	switch c {
	case '\\':
		return '\\', true
	case '"':
		return '"', true
	case 'n':
		return '\n', true
	case 't':
		return '\t', true
	case 'r':
		return '\r', true
	case 'b':
		return '\b', true
	case 'f':
		return '\f', true
	case 'v':
		return '\v', true
	case 'a':
		return '\a', true
	default:
		return 0, false
	}
}

// WHY: git's encoder always emits exactly 3 octal digits per byte; this
// caps at 3 so a 4th digit is treated as a literal following character.
func decodeOctal(s string) (byte, int) {
	n := 0
	i := 0
	for i < 3 && i < len(s) && s[i] >= '0' && s[i] <= '7' {
		n = n*8 + int(s[i]-'0')
		i++
	}
	return byte(n), i
}
