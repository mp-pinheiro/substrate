package maintenance

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/mp-pinheiro/substrate/internal/xshell"
)

func SyncExternalUnits(ctx context.Context, txReceiptPath, stablePath string, repoOnly bool) error {
	runtimeStatus := PhasePassed
	harnessStatus := PhaseSkipped

	if err := syncRepoRuntime(ctx); err != nil {
		runtimeStatus = PhaseFailed
	}
	_ = updatePhaseStatus(txReceiptPath, stablePath, ".repoRuntime.status", runtimeStatus)

	if !repoOnly && os.Getenv("SUBSTRATE_NO_USER_HARNESS") != "1" {
		harnessStatus = PhasePassed
		if err := SyncUserLocked(ctx); err != nil {
			harnessStatus = PhaseFailed
		}
	}
	_ = updatePhaseStatus(txReceiptPath, stablePath, ".userHarness.status", harnessStatus)

	if runtimeStatus != PhasePassed {
		return fmt.Errorf("sync_external: repo runtime failed")
	}
	if harnessStatus == PhaseFailed {
		return fmt.Errorf("sync_external: user harness failed")
	}
	return nil
}

func syncRepoRuntime(ctx context.Context) error {
	_, err := xshell.Run(ctx, filepath.Join(".substrate", "install-substrate.sh"))
	if err != nil {
		return fmt.Errorf("sync_repo_runtime: %w", err)
	}
	return nil
}

func updatePhaseStatus(txReceiptPath, stablePath, key, status string) error {
	data, err := os.ReadFile(txReceiptPath)
	if err != nil {
		return fmt.Errorf("update_phase: read: %w", err)
	}
	var receipt map[string]interface{}
	if err := json.Unmarshal(data, &receipt); err != nil {
		return fmt.Errorf("update_phase: parse: %w", err)
	}
	switch key {
	case ".repoRuntime.status":
		if rr, ok := receipt["repoRuntime"].(map[string]interface{}); ok {
			rr["status"] = status
		}
	case ".userHarness.status":
		if uh, ok := receipt["userHarness"].(map[string]interface{}); ok {
			uh["status"] = status
		}
	}
	next, err := json.Marshal(receipt)
	if err != nil {
		return fmt.Errorf("update_phase: marshal: %w", err)
	}
	nextStr := string(next)
	if err := WriteJSON(txReceiptPath, nextStr); err != nil {
		return err
	}
	return WriteJSON(stablePath, nextStr)
}

func SyncUserLocked(ctx context.Context) error {
	home, err := os.UserHomeDir()
	if err != nil {
		return fmt.Errorf("sync_user_locked: home: %w", err)
	}
	stateRoot := filepath.Join(home, ".local", "state", "substrate")
	if err := os.MkdirAll(stateRoot, 0755); err != nil {
		return fmt.Errorf("sync_user_locked: mkdir state: %w", err)
	}
	lockPath := filepath.Join(stateRoot, "harness.lock")
	if err := os.Mkdir(lockPath, 0755); err != nil {
		return fmt.Errorf("sync_user_locked: lock: %w", err)
	}
	defer func() { _ = os.Remove(lockPath) }()

	rc := 0
	if err := syncUserHarness(ctx); err != nil {
		rc = 1
	}

	receiptPath := filepath.Join(stateRoot, "harness-receipt.json")
	status := PhasePassed
	if rc != 0 {
		status = "incomplete"
	}
	now := time.Now().UTC().Format(time.RFC3339)
	receiptJSON := fmt.Sprintf(`{"status":"%s","engineVersion":"unknown","at":"%s"}`, status, now)
	if err := WriteJSON(receiptPath, receiptJSON); err != nil {
		return fmt.Errorf("sync_user_locked: write receipt: %w", err)
	}
	if rc != 0 {
		return fmt.Errorf("sync_user_locked: harness sync failed")
	}
	return nil
}

func syncUserHarness(ctx context.Context) error {
	_, err := xshell.Run(ctx, filepath.Join(".substrate", "install-user-harness.sh"))
	if err != nil {
		return fmt.Errorf("sync_user_harness: %w", err)
	}
	return nil
}

func FinishOutput(ctx context.Context) error {
	metaDir, err := MetadataDir()
	if err != nil {
		return err
	}
	path := StablePath(metaDir)
	data, err := os.ReadFile(path)
	if err != nil {
		return fmt.Errorf("finish_output: read: %w", err)
	}
	var receipt Receipt
	if err := json.Unmarshal(data, &receipt); err != nil {
		return fmt.Errorf("finish_output: parse: %w", err)
	}

	status := receipt.Repository.Status
	commit := ""
	if receipt.Repository.Commit != nil {
		commit = *receipt.Repository.Commit
	}

	if status == StatusCommitted {
		if len(receipt.Repository.ChangedPaths) == 0 {
			_, _ = fmt.Fprintf(os.Stdout, "repository: unchanged at %s\n", shortSHA(commit))
		} else {
			_, _ = fmt.Fprintf(os.Stdout, "repository: committed %s\n", shortSHA(commit))
		}
		_, _ = fmt.Fprintf(os.Stdout, "repo runtime: %s\n", receipt.RepoRuntime.Status)
		_, _ = fmt.Fprintf(os.Stdout, "user harness: %s\n", receipt.UserHarness.Status)
		_, _ = fmt.Fprintf(os.Stdout, "push: not performed\n")
	} else {
		_, _ = fmt.Fprintf(os.Stdout, "repository: %s (checkpoint with --checkpoint)\n", status)
		_, _ = fmt.Fprintf(os.Stdout, "push: not performed\n")
	}
	return nil
}


func shortSHA(sha string) string {
	if len(sha) > 12 {
		return sha[:12]
	}
	return sha
}
