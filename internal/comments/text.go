package comments

import "strings"

func isSpaceByte(b byte) bool {
	switch b {
	case ' ', '\t', '\n', '\v', '\f', '\r':
		return true
	}
	return false
}

func trimLeadingSpace(s string) string {
	i := 0
	for i < len(s) && isSpaceByte(s[i]) {
		i++
	}
	return s[i:]
}

func hasNonSpace(s string) bool {
	for i := range s {
		if !isSpaceByte(s[i]) {
			return true
		}
	}
	return false
}

func hasASCIIAlnum(s string) bool {
	for i := range s {
		c := s[i]
		if (c >= '0' && c <= '9') || (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') {
			return true
		}
	}
	return false
}

func splitBashLines(content []byte) []string {
	s := string(content)
	if s == "" {
		return nil
	}
	parts := strings.Split(s, "\n")
	if len(parts) > 0 && parts[len(parts)-1] == "" {
		parts = parts[:len(parts)-1]
	}
	return parts
}
