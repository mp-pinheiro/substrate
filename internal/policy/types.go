package policy

import (
	"fmt"
	"regexp"
	"strings"

	"github.com/mp-pinheiro/substrate/internal/recovery"
)

type Input struct {
	Raw       []byte
	Command   string
	FilePath  string
	SessionID string
	RepoRoot  string
	HookEvent string
}

type Level int

const (
	_ Level = iota
	LevelAllow
	LevelWarn
	LevelAsk
	LevelBlock
)

type Decision struct {
	Level    Level
	Message  string
	Recovery recovery.Report
}

func allow() Decision {
	return Decision{Level: LevelAllow}
}

func ask(format string, a ...any) Decision {
	return Decision{Level: LevelAsk, Message: fmt.Sprintf(format, a...)}
}

func block(format string, a ...any) Decision {
	stderr := fmt.Sprintf(format, a...)
	report := recovery.Report{
		Status: "blocked", Code: "policy.config", Owner: "agent", Retry: "after-change",
		Summary: "policy blocked the requested operation", Details: []string{strings.TrimSpace(stderr)},
		Next: "change the named path or command, then retry the sanctioned workflow",
	}
	switch {
	case strings.Contains(stderr, "baseline"):
		report.Code = "policy.baseline"
	case strings.Contains(stderr, "substrate.json"):
		report.Code = "policy.config"
	case strings.Contains(stderr, "contract"):
		report.Code = "policy.contract-output"
	case strings.Contains(stderr, "symlink"):
		report.Code = "policy.symlink"
	case strings.Contains(stderr, "protected"):
		report.Code = "policy.protected"
	case strings.Contains(stderr, "vendored") || strings.Contains(stderr, ".substrate"):
		report.Code = "policy.vendored"
	}
	if strings.Contains(stderr, "protected_paths") || strings.Contains(stderr, "user") {
		report.Owner, report.Retry, report.Next = "user", "terminal", "present this policy decision to the user; do not retry unchanged state"
	}
	if strings.Contains(stderr, "vendored") {
		report.Owner, report.Retry, report.Next = "user", "terminal", "change the kit source, then the user runs substrate update --apply --checkpoint; never commit the mirror directly"
	}
	if strings.Contains(stderr, "jj commit") || strings.Contains(stderr, "checkpoint transaction") ||
		strings.Contains(stderr, "checkpoint/baseline-transaction") {
		report.Next = "after direct verification, call substrate_checkpoint"
	}
	return Decision{Level: LevelBlock, Message: stderr, Recovery: report}
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
