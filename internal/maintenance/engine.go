package maintenance

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/mp-pinheiro/substrate/internal/logx"
)

const ExitPreflight = 12

func RunMaintenance(ctx context.Context, args []string) int {
	c, err := ParseArgs(args)
	if err != nil {
		logx.Err().Line("maintenance: %v", err)
		return ExitPreflight
	}

	cwd, err := os.Getwd()
	if err != nil {
		logx.Err().Line("maintenance: getwd: %v", err)
		return ExitPreflight
	}
	c.RepoRoot = cwd

	metaDir, err := MetadataDir()
	if err != nil {
		logx.Err().Line("maintenance: repository metadata is unavailable")
		return ExitPreflight
	}
	c.MetadataDir = metaDir

	c.StoreDir = filepath.Join(metaDir, "substrate")
	if err := os.MkdirAll(filepath.Join(c.StoreDir, "maintenance"), 0755); err != nil {
		logx.Err().Line("maintenance: mkdir store: %v", err)
		return ExitPreflight
	}

	c.LockPath = filepath.Join(c.StoreDir, "maintenance.lock")
	c.StablePath = filepath.Join(c.StoreDir, "maintenance-receipt.json")

	if err := os.Mkdir(c.LockPath, 0755); err != nil {
		logx.Err().Line("maintenance: another repository maintenance transaction is active")
		return ExitPreflight
	}
	defer func() { _ = os.Remove(c.LockPath) }()

	if data, err := os.ReadFile(c.StablePath); err == nil {
		var receipt Receipt
		if err := json.Unmarshal(data, &receipt); err == nil {
			recover := false
			switch receipt.Repository.Status {
			case StatusPrepared, StatusApplying, StatusIncomplete:
				recover = true
			case StatusApplied:
				if receipt.Repository.CheckpointRequested {
					recover = true
				}
			}
			if recover {
				ok, err := ResumeIncomplete(ctx, c.StablePath, c)
				if err == nil && ok {
					externalRC := 0
					if err := SyncExternalUnits(ctx, c.StablePath, c.StablePath, c.RepoOnly); err != nil {
						externalRC = 1
					}
					_ = FinishOutput(ctx)
					return externalRC
				}
				if err != nil {
					logx.Err().Line("maintenance: resume failed: %v", err)
				}
				return 1
			}
		}
	}

	base, err := Revision(ctx)
	if err != nil {
		logx.Err().Line("maintenance: revision: %v", err)
		return ExitPreflight
	}

	manifest, err := BuildManifest(c.Profiles, c.Operation, c.Checkpoint, c.AcceptBaseline, c.VCS)
	if err != nil {
		logx.Err().Line("maintenance: build manifest: %v", err)
		return ExitPreflight
	}

	dirtyPaths, err := CollectDirtyPaths(ctx, c.VCS)
	if err != nil {
		logx.Err().Line("maintenance: collect dirty paths: %v", err)
		return ExitPreflight
	}

	dirtyInside, err := EntriesJSON(ctx, dirtyPaths, manifest, "inside")
	if err != nil {
		logx.Err().Line("maintenance: entries inside: %v", err)
		return ExitPreflight
	}

	var repairOverlap, appliedOverlap bool
	var blockedOverlap []string
	if len(dirtyInside) > 0 {
		for path := range dirtyInside {
			if AppliedPathAuthorized(ctx, c.StablePath, base, path) {
				appliedOverlap = true
			} else if DirtyPathSeedable(ctx, base, path, c.Profiles) {
			} else if DirtyPathRepairable(ctx, base, path) {
				repairOverlap = true
			} else {
				blockedOverlap = append(blockedOverlap, path)
			}
		}
		if len(blockedOverlap) > 0 {
			logx.Err().Line("maintenance: maintenance overlaps dirty managed paths: %s", strings.Join(blockedOverlap, ", "))
			return ExitPreflight
		}
		if appliedOverlap {
			logx.Info("resuming previously applied maintenance paths")
		}
		if repairOverlap {
			logx.Info("repairing dirty paths with checked Substrate ownership")
		}
	}

	dirtyOutside, err := EntriesJSON(ctx, dirtyPaths, manifest, "outside")
	if err != nil {
		logx.Err().Line("maintenance: entries outside: %v", err)
		return ExitPreflight
	}

	dirtyFingerprint, err := JSONFingerprint(mapToJSONString(dirtyOutside))
	if err != nil {
		logx.Err().Line("maintenance: fingerprint: %v", err)
		return ExitPreflight
	}

	if base == "" && c.AcceptBaseline && len(dirtyOutside) > 0 {
		logx.Err().Line("maintenance: commit existing source before accepting its initial Substrate baseline")
		return ExitPreflight
	}

	id := fmt.Sprintf("%s:%s:%d:%d", c.Operation, base, os.Getpid(), time.Now().UnixNano())
	if len(id) > 24 {
		id = id[:24]
	}
	c.TxID = id
	c.TxDir = filepath.Join(c.StoreDir, "maintenance", id)
	c.CandidateDir = filepath.Join(c.TxDir, "candidate")

	if err := os.MkdirAll(filepath.Join(c.TxDir, "home"), 0755); err != nil {
		logx.Err().Line("maintenance: mkdir tx: %v", err)
		return ExitPreflight
	}

	renderOutput := filepath.Join(c.TxDir, "render.log")
	gateOutput := filepath.Join(c.TxDir, "gate.log")

	if err := PrepareCandidate(ctx, c.CandidateDir, base, filepath.Join(c.TxDir, "base.tar"), dirtyPaths, manifest, c.Checkpoint, c.Profiles); err != nil {
		logx.Err().Line("maintenance: prepare candidate: %v", err)
		return ExitPreflight
	}

	if err := RenderCandidate(ctx, c.CandidateDir, filepath.Join(c.TxDir, "home"), renderOutput, c); err != nil {
		logData, _ := os.ReadFile(renderOutput)
		if len(logData) > 0 {
			fmt.Fprintf(os.Stderr, "%s\n", string(logData))
		}
		logx.Err().Line("maintenance: render candidate: %v", err)
		return ExitPreflight
	}

	if err := GateCandidate(ctx, c.CandidateDir, gateOutput, os.Getenv("HOME"), c); err != nil {
		logData, _ := os.ReadFile(gateOutput)
		if len(logData) > 0 {
			fmt.Fprintf(os.Stderr, "%s\n", string(logData))
		}
		logx.Err().Line("maintenance: gate candidate: %v", err)
		return ExitPreflight
	}
	if os.Getenv("SUBSTRATE_MAINTENANCE_TESTING") == "1" {
		if hook := os.Getenv("SUBSTRATE_MAINTENANCE_TEST_HOOK"); hook != "" {
			_ = exec.Command(hook, c.RepoRoot).Run()
		}
	}
	gateData, err := os.ReadFile(gateOutput)
	if err != nil {
		logx.Err().Line("maintenance: read gate output: %v", err)
		return ExitPreflight
	}
	gateSum := sha256.Sum256(gateData)
	gateHash := hex.EncodeToString(gateSum[:])

	changedLines, _, err := CandidateChanges(ctx, c.CandidateDir, manifest)
	if err != nil {
		logx.Err().Line("maintenance: candidate changes: %v", err)
		return ExitPreflight
	}

	changedUnitPaths := ChangedUnits(manifest, changedLines)

	var repairUnitPaths []string
	if repairOverlap || appliedOverlap {
		for path := range dirtyInside {
			repairUnitPaths = append(repairUnitPaths, path)
		}
	}

	allUnitPaths := append(changedUnitPaths, repairUnitPaths...)
	seen := map[string]bool{}
	var unitsPaths []string
	for _, p := range allUnitPaths {
		if !seen[p] {
			seen[p] = true
			unitsPaths = append(unitsPaths, p)
		}
	}

	// The receipt's ChangedPaths is verified against git diff --name-only (files,
	// not manifest units), so it uses dirtyInside's file keys, not unitsPaths.
	receiptChangedPaths := append([]string{}, changedLines...)
	receiptChangedPaths = append(receiptChangedPaths, repairUnitPaths...)

	unitsFile := filepath.Join(c.TxDir, "units.paths")
	if err := os.WriteFile(unitsFile, []byte(strings.Join(unitsPaths, "\n")+"\n"), 0644); err != nil {
		logx.Err().Line("maintenance: write units: %v", err)
		return ExitPreflight
	}

	unitsList, err := UnitsJSON(unitsFile, c.CandidateDir)
	if err != nil {
		logx.Err().Line("maintenance: units json: %v", err)
		return ExitPreflight
	}
	unitsJSON, _ := json.Marshal(unitsList)

	txReceiptPath := filepath.Join(c.TxDir, "receipt.json")

	if len(changedLines) == 0 && len(unitsPaths) == 0 {
		status := StatusNoop
		commit := ""
		if c.Checkpoint {
			status = StatusCommitted
			commit = base
		}
		receiptData, err := ReceiptJSON(c, id, status, base, base, manifest, changedLines, string(unitsJSON), dirtyFingerprint, gateHash, "", commit)
		if err != nil {
			logx.Err().Line("maintenance: receipt json: %v", err)
			return ExitPreflight
		}
		if err := WriteJSON(txReceiptPath, string(receiptData)); err != nil {
			logx.Err().Line("maintenance: write receipt: %v", err)
			return ExitPreflight
		}
		if err := PublishReceipt(txReceiptPath, c.StablePath); err != nil {
			logx.Err().Line("maintenance: publish receipt: %v", err)
			return ExitPreflight
		}
		externalRC := 0
		if err := SyncExternalUnits(ctx, txReceiptPath, c.StablePath, c.RepoOnly); err != nil {
			externalRC = 1
		}
		_ = FinishOutput(ctx)
		return externalRC
	}

	receiptData, err := ReceiptJSON(c, id, StatusPrepared, base, "", manifest, receiptChangedPaths, string(unitsJSON), dirtyFingerprint, gateHash, c.CandidateDir, "")
	if err != nil {
		logx.Err().Line("maintenance: receipt json: %v", err)
		return ExitPreflight
	}
	if err := WriteJSON(txReceiptPath, string(receiptData)); err != nil {
		logx.Err().Line("maintenance: write receipt: %v", err)
		return ExitPreflight
	}

	if err := UnitsMatchPreimage(txReceiptPath); err != nil {
		logx.Err().Line("maintenance: managed paths changed while rendering maintenance candidate")
		return ExitPreflight
	}

	currentRev, err := Revision(ctx)
	if err != nil || currentRev != base {
		logx.Err().Line("maintenance: repository revision changed while rendering maintenance candidate")
		return ExitPreflight
	}

	currentFingerprint := computeCurrentDirtyFingerprint(ctx, manifest)
	if currentFingerprint != dirtyFingerprint {
		logx.Err().Line("maintenance: working copy changed while rendering maintenance candidate")
		return ExitPreflight
	}

	if err := PublishReceipt(txReceiptPath, c.StablePath); err != nil {
		logx.Err().Line("maintenance: publish receipt: %v", err)
		return ExitPreflight
	}

	if err := ApplyUnits(ctx, c.CandidateDir, txReceiptPath, c.StablePath); err != nil {
		_ = UpdateReceipt(txReceiptPath, c.StablePath, `.repository.status="incomplete"`)
		logx.Err().Line("maintenance: repository maintenance incomplete; rerun the same command to converge")
		return ExitPreflight
	}

	if err := UpdateReceipt(txReceiptPath, c.StablePath, `.repository.status="applied"`); err != nil {
		logx.Err().Line("maintenance: update receipt: %v", err)
		return ExitPreflight
	}

	if c.Checkpoint {
		manifestFile := writeTempLines(manifest)
		defer func() { _ = os.Remove(manifestFile) }()
		if !CompareDirtyState(manifestFile, dirtyFingerprint) {
			_ = UpdateReceipt(txReceiptPath, c.StablePath, `.repository.status="incomplete"`)
			logx.Err().Line("maintenance: unrelated work changed before maintenance checkpoint")
			return ExitPreflight
		}

		var commit string
		var to string
		actualChanged := []string{}
		if len(unitsPaths) > 0 {
			var err error
			commitUnitsFile := filepath.Join(c.TxDir, "commit-units.paths")
			if err := os.WriteFile(commitUnitsFile, []byte(strings.Join(unitsPaths, "\n")+"\n"), 0644); err != nil {
				logx.Err().Line("maintenance: write commit units: %v", err)
				return ExitPreflight
			}
			commit, err = CommitExact(ctx, commitUnitsFile, id, c)
			if err != nil {
				logx.Err().Line("maintenance: repository maintenance applied but exact-path commit failed")
				_ = UpdateReceipt(txReceiptPath, c.StablePath, `.repository.status="incomplete"`)
				return ExitPreflight
			}
			to, err = Revision(ctx)
			if err != nil {
				_ = UpdateReceipt(txReceiptPath, c.StablePath, `.repository.status="incomplete"`)
				logx.Err().Line("maintenance: revision after commit: %v", err)
				return ExitPreflight
			}
			actualChanged, err = ActualChangedPaths(ctx, base, to)
			if err != nil {
				_ = UpdateReceipt(txReceiptPath, c.StablePath, `.repository.status="incomplete"`)
				logx.Err().Line("maintenance: actual changed paths: %v", err)
				return ExitPreflight
			}
		} else {
			if base == "" {
				logx.Err().Line("maintenance: no base revision for empty commit")
				return ExitPreflight
			}
			commit = base
			to = base
		}

		changedPathsJSON, err := json.Marshal(actualChanged)
		if err != nil {
			logx.Err().Line("maintenance: marshal changed paths: %v", err)
			return ExitPreflight
		}
		filter := fmt.Sprintf(`.repository.status="committed" | .repository.toRevision="%s" | .repository.commit="%s" | .repository.candidatePath=null | .repository.changedPaths=%s`, to, commit, string(changedPathsJSON))
		if err := UpdateReceipt(txReceiptPath, c.StablePath, filter); err != nil {
			logx.Err().Line("maintenance: update receipt transition: %v", err)
			return ExitPreflight
		}

		if err := VerifyTransition(base, to, dirtyFingerprint); err != nil {
			logx.Err().Line("maintenance: maintenance commit exists but its exact-state receipt failed verification: %v", err)
			return ExitPreflight
		}
	}

	externalRC := 0
	if err := SyncExternalUnits(ctx, txReceiptPath, c.StablePath, c.RepoOnly); err != nil {
		externalRC = 1
	}

	if c.Checkpoint {
		_ = os.RemoveAll(c.TxDir)
	}

	_ = FinishOutput(ctx)
	return externalRC
}

func mapToJSONString(m map[string]string) string {
	b, err := json.Marshal(m)
	if err != nil {
		return "{}"
	}
	return string(b)
}

func computeCurrentDirtyFingerprint(ctx context.Context, manifest []string) string {
	paths, err := CollectDirtyPaths(ctx, "")
	if err != nil {
		return ""
	}
	entries, err := EntriesJSON(ctx, paths, manifest, "outside")
	if err != nil {
		return ""
	}
	fp, err := JSONFingerprint(mapToJSONString(entries))
	if err != nil {
		return ""
	}
	return fp
}
