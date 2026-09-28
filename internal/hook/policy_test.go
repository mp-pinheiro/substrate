package hook

import (
	"testing"

	"github.com/mp-pinheiro/substrate/internal/policy"
)

func TestHookOutputProtocol(t *testing.T) {
	cases := []struct {
		name   string
		d      policy.Decision
		legacy bool
		stdout string
		stderr string
		code   int
	}{
		{name: "allow", d: policy.Decision{Level: policy.LevelAllow}},
		{name: "block", d: policy.Decision{Level: policy.LevelBlock, Message: "blocked: x\n"}, stderr: "blocked: x\n", code: 2},
		{
			name:   "ask",
			d:      policy.Decision{Level: policy.LevelAsk, Message: "review \"x\""},
			stdout: `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"review \"x\""}}` + "\n",
		},
		{
			name:   "ask from a harness without the PreToolUse protocol blocks",
			d:      policy.Decision{Level: policy.LevelAsk, Message: "review x."},
			legacy: true,
			stderr: "blocked: review x. This harness cannot ask the user, so the change is blocked; hand it to the user.\n",
			code:   2,
		},
		{
			name:   "warn",
			d:      policy.Decision{Level: policy.LevelWarn, Message: "note x"},
			stdout: `{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"note x"},"systemMessage":"note x"}` + "\n",
		},
		{name: "unset level fails closed", d: policy.Decision{Message: "ignored"}, stderr: msgNoDecision, code: 2},
		{name: "unknown level fails closed", d: policy.Decision{Level: policy.LevelBlock + 1}, stderr: msgNoDecision, code: 2},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			stdout, stderr, code := hookOutput(c.d, !c.legacy)
			if string(stdout) != c.stdout || string(stderr) != c.stderr || code != c.code {
				t.Fatalf("got stdout=%q stderr=%q code=%d, want stdout=%q stderr=%q code=%d",
					stdout, stderr, code, c.stdout, c.stderr, c.code)
			}
		})
	}
}
