package recovery

import (
	"fmt"
	"strings"

	"github.com/mp-pinheiro/substrate/internal/canonjson"
	"github.com/mp-pinheiro/substrate/internal/logx"
)

type Report struct {
	Status  string   `json:"status"`
	Code    string   `json:"code"`
	Owner   string   `json:"owner"`
	Retry   string   `json:"retry"`
	Summary string   `json:"summary"`
	Details []string `json:"details"`
	Next    string   `json:"next"`
}

func (r Report) value() canonjson.Value {
	details := make([]canonjson.Value, len(r.Details))
	for i, detail := range r.Details {
		details[i] = detail
	}
	return canonjson.NewObject().
		Set("status", r.Status).
		Set("code", r.Code).
		Set("owner", r.Owner).
		Set("retry", r.Retry).
		Set("summary", r.Summary).
		Set("details", details).
		Set("next", r.Next)
}

// JSONLine returns the canonical machine-readable representation with a final
// newline, suitable for the last line of --json command output.
func (r Report) JSONLine() (string, error) {
	data, err := canonjson.MarshalSorted(r.value())
	if err != nil {
		return "", fmt.Errorf("recovery: encode report: %w", err)
	}
	return string(data) + "\n", nil
}

func label(r Report) string {
	return r.Label()
}

func (r Report) Label() string {
	if r.Status == "incomplete" {
		return "[substrate — checkpoint incomplete]"
	}
	if r.Owner == "user" {
		return "[substrate — hand to user]"
	}
	return "[substrate — fix before proceeding]"
}

func (r Report) Human() {
	w := logx.Err()
	w.Line("%s %s", label(r), r.Summary)
	for _, detail := range r.Details {
		for _, line := range strings.Split(strings.TrimSuffix(detail, "\n"), "\n") {
			w.Line("  %s", line)
		}
	}
	if r.Next != "" {
		w.Line("next: %s", r.Next)
	}
}

// Emit writes the report in the requested protocol. Human output is stderr;
// JSON is stdout so callers can consume the final line without losing checks.
func Emit(r Report, jsonMode bool) int {
	if !jsonMode {
		r.Human()
		return 0
	}
	line, err := r.JSONLine()
	if err != nil {
		logx.Err().Line("substrate: %v", err)
		return 1
	}
	logx.Out().Print(line)
	return 0
}
