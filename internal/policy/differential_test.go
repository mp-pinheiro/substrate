package policy

import (
	"bytes"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/mp-pinheiro/substrate/internal/config"
)

type payloadJSON struct {
	ToolInput struct {
		Command  string `json:"command"`
		FilePath string `json:"file_path"`
	} `json:"tool_input"`
	Command   string `json:"command"`
	SessionID string `json:"session_id"`
}

func inputFromPayload(raw []byte) Input {
	var p payloadJSON
	_ = json.Unmarshal(raw, &p)
	cmd := p.ToolInput.Command
	if cmd == "" {
		cmd = p.Command
	}
	return Input{Raw: raw, Command: cmd, FilePath: p.ToolInput.FilePath, SessionID: p.SessionID}
}

func loadCfgForTest(t *testing.T, repoRoot string) (cfg *config.Config, present, corrupt bool) {
	t.Helper()
	c, err := config.LoadConfig(filepath.Join(repoRoot, "substrate.json"))
	if err != nil {
		return nil, true, true
	}
	return c, c.Present, false
}

func pinnedJQEnv(t *testing.T) []string {
	t.Helper()
	root, err := filepath.Abs("../..")
	if err != nil {
		t.Fatalf("resolve repo root: %v", err)
	}
	jqDir := filepath.Join(root, "test", ".toolchain", "bin")
	if _, err := os.Stat(filepath.Join(jqDir, "jq")); err != nil {
		t.Fatalf("pinned jq missing at %s: %v", jqDir, err)
	}
	return append(os.Environ(), "PATH="+jqDir+":"+os.Getenv("PATH"))
}

func bashRealpath(t *testing.T, dir string) string {
	t.Helper()
	out, err := exec.Command("bash", "-c", "cd \""+dir+"\" && pwd").Output()
	if err != nil {
		t.Fatalf("resolve repo root via bash: %v", err)
	}
	return strings.TrimRight(string(out), "\n")
}

func installHook(t *testing.T, repoRoot, guard string) string {
	t.Helper()
	root, err := filepath.Abs("../..")
	if err != nil {
		t.Fatalf("resolve repo root: %v", err)
	}
	src := filepath.Join(root, "core", "hooks", guard+".sh")
	data, err := os.ReadFile(src)
	if err != nil {
		t.Fatalf("read hook source %s: %v", src, err)
	}
	data = stripEngineShimWiring(data)
	dst := filepath.Join(repoRoot, ".substrate", "hooks", guard+".sh")
	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		t.Fatalf("mkdir hooks dir: %v", err)
	}
	if err := os.WriteFile(dst, data, 0o755); err != nil {
		t.Fatalf("write hook copy: %v", err)
	}
	return dst
}

// WHY: core/hooks/*.sh grew a not-yet-functional engine-shim source+dispatch
// preamble mid-cutover; strip it so the diff exercises the guard spec only.
func stripEngineShimWiring(data []byte) []byte {
	lines := strings.Split(string(data), "\n")
	out := make([]string, 0, len(lines))
	for _, line := range lines {
		if strings.Contains(line, "engine-shim.sh") || strings.Contains(line, "substrate_engine_exec") {
			continue
		}
		out = append(out, line)
	}
	return []byte(strings.Join(out, "\n"))
}

type bashResult struct {
	stdout []byte
	stderr []byte
	code   int
}

func runBashHook(t *testing.T, scriptPath string, env []string, payload []byte) bashResult {
	t.Helper()
	cmd := exec.Command("bash", scriptPath)
	cmd.Env = env
	cmd.Stdin = bytes.NewReader(payload)
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	err := cmd.Run()
	code := 0
	if err != nil {
		var exitErr *exec.ExitError
		if errors.As(err, &exitErr) {
			code = exitErr.ExitCode()
		} else {
			t.Fatalf("run bash hook: %v", err)
		}
	}
	return bashResult{stdout: stdout.Bytes(), stderr: stderr.Bytes(), code: code}
}

type diffVector struct {
	name    string
	guard   string
	payload func(repoRoot string) map[string]any
	setup   func(t *testing.T, repoRoot string)
}

func runDifferential(t *testing.T, v diffVector) {
	t.Helper()
	repoRoot := t.TempDir()
	if v.setup != nil {
		v.setup(t, repoRoot)
	}
	repoRoot = bashRealpath(t, repoRoot)

	scriptPath := installHook(t, repoRoot, v.guard)
	payload, err := json.Marshal(v.payload(repoRoot))
	if err != nil {
		t.Fatalf("marshal payload: %v", err)
	}

	bashRes := runBashHook(t, scriptPath, pinnedJQEnv(t), payload)

	in := inputFromPayload(payload)
	var got Decision
	switch v.guard {
	case "protect-paths":
		cfg, _, corrupt := loadCfgForTest(t, repoRoot)
		if corrupt {
			cfg = nil
		}
		got = ProtectPaths(in, cfg, repoRoot)
	case "protect-command":
		cfg, present, corrupt := loadCfgForTest(t, repoRoot)
		got = ProtectCommand(in, cfg, present, corrupt)
	case "enforce-jj":
		got = EnforceJJ(in, repoRoot)
	case "enforce-conventional-commits":
		got = EnforceConventionalCommits(in, repoRoot)
	default:
		t.Fatalf("unknown guard %q", v.guard)
	}
	goCode := 0
	if got.Block {
		goCode = got.Code
	}

	if goCode != bashRes.code {
		t.Errorf("%s: exit code mismatch: go=%d bash=%d (go stderr=%q bash stderr=%q)",
			v.name, goCode, bashRes.code, got.Stderr, string(bashRes.stderr))
	}
	if got.Stderr != string(bashRes.stderr) {
		t.Errorf("%s: stderr mismatch:\n go=%q\nbash=%q", v.name, got.Stderr, string(bashRes.stderr))
	}
	if len(bashRes.stdout) != 0 {
		t.Errorf("%s: unexpected bash stdout: %q", v.name, string(bashRes.stdout))
	}
}

func writeRepoFile(t *testing.T, repoRoot, rel, content string) {
	t.Helper()
	full := filepath.Join(repoRoot, rel)
	if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
		t.Fatalf("mkdir for %s: %v", rel, err)
	}
	if err := os.WriteFile(full, []byte(content), 0o644); err != nil {
		t.Fatalf("write %s: %v", rel, err)
	}
}

func writeSubstrateJSON(t *testing.T, repoRoot, content string) {
	t.Helper()
	writeRepoFile(t, repoRoot, "substrate.json", content)
}

func makeJJRepo(t *testing.T, repoRoot string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Join(repoRoot, ".jj"), 0o755); err != nil {
		t.Fatalf("mkdir .jj: %v", err)
	}
}

func cmdPayload(cmd, session string) func(string) map[string]any {
	return func(string) map[string]any {
		return map[string]any{
			"tool_input": map[string]any{"command": cmd},
			"session_id": session,
		}
	}
}

func topLevelCmdPayload(cmd string) func(string) map[string]any {
	return func(string) map[string]any {
		return map[string]any{"command": cmd}
	}
}

func filePayload(path string) func(string) map[string]any {
	return func(string) map[string]any {
		return map[string]any{"tool_input": map[string]any{"file_path": path}}
	}
}
