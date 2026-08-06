package bashglob

func matchPosixClass(name string, r rune) bool {
	switch name {
	case "alpha":
		return r >= 'A' && r <= 'Z' || r >= 'a' && r <= 'z'
	case "digit":
		return r >= '0' && r <= '9'
	case "alnum":
		return r >= 'A' && r <= 'Z' || r >= 'a' && r <= 'z' || r >= '0' && r <= '9'
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
