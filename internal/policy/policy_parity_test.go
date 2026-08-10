package policy

import (
	"bytes"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"testing"

	"github.com/mp-pinheiro/substrate/internal/config"
)

var policyEnginePath string

func TestMain(m *testing.M) {
	root, err := filepath.Abs("../..")
	if err != nil {
		_, _ = os.Stderr.WriteString("resolve repo root: " + err.Error() + "\n")
		os.Exit(1)
	}
	tempDir, err := os.MkdirTemp("", "substrate-policy-engine-")
	if err != nil {
		_, _ = os.Stderr.WriteString("create engine temp dir: " + err.Error() + "\n")
		os.Exit(1)
	}
	policyEnginePath = filepath.Join(tempDir, "substrate-engine")
	cmd := exec.Command("go", "build", "-trimpath", "-buildvcs=false", "-o", policyEnginePath, "./cmd/substrate-engine")
	cmd.Dir = root
	if output, err := cmd.CombinedOutput(); err != nil {
		_, _ = os.Stderr.WriteString("build policy engine: " + err.Error() + "\n" + string(output))
		os.Exit(1)
	}
	code := m.Run()
	if err := os.RemoveAll(tempDir); err != nil {
		_, _ = os.Stderr.WriteString("remove engine temp dir: " + err.Error() + "\n")
		os.Exit(1)
	}
	os.Exit(code)
}

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

type engineResult struct {
	stdout []byte
	stderr []byte
	code   int
}

func runEngineHook(t *testing.T, repoRoot, guard string, payload []byte) engineResult {
	t.Helper()
	cmd := exec.Command(policyEnginePath, "hook", guard)
	cmd.Env = append(os.Environ(),
		"REPO_ROOT="+repoRoot,
		"SUBSTRATE_DIR="+filepath.Join(repoRoot, ".substrate"),
	)
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
			t.Fatalf("run engine hook: %v", err)
		}
	}
	return engineResult{stdout: stdout.Bytes(), stderr: stderr.Bytes(), code: code}
}

type parityVector struct {
	name    string
	guard   string
	payload func(repoRoot string) map[string]any
	setup   func(t *testing.T, repoRoot string)
}

func runParityVectors(t *testing.T, vectors []parityVector) {
	t.Helper()
	for _, v := range vectors {
		v := v
		t.Run(v.name, func(t *testing.T) { runEnginePolicyParity(t, v) })
	}
}

func runEnginePolicyParity(t *testing.T, v parityVector) {
	t.Helper()
	repoRoot := t.TempDir()
	if v.setup != nil {
		v.setup(t, repoRoot)
	}
	repoRoot, err := filepath.Abs(repoRoot)
	if err != nil {
		t.Fatalf("resolve temporary repo root: %v", err)
	}

	payload, err := json.Marshal(v.payload(repoRoot))
	if err != nil {
		t.Fatalf("marshal payload: %v", err)
	}

	engineRes := runEngineHook(t, repoRoot, v.guard, payload)

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

	if goCode != engineRes.code {
		t.Errorf("%s: exit code mismatch: go=%d engine=%d (go stderr=%q engine stderr=%q)",
			v.name, goCode, engineRes.code, got.Stderr, string(engineRes.stderr))
	}
	if got.Stderr != string(engineRes.stderr) {
		t.Errorf("%s: stderr mismatch:\n go=%q\nengine=%q", v.name, got.Stderr, string(engineRes.stderr))
	}
	if len(engineRes.stdout) != 0 {
		t.Errorf("%s: unexpected engine stdout: %q", v.name, string(engineRes.stdout))
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
