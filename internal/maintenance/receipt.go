package maintenance

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"

	"github.com/mp-pinheiro/substrate/internal/xshell"
)

func ReceiptJSON(c *Context, id, status, from, to string, manifest, changedLines []string, unitsJSON string, dirtyFingerprint, gateHash, candidate, commit string) (string, error) {
	manifestFiltered := filterEmpty(manifest)
	changedFiltered := filterEmpty(changedLines)

	var units []Unit
	if unitsJSON != "" {
		if err := json.Unmarshal([]byte(unitsJSON), &units); err != nil {
			return "", fmt.Errorf("receipt json: parse units: %w", err)
		}
	}

	kitVersion, err := readKitVersion()
	if err != nil {
		return "", fmt.Errorf("receipt json: %w", err)
	}

	r := Receipt{
		SchemaVersion: 1,
		ID:            id,
		Operation:     c.Operation,
		EngineVersion: kitVersion,
		Repository: RepositorySection{
			Status:                    status,
			VCS:                       c.VCS,
			FromRevision:              nullable(from),
			ToRevision:                nullable(to),
			Commit:                    nullable(commit),
			Message:                   c.Message,
			CheckpointRequested:       c.Checkpoint,
			Manifest:                  manifestFiltered,
			ChangedPaths:              changedFiltered,
			Units:                     units,
			PreservedDirtyFingerprint: dirtyFingerprint,
			GateHash:                  gateHash,
			CandidatePath:             nullable(candidate),
		},
		RepoRuntime: PhaseSection{Status: PhasePending},
		UserHarness: PhaseSection{Status: PhasePending},
		NoPush:      true,
		At:          time.Now().UTC().Format(time.RFC3339),
	}

	data, err := json.Marshal(r)
	if err != nil {
		return "", fmt.Errorf("receipt json: marshal: %w", err)
	}
	return string(data), nil
}

func PublishReceipt(txReceiptPath, stablePath string) error {
	raw, err := os.ReadFile(txReceiptPath)
	if err != nil {
		return fmt.Errorf("publish receipt: read: %w", err)
	}
	return WriteJSON(stablePath, string(raw))
}

func UpdateReceipt(txReceiptPath, stablePath, filter string) error {
	raw, err := os.ReadFile(txReceiptPath)
	if err != nil {
		return fmt.Errorf("update receipt: read: %w", err)
	}
	result, err := xshell.RunStdin(context.Background(), "", raw, "jq", "-c", filter)
	if err != nil {
		return fmt.Errorf("update receipt: jq: %w", err)
	}
	next := strings.TrimSpace(string(result.Stdout))
	if err := WriteJSON(txReceiptPath, next); err != nil {
		return fmt.Errorf("update receipt: write tx: %w", err)
	}
	if err := WriteJSON(stablePath, next); err != nil {
		return fmt.Errorf("update receipt: write stable: %w", err)
	}
	return nil
}

func VerifyTransition(from, to, fingerprint string) error {
	metaDir, err := MetadataDir()
	if err != nil {
		return err
	}
	stablePath := StablePath(metaDir)

	raw, err := os.ReadFile(stablePath)
	if err != nil {
		return fmt.Errorf("verify transition: %w", err)
	}

	var r Receipt
	if err := json.Unmarshal(raw, &r); err != nil {
		return fmt.Errorf("verify transition: parse: %w", err)
	}

	if r.Repository.Status != StatusCommitted {
		return fmt.Errorf("verify transition: status is %q, expected %q", r.Repository.Status, StatusCommitted)
	}
	if fromRev := stringOrEmpty(r.Repository.FromRevision); fromRev != from {
		return fmt.Errorf("verify transition: fromRevision mismatch: %q != %q", fromRev, from)
	}
	if toRev := stringOrEmpty(r.Repository.ToRevision); toRev != to {
		return fmt.Errorf("verify transition: toRevision mismatch: %q != %q", toRev, to)
	}
	if r.Repository.PreservedDirtyFingerprint != fingerprint {
		return fmt.Errorf("verify transition: fingerprint mismatch")
	}

	ctx := context.Background()
	current, err := Revision(ctx)
	if err != nil {
		return err
	}
	if current != to {
		return fmt.Errorf("verify transition: current revision %q != to %q", current, to)
	}

	actual, err := ActualChangedPaths(ctx, from, to)
	if err != nil {
		return fmt.Errorf("verify transition: %w", err)
	}

	expected := make([]string, len(r.Repository.ChangedPaths))
	copy(expected, r.Repository.ChangedPaths)
	sort.Strings(expected)

	if !stringSlicesEqual(actual, expected) {
		return fmt.Errorf("verify transition: changed paths mismatch")
	}

	return nil
}

// ActualChangedPaths returns the sorted file-level paths git actually
// changed between from and to (empty from means the root commit).
func ActualChangedPaths(ctx context.Context, from, to string) ([]string, error) {
	var actual []string
	useDiff := from != ""
	if useDiff {
		result, catErr := xshell.RunC(ctx, "git", "cat-file", "-e", from+"^{commit}")
		useDiff = catErr == nil && result.Code == 0
	}
	if useDiff {
		result, err := xshell.RunC(ctx, "git", "diff", "--name-only", "-z", "--no-renames", from, to)
		if err != nil {
			return nil, fmt.Errorf("diff: %w", err)
		}
		actual = stringsFromNull(result.Stdout)
	} else {
		result, err := xshell.RunC(ctx, "git", "diff-tree", "--root", "--name-only", "-z", "-r", "--no-commit-id", to)
		if err != nil {
			return nil, fmt.Errorf("diff-tree: %w", err)
		}
		actual = stringsFromNull(result.Stdout)
	}
	sort.Strings(actual)
	return actual, nil
}

func RepositoryReceiptMatches(path string) error {
	if path == "" {
		metaDir, err := MetadataDir()
		if err != nil {
			return err
		}
		path = StablePath(metaDir)
	}

	raw, err := os.ReadFile(path)
	if err != nil {
		return fmt.Errorf("repository receipt matches: %w", err)
	}

	var r Receipt
	if err := json.Unmarshal(raw, &r); err != nil {
		return fmt.Errorf("repository receipt matches: parse: %w", err)
	}

	if r.SchemaVersion != 1 {
		return fmt.Errorf("repository receipt matches: schemaVersion is %d, expected 1", r.SchemaVersion)
	}

	repoEngineVersion := readRepoEngineVersion(".")
	if r.EngineVersion != repoEngineVersion {
		return fmt.Errorf("repository receipt matches: engineVersion mismatch")
	}

	if r.Repository.Status != StatusCommitted {
		return fmt.Errorf("repository receipt matches: status is %q, expected %q", r.Repository.Status, StatusCommitted)
	}

	if !r.Repository.CheckpointRequested {
		return fmt.Errorf("repository receipt matches: checkpointRequested is false")
	}

	vcs, err := detectVCS()
	if err != nil {
		return err
	}
	if r.Repository.VCS != vcs {
		return fmt.Errorf("repository receipt matches: vcs mismatch: %q != %q", r.Repository.VCS, vcs)
	}

	commitStr := ""
	if r.Repository.Commit != nil {
		commitStr = *r.Repository.Commit
	}
	toRevStr := stringOrEmpty(r.Repository.ToRevision)
	if commitStr != toRevStr {
		return fmt.Errorf("repository receipt matches: commit != toRevision")
	}

	if !regexp.MustCompile(`^[0-9a-f]{64}$`).MatchString(r.Repository.GateHash) {
		return fmt.Errorf("repository receipt matches: gateHash format invalid")
	}

	if !r.NoPush {
		return fmt.Errorf("repository receipt matches: noPush is false")
	}

	ctx := context.Background()
	current, err := Revision(ctx)
	if err != nil {
		return err
	}
	if current != stringOrEmpty(r.Repository.ToRevision) {
		return fmt.Errorf("repository receipt matches: current revision %q != toRevision %q", current, stringOrEmpty(r.Repository.ToRevision))
	}

	dirtyPaths, err := CollectDirtyPaths(ctx, vcs)
	if err != nil {
		return err
	}

	inside, err := EntriesJSON(ctx, dirtyPaths, r.Repository.Manifest, "inside")
	if err != nil {
		return err
	}
	if len(inside) > 0 {
		return fmt.Errorf("repository receipt matches: dirty managed paths inside manifest")
	}

	outside, err := EntriesJSON(ctx, dirtyPaths, r.Repository.Manifest, "outside")
	if err != nil {
		return err
	}
	outsideJSON, err := json.Marshal(outside)
	if err != nil {
		return fmt.Errorf("compare_dirty: marshal: %w", err)
	}
	fp, err := JSONFingerprint(string(outsideJSON))
	if err != nil {
		return err
	}
	if fp != r.Repository.PreservedDirtyFingerprint {
		return fmt.Errorf("repository receipt matches: dirty fingerprint mismatch")
	}

	for _, unit := range r.Repository.Units {
		actual, err := PathState(unit.Path)
		if err != nil {
			return fmt.Errorf("repository receipt matches: pathstate %s: %w", unit.Path, err)
		}
		if actual != unit.Desired {
			return fmt.Errorf("repository receipt matches: unit %s desired state %q != actual %q", unit.Path, unit.Desired, actual)
		}
	}

	return nil
}

func ReceiptMatches() error {
	if err := RepositoryReceiptMatches(""); err != nil {
		return err
	}
	metaDir, _ := MetadataDir()
	stablePath := StablePath(metaDir)
	raw, _ := os.ReadFile(stablePath)
	var r Receipt
	_ = json.Unmarshal(raw, &r)
	if r.RepoRuntime.Status != PhasePassed {
		return fmt.Errorf("receipt matches: repoRuntime.status is %q, expected %q", r.RepoRuntime.Status, PhasePassed)
	}
	return nil
}

func CompareDirtyState(manifestPath string, expectedFingerprint string) bool {
	manifestRaw, err := os.ReadFile(manifestPath)
	if err != nil {
		return false
	}
	manifest := filterEmpty(strings.Split(string(manifestRaw), "\n"))

	ctx := context.Background()
	vcs, err := detectVCS()
	if err != nil {
		return false
	}
	dirtyPaths, err := CollectDirtyPaths(ctx, vcs)
	if err != nil {
		return false
	}

	outside, err := EntriesJSON(ctx, dirtyPaths, manifest, "outside")
	if err != nil {
		return false
	}
	outsideJSON, err := json.Marshal(outside)
	if err != nil {
		return false
	}
	fp, err := JSONFingerprint(string(outsideJSON))
	if err != nil {
		return false
	}
	return fp == expectedFingerprint
}

func filterEmpty(ss []string) []string {
	out := make([]string, 0, len(ss))
	for _, s := range ss {
		if s != "" {
			out = append(out, s)
		}
	}
	return out
}

func nullable(s string) *string {
	if s == "" {
		return nil
	}
	return &s
}

func stringOrEmpty(s *string) string {
	if s == nil {
		return ""
	}
	return *s
}

func readKitVersion() (string, error) {
	kitRoot, err := resolveKitRoot()
	if err != nil {
		return "", err
	}
	data, err := os.ReadFile(filepath.Join(kitRoot, "VERSION"))
	if err != nil {
		return "", fmt.Errorf("read kit version: %w", err)
	}
	return strings.TrimRight(string(data), "\n"), nil
}

func readRepoEngineVersion(repoRoot string) string {
	data, err := os.ReadFile(filepath.Join(repoRoot, ".substrate", "VERSION"))
	if err != nil {
		return ""
	}
	return strings.TrimRight(string(data), "\n")
}

func stringsFromNull(data []byte) []string {
	parts := strings.Split(strings.TrimRight(string(data), "\x00"), "\x00")
	out := make([]string, 0, len(parts))
	for _, p := range parts {
		if p != "" {
			out = append(out, p)
		}
	}
	return out
}

func stringSlicesEqual(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

func writeTempLines(lines []string) string {
	f, err := os.CreateTemp("", "substrate-manifest-*")
	if err != nil {
		return ""
	}
	defer func() { _ = f.Close() }()
	for _, line := range lines {
		_, _ = fmt.Fprintf(f, "%s\n", line)
	}
	return f.Name()
}
