package hook

import (
	"io"
	"os"
	"strings"

	"github.com/mp-pinheiro/substrate/internal/canonjson"
	"github.com/mp-pinheiro/substrate/internal/config"
	"github.com/mp-pinheiro/substrate/internal/policy"
)

const msgNoDecision = "blocked: policy returned no decision level\n"

func buildInput(payload []byte, cmdPaths ...string) (policy.Input, bool) {
	in := policy.Input{Raw: payload}
	v, decodeFailed := decodePayload(payload)
	if decodeFailed {
		return in, true
	}
	if len(cmdPaths) > 0 {
		cmd, failed := jqAlt(v, cmdPaths...)
		if failed {
			return in, true
		}
		in.Command = cmd
	}
	filePath, failed := jqAlt(v, "tool_input.file_path")
	if failed {
		return in, true
	}
	in.FilePath = filePath
	session, failed := jqAlt(v, "session_id")
	if failed {
		return in, true
	}
	in.SessionID = session
	event, failed := jqAlt(v, "hook_event_name")
	if failed {
		return in, true
	}
	in.HookEvent = event
	return in, false
}

func render(in policy.Input, d policy.Decision) int {
	stdout, stderr, code := hookOutput(d, in.HookEvent == "PreToolUse")
	writeResult(stdout, stderr)
	return code
}

func hookOutput(d policy.Decision, canAsk bool) (stdout, stderr []byte, code int) {
	switch d.Level {
	case policy.LevelAllow:
		return nil, nil, 0
	case policy.LevelBlock:
		return nil, []byte(d.Message), 2
	case policy.LevelAsk:
		if !canAsk {
			return nil, []byte("blocked: " + d.Message + " This harness cannot ask the user, so the change is blocked; hand it to the user.\n"), 2
		}
		return preToolUseOutput(canonjson.NewObject().Set("hookSpecificOutput", canonjson.NewObject().
			Set("hookEventName", "PreToolUse").
			Set("permissionDecision", "ask").
			Set("permissionDecisionReason", d.Message)))
	case policy.LevelWarn:
		return preToolUseOutput(canonjson.NewObject().
			Set("hookSpecificOutput", canonjson.NewObject().
				Set("hookEventName", "PreToolUse").
				Set("additionalContext", d.Message)).
			Set("systemMessage", d.Message))
	}
	return nil, []byte(msgNoDecision), 2
}

func preToolUseOutput(doc *canonjson.Object) (stdout, stderr []byte, code int) {
	body, err := canonjson.Marshal(doc)
	if err != nil {
		return nil, []byte(msgNoDecision), 2
	}
	return append(body, '\n'), nil, 0
}

func pathInput(e env, stdin io.Reader) (policy.Input, *config.Config) {
	payload, _ := io.ReadAll(stdin)
	in, _ := buildInput(payload)
	if in.FilePath == "" {
		return in, nil
	}
	cfg, _ := config.LoadConfig(e.paths().ConfigPath)
	return in, cfg
}

func dispatchProtectPaths(e env, stdin io.Reader) int {
	in, cfg := pathInput(e, stdin)
	if in.FilePath == "" {
		return 0
	}
	return render(in, policy.ProtectPaths(in, cfg, e.repoRoot))
}

func dispatchCheckHard(e env, stdin io.Reader) int {
	in, cfg := pathInput(e, stdin)
	if in.FilePath == "" {
		return 0
	}
	d := policy.CheckpointDecision(in.FilePath, cfg)
	switch d.Level {
	case policy.LevelAllow, policy.LevelWarn:
		return 0
	case policy.LevelAsk, policy.LevelBlock:
		writeResult(nil, []byte(strings.TrimSuffix(d.Message, "\n")+"\n"))
		return 2
	}
	writeResult(nil, []byte(msgNoDecision))
	return 2
}

func dispatchProtectCommand(e env, stdin io.Reader) int {
	payload, _ := io.ReadAll(stdin)
	in, decodeFailed := buildInput(payload, "tool_input.command", "command")
	if decodeFailed {
		return render(in, policy.Decision{Level: policy.LevelBlock, Message: "blocked: malformed Bash tool payload\n"})
	}
	if in.Command == "" {
		return 0
	}
	in.RepoRoot = e.repoRoot
	cfgPath := e.paths().ConfigPath
	info, statErr := os.Stat(cfgPath)
	present := statErr == nil && !info.IsDir()
	var cfg *config.Config
	corrupt := false
	if present {
		loaded, loadErr := config.LoadConfig(cfgPath)
		if loadErr != nil {
			corrupt = true
		} else {
			cfg = loaded
		}
	}
	return render(in, policy.ProtectCommand(in, cfg, present, corrupt))
}

func dispatchEnforceJJ(e env, stdin io.Reader) int {
	payload, _ := io.ReadAll(stdin)
	in, decodeFailed := buildInput(payload, "tool_input.command", "command")
	if decodeFailed {
		in.Command = ""
	}
	return render(in, policy.EnforceJJ(in, e.repoRoot))
}

func dispatchEnforceConventionalCommits(e env, stdin io.Reader) int {
	payload, _ := io.ReadAll(stdin)
	in, decodeFailed := buildInput(payload, "tool_input.command", "command")
	if decodeFailed {
		in.Command = ""
	}
	return render(in, policy.EnforceConventionalCommits(in, e.repoRoot))
}
