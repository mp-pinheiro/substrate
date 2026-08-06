package policy

import (
	"regexp"
	"strings"

	"github.com/mp-pinheiro/substrate/internal/xshell"
)

const posixSpaceToken = "[:space:]"

// Derived from /usr/bin/grep, not Unicode White_Space: glibc's iswspace() drops U+2007
// and excludes U+00A0/U+0085/U+202F/U+200B in both locales.
const utf8SpaceBody = `\t\n\v\f\r \x{1680}\x{2000}-\x{2006}\x{2008}-\x{200A}\x{2028}\x{2029}\x{205F}\x{3000}`

// Compiled twice because LC_ALL can differ between calls within one process.
type localeRegexp struct {
	ascii *regexp.Regexp
	utf8  *regexp.Regexp
}

func compileLocaleRegexp(pattern string) localeRegexp {
	return localeRegexp{
		ascii: regexp.MustCompile(pattern),
		utf8:  regexp.MustCompile(strings.ReplaceAll(pattern, posixSpaceToken, utf8SpaceBody)),
	}
}

func (lr localeRegexp) match(subject string) bool {
	re := lr.ascii
	if xshell.IsUTF8Locale() {
		re = lr.utf8
	}
	return matchAnyLine(re, subject)
}
