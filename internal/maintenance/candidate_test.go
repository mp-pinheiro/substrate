package maintenance

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestRenderCandidateReportsRendererExit(t *testing.T) {
	kit := t.TempDir()
	if err := os.Mkdir(filepath.Join(kit, "bin"), 0o755); err != nil {
		t.Fatal(err)
	}
	renderer := "#!/bin/sh\nprintf '[!] kit worktree has uncommitted vendor sources\\n'\nexit 2\n"
	if err := os.WriteFile(filepath.Join(kit, "bin", "substrate"), []byte(renderer), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("SUBSTRATE_KIT_ROOT", kit)
	output := filepath.Join(t.TempDir(), "render.log")

	err := RenderCandidate(context.Background(), t.TempDir(), t.TempDir(), output, &Context{Operation: OpUpdate})
	if err == nil {
		t.Fatal("render succeeded, want the renderer's exit status")
	}
	if msg := err.Error(); strings.Contains(msg, "%!") || !strings.Contains(msg, "exited 2") {
		t.Fatalf("error = %q, want the renderer's exit status without format artifacts", msg)
	}
	log, err := os.ReadFile(output)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(log), "uncommitted vendor sources") {
		t.Fatalf("render log = %q, want the renderer's refusal", log)
	}
}
