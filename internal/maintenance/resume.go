package maintenance

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
)

func ResumeIncomplete(ctx context.Context, stablePath string, c *Context) (bool, error) {
	data, err := os.ReadFile(stablePath)
	if err != nil {
		return false, fmt.Errorf("resume: read receipt: %w", err)
	}
	var receipt Receipt
	if err := json.Unmarshal(data, &receipt); err != nil {
		return false, fmt.Errorf("resume: parse receipt: %w", err)
	}

	status := receipt.Repository.Status
	switch status {
	case StatusPrepared, StatusApplying, StatusApplied, StatusIncomplete:
	default:
		return false, fmt.Errorf("resume: unexpected status: %s", status)
	}
	if receipt.Operation != c.Operation {
		return false, fmt.Errorf("resume: incomplete %s transaction must be resumed first", receipt.Operation)
	}

	candidatePath := ""
	if receipt.Repository.CandidatePath != nil {
		candidatePath = *receipt.Repository.CandidatePath
	}
	if candidatePath == "" || !dirExists(filepath.Join(candidatePath, ".git")) {
		return false, fmt.Errorf("resume: incomplete transaction candidate is missing")
	}

	fromRev := ""
	if receipt.Repository.FromRevision != nil {
		fromRev = *receipt.Repository.FromRevision
	}
	current, err := Revision(ctx)
	if err != nil {
		return false, fmt.Errorf("resume: revision: %w", err)
	}
	if current != fromRev {
		return false, fmt.Errorf("resume: repository revision changed during incomplete maintenance")
	}

	for _, unit := range receipt.Repository.Units {
		state, err := PathState(unit.Path)
		if err != nil {
			return false, fmt.Errorf("resume: path_state %s: %w", unit.Path, err)
		}
		if state != unit.Preimage && state != unit.Desired {
			return false, fmt.Errorf("resume: maintenance recovery blocked by drift at %s", unit.Path)
		}
	}

	manifestFile := writeTempLines(receipt.Repository.Manifest)
	defer func() { _ = os.Remove(manifestFile) }()
	if !CompareDirtyState(manifestFile, receipt.Repository.PreservedDirtyFingerprint) {
		return false, fmt.Errorf("resume: maintenance recovery blocked by unrelated working-copy drift")
	}

	checkpoint := receipt.Repository.CheckpointRequested

	txDir := filepath.Dir(candidatePath)
	gateLog := filepath.Join(txDir, "gate-resume.log")
	_ = os.Remove(gateLog)

	if err := GateCandidate(ctx, candidatePath, gateLog, os.Getenv("HOME"), c); err != nil {
		logData, _ := os.ReadFile(gateLog)
		if len(logData) > 0 {
			fmt.Fprintf(os.Stderr, "%s\n", string(logData))
		}
		return false, fmt.Errorf("resume: gate candidate failed: %w", err)
	}

	if err := ApplyUnits(ctx, candidatePath, stablePath, stablePath); err != nil {
		return false, fmt.Errorf("resume: apply units: %w", err)
	}

	if err := UpdateReceipt(stablePath, stablePath, `.repository.status="applied"`); err != nil {
		return false, fmt.Errorf("resume: update receipt: %w", err)
	}

	if !checkpoint {
		return false, nil
	}

	unitsFile := filepath.Join(txDir, "units.paths")
	commitLog := filepath.Join(txDir, "commit-resume.log")
	_ = os.Remove(commitLog)

	commit, err := CommitExact(ctx, unitsFile, receipt.ID, c)
	if err != nil {
		logData, _ := os.ReadFile(commitLog)
		if len(logData) > 0 {
			fmt.Fprintf(os.Stderr, "%s\n", string(logData))
		}
		return false, fmt.Errorf("resume: commit exact: %w", err)
	}

	to, err := Revision(ctx)
	if err != nil {
		return false, fmt.Errorf("resume: revision after commit: %w", err)
	}

	filter := fmt.Sprintf(`.repository.status="committed" | .repository.toRevision="%s" | .repository.commit="%s" | .repository.candidatePath=null`, to, commit)
	if err := UpdateReceipt(stablePath, stablePath, filter); err != nil {
		return false, fmt.Errorf("resume: update receipt transition: %w", err)
	}

	if err := VerifyTransition(fromRev, to, receipt.Repository.PreservedDirtyFingerprint); err != nil {
		return false, fmt.Errorf("resume: verify transition: %w", err)
	}

	_ = os.RemoveAll(txDir)
	return true, nil
}

func dirExists(path string) bool {
	fi, err := os.Stat(path)
	return err == nil && fi.IsDir()
}
