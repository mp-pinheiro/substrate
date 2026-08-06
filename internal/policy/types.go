package policy

import (
	"fmt"
	"regexp"
	"strings"
)

type Input struct {
	Raw       []byte
	Command   string
	FilePath  string
	SessionID string
}

type Decision struct {
	Block  bool
	Stderr string
	Code   int
}

func block(format string, a ...any) Decision {
	return Decision{Block: true, Code: 2, Stderr: fmt.Sprintf(format, a...)}
}

// A6: grep is line-oriented; split the subject and test each line so RE2
// classes like [[:space:]] never span a newline the way (?s)/(?m) would.
func matchAnyLine(re *regexp.Regexp, subject string) bool {
	for _, line := range strings.Split(subject, "\n") {
		if re.MatchString(line) {
			return true
		}
	}
	return false
}

func containsAnyLine(needle, subject string) bool {
	for _, line := range strings.Split(subject, "\n") {
		if strings.Contains(line, needle) {
			return true
		}
	}
	return false
}
