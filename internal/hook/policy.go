package hook

import (
	"io"
	"os"

	"github.com/mp-pinheiro/substrate/internal/config"
	"github.com/mp-pinheiro/substrate/internal/policy"
)

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
	return in, false
}

func render(d policy.Decision) int {
	if d.Block {
		writeResult(nil, []byte(d.Stderr))
		return d.Code
	}
	return 0
}

func dispatchProtectPaths(e env, stdin io.Reader) int {
	payload, _ := io.ReadAll(stdin)
	in, _ := buildInput(payload)
	if in.FilePath == "" {
		return 0
	}
	cfg, err := config.LoadConfig(e.paths().ConfigPath)
	if err != nil {
		cfg = nil
	}
	return render(policy.ProtectPaths(in, cfg, e.repoRoot))
}
func dispatchCheckHard(stdin io.Reader) int {
	payload, _ := io.ReadAll(stdin)
	in, _ := buildInput(payload)
	if in.FilePath == "" {
		return 0
	}
	decision, blocked := policy.CheckHard(in.FilePath)
	if !blocked {
		return 0
	}
	return render(decision)
}

func dispatchProtectCommand(e env, stdin io.Reader) int {
	payload, _ := io.ReadAll(stdin)
	in, decodeFailed := buildInput(payload, "tool_input.command", "command")
	if decodeFailed {
		return render(policy.Decision{Block: true, Code: 2, Stderr: "blocked: malformed Bash tool payload\n"})
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
	return render(policy.ProtectCommand(in, cfg, present, corrupt))
}

func dispatchEnforceJJ(e env, stdin io.Reader) int {
	payload, _ := io.ReadAll(stdin)
	in, decodeFailed := buildInput(payload, "tool_input.command", "command")
	if decodeFailed {
		in.Command = ""
	}
	return render(policy.EnforceJJ(in, e.repoRoot))
}

func dispatchEnforceConventionalCommits(e env, stdin io.Reader) int {
	payload, _ := io.ReadAll(stdin)
	in, decodeFailed := buildInput(payload, "tool_input.command", "command")
	if decodeFailed {
		in.Command = ""
	}
	return render(policy.EnforceConventionalCommits(in, e.repoRoot))
}
