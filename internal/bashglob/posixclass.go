package bashglob

import (
	"unicode"

	"github.com/mp-pinheiro/substrate/internal/xshell"
)

func isAlpha(r rune) bool {
	if r < 0x80 {
		return isAsciiAlpha(r)
	}
	return xshell.IsUTF8Locale() && unicode.IsLetter(r)
}

func isAsciiAlpha(r rune) bool {
	return r >= 'A' && r <= 'Z' || r >= 'a' && r <= 'z'
}

func matchPosixClass(name string, r rune) bool {
	switch name {
	case "alpha":
		return isAlpha(r)
	case "digit":
		return r >= '0' && r <= '9'
	case "alnum":
		return isAlpha(r) || r >= '0' && r <= '9'
	case "word":
		return isAlpha(r) || r >= '0' && r <= '9' || r == '_'
	case "upper":
		return r >= 'A' && r <= 'Z'
	case "lower":
		return r >= 'a' && r <= 'z'
	case "space":
		return r == ' ' || r == '\t' || r == '\n' || r == '\v' || r == '\f' || r == '\r'
	case "blank":
		return r == ' ' || r == '\t'
	case "punct":
		return r >= '!' && r <= '/' ||
			r >= ':' && r <= '@' ||
			r >= '[' && r <= '`' ||
			r >= '{' && r <= '~'
	case "cntrl":
		return r >= 0x00 && r <= 0x1f || r == 0x7f
	case "print":
		return r >= 0x20 && r <= 0x7e
	case "graph":
		return r >= 0x21 && r <= 0x7e
	case "xdigit":
		return r >= '0' && r <= '9' || r >= 'a' && r <= 'f' || r >= 'A' && r <= 'F'
	default:
		return false
	}
}
