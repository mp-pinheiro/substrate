package xshell

import (
	"os"
	"strings"
)

// ResolveCtypeLocale mirrors glibc's environment resolution for LC_CTYPE:
// LC_ALL overrides LC_CTYPE, which overrides LANG.
func ResolveCtypeLocale() string {
	for _, key := range []string{"LC_ALL", "LC_CTYPE", "LANG"} {
		if v, ok := os.LookupEnv(key); ok && v != "" {
			return v
		}
	}
	return "C"
}

func IsUTF8Locale() bool {
	loc := strings.ToUpper(ResolveCtypeLocale())
	return strings.Contains(loc, "UTF-8") || strings.Contains(loc, "UTF8")
}
