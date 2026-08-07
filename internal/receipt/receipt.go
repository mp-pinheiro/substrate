package receipt

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/mp-pinheiro/substrate/internal/canonjson"
	"github.com/mp-pinheiro/substrate/internal/jqx"
	"github.com/mp-pinheiro/substrate/internal/xshell"
)

// MetadataDir probes git before jj, so a colocated jj repo keeps its receipt under .git.
func Path(ctx context.Context, repoRoot string) (string, error) {
	repo, err := detectBackend(repoRoot)
	if err != nil {
		return "", err
	}
	metadataDir, err := repo.MetadataDir(ctx)
	if err != nil {
		return "", fmt.Errorf("receipt: resolve metadata dir: %w", err)
	}
	return filepath.Join(metadataDir, "substrate", "gate-receipt.json"), nil
}

// Matches reproduces gate_receipt_matches (B3); v1 receipts have no recipeVersion field.
func Matches(ctx context.Context, repoRoot string) (bool, error) {
	path, err := Path(ctx, repoRoot)
	if err != nil {
		return false, err
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return false, nil
		}
		return false, fmt.Errorf("receipt: read %s: %w", path, err)
	}
	val, err := canonjson.Unmarshal(raw)
	if err != nil {
		return false, nil
	}
	obj, ok := val.(*canonjson.Object)
	if !ok {
		return false, nil
	}
	if jqx.ObjString(obj, "status") != "passed" {
		return false, nil
	}
	if !jqx.ObjBool(obj, "reusable", false) {
		return false, nil
	}
	if !jqx.ObjIsString(obj, "fingerprint") {
		return false, nil
	}
	if !jqx.ObjInt64Equals(obj, "recipeVersion", RecipeVersion) {
		return false, nil
	}

	state, err := BuildState(ctx, repoRoot)
	if err != nil {
		return false, nil
	}
	fp, err := Fingerprint(state)
	if err != nil {
		return false, fmt.Errorf("receipt: compute fingerprint: %w", err)
	}
	return jqx.ObjString(obj, "fingerprint") == fp, nil
}

// A BuildState refusal is deliberate: the receipt is written non-reusable, never failed (C17).
func Write(ctx context.Context, repoRoot, source, commit, vcsName, session string) (string, error) {
	repo, err := detectBackend(repoRoot)
	if err != nil {
		return "", err
	}
	current, currentErrText, err := repo.Revision(ctx)
	if err != nil {
		return "", fmt.Errorf("receipt: probe revision: %w", err)
	}
	if currentErrText != "" || current != commit {
		return "", fmt.Errorf("receipt: commit %q is not the current revision", commit)
	}

	var (
		stateDoc canonjson.Value
		fp       canonjson.Value
		reusable bool
	)
	if state, buildErr := BuildState(ctx, repoRoot); buildErr == nil {
		fingerprint, fpErr := Fingerprint(state)
		if fpErr != nil {
			return "", fmt.Errorf("receipt: compute fingerprint: %w", fpErr)
		}
		stateDoc = state.Doc()
		fp = fingerprint
		reusable = true
	}

	doc := canonjson.NewObject().
		Set("commit", commit).
		Set("vcs", vcsName).
		Set("source", source).
		Set("session", jqx.Nullable(session)).
		Set("fingerprint", fp).
		Set("reusable", reusable).
		Set("engineVersion", readEngineVersion(repoRoot)).
		Set("recipeVersion", int64(RecipeVersion)).
		Set("state", stateDoc).
		Set("at", time.Now().UTC().Format("2006-01-02T15:04:05Z")).
		Set("status", "passed")

	b, err := canonjson.Marshal(doc)
	if err != nil {
		return "", fmt.Errorf("receipt: marshal: %w", err)
	}
	b = append(b, '\n')

	path, err := Path(ctx, repoRoot)
	if err != nil {
		return "", err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return "", fmt.Errorf("receipt: mkdir %s: %w", filepath.Dir(path), err)
	}
	if err := xshell.WriteFileAtomic(path, b, 0o600); err != nil {
		return "", fmt.Errorf("receipt: write %s: %w", path, err)
	}
	return strings.TrimRight(string(b), "\n"), nil
}

func readEngineVersion(repoRoot string) string {
	data, err := os.ReadFile(filepath.Join(repoRoot, ".substrate", "VERSION"))
	if err != nil {
		return ""
	}
	return strings.TrimRight(string(data), "\n")
}
