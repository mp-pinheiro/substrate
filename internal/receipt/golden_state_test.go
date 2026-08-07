package receipt

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"testing"

	"github.com/mp-pinheiro/substrate/internal/canonjson"
	"github.com/mp-pinheiro/substrate/internal/jqx"
	"github.com/mp-pinheiro/substrate/internal/xshell"
)

func runGit(t *testing.T, dir string, args ...string) {
	t.Helper()
	cmd := exec.Command("git", args...)
	cmd.Dir = dir
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("git %v: %v\n%s", args, err, out)
	}
}

// initGitFixture creates a git-initialized repo with substrate.json seeded;
// callers add whatever else they need before committing.
func initGitFixture(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	runGit(t, root, "init", "-q", "--initial-branch=main")
	runGit(t, root, "config", "user.name", "substrate")
	runGit(t, root, "config", "user.email", "substrate@localhost")
	writeMinimalSubstrateJSON(t, root)
	return root
}

func writeMinimalSubstrateJSON(t *testing.T, root string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(root, "substrate.json"),
		[]byte(`{"version":1,"profiles":[],"contracts":[]}`+"\n"), 0o644); err != nil {
		t.Fatalf("write substrate.json: %v", err)
	}
}

func newStateFixture(t *testing.T) string {
	t.Helper()
	root := initGitFixture(t)
	if err := os.WriteFile(filepath.Join(root, "tracked.txt"), []byte("tracked\n"), 0o644); err != nil {
		t.Fatalf("write tracked.txt: %v", err)
	}
	runGit(t, root, "add", "-A")
	runGit(t, root, "commit", "-qm", "chore: initialize")
	return root
}

func requireRefusal(t *testing.T, state *State, err error, want RefusalReason) {
	t.Helper()
	if state != nil {
		t.Fatalf("got a non-nil state alongside a refusal: %+v", state)
	}
	var refusal *Refusal
	if !errors.As(err, &refusal) {
		t.Fatalf("err = %v, want a *Refusal", err)
	}
	if refusal.Reason != want {
		t.Fatalf("refusal reason = %q, want %q", refusal.Reason, want)
	}
}

// Each of B5's refusal conditions must surface as a typed Refusal, never a
// digest, so callers can tell "invalid" from "recipe error".
func TestBuildStateRefusals(t *testing.T) {
	ctx := context.Background()

	t.Run("SUBSTRATE_FILE_LIST set", func(t *testing.T) {
		root := newStateFixture(t)
		t.Setenv("SUBSTRATE_FILE_LIST", "some/file.txt")
		state, err := BuildState(ctx, root)
		requireRefusal(t, state, err, ReasonFileListScoped)
	})

	t.Run("non-empty contracts", func(t *testing.T) {
		root := newStateFixture(t)
		contracts := `{"version":1,"profiles":[],"contracts":[{"name":"x","regen":"true","paths":["x"]}]}` + "\n"
		if err := os.WriteFile(filepath.Join(root, "substrate.json"), []byte(contracts), 0o644); err != nil {
			t.Fatalf("write substrate.json: %v", err)
		}
		state, err := BuildState(ctx, root)
		requireRefusal(t, state, err, ReasonContractsPresent)
	})

	t.Run("dirty working copy", func(t *testing.T) {
		root := newStateFixture(t)
		f := filepath.Join(root, "tracked.txt")
		existing, err := os.ReadFile(f)
		if err != nil {
			t.Fatalf("read tracked.txt: %v", err)
		}
		if err := os.WriteFile(f, append(existing, []byte("dirty\n")...), 0o644); err != nil {
			t.Fatalf("dirty tracked.txt: %v", err)
		}
		state, err := BuildState(ctx, root)
		requireRefusal(t, state, err, ReasonWorkingCopyDirty)
	})

	t.Run("jj metadata present but jj unresolvable", func(t *testing.T) {
		root := t.TempDir()
		writeMinimalSubstrateJSON(t, root)
		if err := os.Mkdir(filepath.Join(root, ".jj"), 0o755); err != nil {
			t.Fatalf("mkdir .jj: %v", err)
		}
		t.Setenv("PATH", t.TempDir())
		state, err := BuildState(ctx, root)
		requireRefusal(t, state, err, ReasonJJUnresolvable)
	})
}

// R6/C18: the embedded .state must be the SAME rendering that gets hashed
// (MarshalSorted), so sha256(compact .state + LF) == .fingerprint.
func TestWriteEmbedsSelfAuditableState(t *testing.T) {
	ctx := context.Background()
	root := initGitFixture(t)
	if err := os.MkdirAll(filepath.Join(root, ".substrate"), 0o755); err != nil {
		t.Fatalf("mkdir .substrate: %v", err)
	}
	if err := os.WriteFile(filepath.Join(root, ".substrate", "VERSION"), []byte("1.2.3\n"), 0o644); err != nil {
		t.Fatalf("write VERSION: %v", err)
	}
	runGit(t, root, "add", "-A")
	runGit(t, root, "commit", "-qm", "chore: initialize")
	head := runGitOutput(t, root, "rev-parse", "HEAD")

	receiptJSON, err := Write(ctx, root, "test", head, "git", "", "")
	if err != nil {
		t.Fatalf("Write: %v", err)
	}

	val, err := canonjson.Unmarshal([]byte(receiptJSON))
	if err != nil {
		t.Fatalf("Unmarshal receipt: %v", err)
	}
	obj := val.(*canonjson.Object)
	if !jqx.ObjBool(obj, "reusable", false) {
		t.Fatalf("receipt not reusable, cannot self-audit: %s", receiptJSON)
	}
	stateVal, _ := obj.Get("state")
	stateBytes, err := canonjson.Marshal(stateVal)
	if err != nil {
		t.Fatalf("re-marshal .state: %v", err)
	}
	stateBytes = append(stateBytes, '\n')

	got := xshell.SHA256Bytes(stateBytes)
	if want := jqx.ObjString(obj, "fingerprint"); got != want {
		t.Errorf("sha256(.state + LF) = %s, want .fingerprint %s", got, want)
	}
}

func runGitOutput(t *testing.T, dir string, args ...string) string {
	t.Helper()
	cmd := exec.Command("git", args...)
	cmd.Dir = dir
	out, err := cmd.Output()
	if err != nil {
		t.Fatalf("git %v: %v", args, err)
	}
	for len(out) > 0 && (out[len(out)-1] == '\n' || out[len(out)-1] == '\r') {
		out = out[:len(out)-1]
	}
	return string(out)
}
