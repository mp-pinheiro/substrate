package maintenance

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/mp-pinheiro/substrate/internal/xshell"
)

var ErrInjectedFailure = errors.New("maintenance: injected failure")

func MarkUnitApplied(txReceiptPath, stablePath, unitPath string) error {
	data, err := os.ReadFile(txReceiptPath)
	if err != nil {
		return fmt.Errorf("mark-unit-applied: read receipt: %w", err)
	}

	var receipt Receipt
	if err := json.Unmarshal(data, &receipt); err != nil {
		return fmt.Errorf("mark-unit-applied: parse receipt: %w", err)
	}

	receipt.Repository.Status = StatusApplying
	found := false
	for i := range receipt.Repository.Units {
		if receipt.Repository.Units[i].Path == unitPath {
			receipt.Repository.Units[i].Applied = true
			found = true
			break
		}
	}
	if !found {
		return fmt.Errorf("mark-unit-applied: unit %s not found in receipt", unitPath)
	}

	next, err := json.Marshal(&receipt)
	if err != nil {
		return fmt.Errorf("mark-unit-applied: marshal: %w", err)
	}

	if err := WriteJSON(txReceiptPath, string(next)); err != nil {
		return fmt.Errorf("mark-unit-applied: write tx receipt: %w", err)
	}
	if err := WriteJSON(stablePath, string(next)); err != nil {
		return fmt.Errorf("mark-unit-applied: write stable receipt: %w", err)
	}

	return nil
}

func validateApplyPath(p string) error {
	if err := validatePath(p); err != nil {
		return err
	}
	if strings.HasPrefix(p, "-") {
		return fmt.Errorf("validate path: path starts with dash: %s", p)
	}
	if fi, err := os.Lstat(p); err == nil && fi.Mode()&os.ModeSymlink != 0 {
		return fmt.Errorf("validate path: path is a symlink: %s", p)
	}
	return nil
}

func ApplyUnit(candidateDir, unitPath, desired string) error {
	ctx := context.Background()

	current, err := PathState(unitPath)
	if err != nil {
		return fmt.Errorf("apply-unit: path-state %s: %w", unitPath, err)
	}
	if current == desired {
		return nil
	}

	if err := validateApplyPath(unitPath); err != nil {
		return fmt.Errorf("apply-unit: %w", err)
	}

	parent := filepath.Dir(unitPath)

	if err := os.MkdirAll(parent, 0755); err != nil {
		return fmt.Errorf("apply-unit: mkdir parent: %w", err)
	}

	stageDir, err := os.MkdirTemp(parent, ".substrate-maint-stage-*")
	if err != nil {
		return fmt.Errorf("apply-unit: mktemp stage: %w", err)
	}

	candidateSrc := filepath.Join(candidateDir, unitPath)
	if _, err := os.Lstat(candidateSrc); err == nil {
		stageValue := filepath.Join(stageDir, "value")
		result, cpErr := xshell.Run(ctx, "cp", "-a", candidateSrc, stageValue)
		if cpErr != nil || result.Code != 0 {
			_ = os.RemoveAll(stageDir)
			if cpErr != nil {
				return fmt.Errorf("apply-unit: cp candidate: %w", cpErr)
			}
			return fmt.Errorf("apply-unit: cp candidate failed: %s", string(result.Stderr))
		}
	}

	var backupDir string
	if _, err := os.Lstat(unitPath); err == nil {
		backupDir, err = os.MkdirTemp(parent, ".substrate-maint-backup-*")
		if err != nil {
			_ = os.RemoveAll(stageDir)
			return fmt.Errorf("apply-unit: mktemp backup: %w", err)
		}
		if err := os.Remove(backupDir); err != nil {
			_ = os.RemoveAll(stageDir)
			return fmt.Errorf("apply-unit: remove backup dir: %w", err)
		}
		if err := os.Rename(unitPath, backupDir); err != nil {
			_ = os.RemoveAll(stageDir)
			return fmt.Errorf("apply-unit: backup mv: %w", err)
		}
	}

	stageValue := filepath.Join(stageDir, "value")
	if _, err := os.Lstat(stageValue); err == nil {
		if err := os.Rename(stageValue, unitPath); err != nil {
			if backupDir != "" {
				_ = os.Rename(backupDir, unitPath)
			}
			_ = os.RemoveAll(stageDir)
			if backupDir != "" {
				_ = os.RemoveAll(backupDir)
			}
			return fmt.Errorf("apply-unit: mv stage: %w", err)
		}
	}

	_ = os.RemoveAll(stageDir)

	actual, err := PathState(unitPath)
	if err != nil {
		actual = ""
	}
	if actual != desired {
		_ = os.RemoveAll(unitPath)
		if backupDir != "" {
			_ = os.Rename(backupDir, unitPath)
			_ = os.RemoveAll(backupDir)
		}
		return fmt.Errorf("apply-unit: verify: expected %s, got %s", desired, actual)
	}

	if backupDir != "" {
		if err := os.RemoveAll(backupDir); err != nil {
			_ = os.RemoveAll(unitPath)
			_ = os.Rename(backupDir, unitPath)
			return fmt.Errorf("apply-unit: cleanup backup: %w", err)
		}
	}

	return nil
}

func updateReceiptStatus(txPath, stablePath, status string) {
	data, err := os.ReadFile(txPath)
	if err != nil {
		return
	}
	var receipt Receipt
	if err := json.Unmarshal(data, &receipt); err != nil {
		return
	}
	receipt.Repository.Status = status
	next, err := json.Marshal(&receipt)
	if err != nil {
		return
	}
	_ = WriteJSON(txPath, string(next))
	_ = WriteJSON(stablePath, string(next))
}

func ApplyUnits(ctx context.Context, candidateDir, txReceiptPath, stablePath string) error {
	data, err := os.ReadFile(txReceiptPath)
	if err != nil {
		return fmt.Errorf("apply-units: read receipt: %w", err)
	}

	var receipt Receipt
	if err := json.Unmarshal(data, &receipt); err != nil {
		return fmt.Errorf("apply-units: parse receipt: %w", err)
	}

	failAfter, _ := strconv.Atoi(os.Getenv("SUBSTRATE_MAINTENANCE_FAIL_AFTER"))
	testing := os.Getenv("SUBSTRATE_MAINTENANCE_TESTING") == "1"

	for i, unit := range receipt.Repository.Units {
		current, err := PathState(unit.Path)
		if err != nil {
			return fmt.Errorf("apply-units: path-state %s: %w", unit.Path, err)
		}
		if current != unit.Desired {
			if err := ApplyUnit(candidateDir, unit.Path, unit.Desired); err != nil {
				return fmt.Errorf("apply-units: %w", err)
			}
		}
		if err := MarkUnitApplied(txReceiptPath, stablePath, unit.Path); err != nil {
			return fmt.Errorf("apply-units: mark applied: %w", err)
		}

		if testing && failAfter > 0 && i+1 == failAfter {
			updateReceiptStatus(txReceiptPath, stablePath, StatusIncomplete)
			return fmt.Errorf("%w: failed after %d units", ErrInjectedFailure, i+1)
		}
	}

	return nil
}
