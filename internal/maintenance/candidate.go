package maintenance

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/mp-pinheiro/substrate/internal/xshell"
)

func OverlayWorktree(ctx context.Context, candidateDir string, dirtyPaths []string, manifest []string, base string, checkpoint bool, profiles []string, phase string) error {
	sourceRoot, err := os.Getwd()
	if err != nil {
		return fmt.Errorf("overlay worktree: getwd: %w", err)
	}
	sourceRoot, err = filepath.EvalSymlinks(sourceRoot)
	if err != nil {
		return fmt.Errorf("overlay worktree: resolve source: %w", err)
	}

	kitRoot, err := resolveKitRoot()
	if err != nil {
		return fmt.Errorf("overlay worktree: kit root: %w", err)
	}
	kitRoot, err = filepath.EvalSymlinks(kitRoot)
	if err != nil {
		return fmt.Errorf("overlay worktree: resolve kit: %w", err)
	}

	if phase == "kit" && sourceRoot != kitRoot {
		return nil
	}

	for _, path := range dirtyPaths {
		switch phase {
		case "kit":
			if PathInManifest(path, manifest) {
				continue
			}
		case "seed":
			if !PathInManifest(path, manifest) {
				continue
			}
			if !checkpoint && DirtyPathSeedable(ctx, base, path, profiles) {
				continue
			}
		default:
			return fmt.Errorf("overlay worktree: unknown phase %q", phase)
		}

		if err := validatePath(path); err != nil {
			return fmt.Errorf("overlay worktree: %w", err)
		}

		info, err := os.Lstat(path)
		if err != nil {
			if os.IsNotExist(err) {
				target := filepath.Join(candidateDir, path)
				_ = os.RemoveAll(target)
				continue
			}
			return fmt.Errorf("overlay worktree: stat %s: %w", path, err)
		}
		if info.Mode()&os.ModeSymlink != 0 {
			continue
		}

		target := filepath.Join(candidateDir, path)
		if err := os.RemoveAll(target); err != nil {
			return fmt.Errorf("overlay worktree: remove %s: %w", path, err)
		}

		srcPath := filepath.Join(sourceRoot, path)
		if _, err := os.Stat(srcPath); err == nil {
			if err := os.MkdirAll(filepath.Dir(target), 0755); err != nil {
				return fmt.Errorf("overlay worktree: mkdir %s: %w", filepath.Dir(path), err)
			}
			res, runErr := xshell.Run(ctx, "cp", "-a", srcPath, target)
			if runErr != nil || res.Code != 0 {
				return fmt.Errorf("overlay worktree: cp %s: %w (stderr: %s)", path, runErr, res.Stderr)
			}
		}
	}

	return nil
}

func PrepareCandidate(ctx context.Context, candidateDir, base, archive string, dirtyPaths, manifest []string, checkpoint bool, profiles []string) error {
	if err := os.MkdirAll(candidateDir, 0755); err != nil {
		return fmt.Errorf("prepare candidate: mkdir: %w", err)
	}

	if base != "" {
		res, err := xshell.Run(ctx, "git", "cat-file", "-e", base+"^{commit}")
		if err == nil && res.Code == 0 {
			archiveRes, archErr := xshell.Run(ctx, "git", "archive", "--format=tar", "--output="+archive, base)
			if archErr != nil || archiveRes.Code != 0 {
				return fmt.Errorf("prepare candidate: git archive %s: %w (stderr: %s)", base, archErr, archiveRes.Stderr)
			}
			tarRes, tarErr := xshell.Run(ctx, "tar", "-xf", archive, "-C", candidateDir)
			if tarErr != nil || tarRes.Code != 0 {
				return fmt.Errorf("prepare candidate: tar extract: %w (stderr: %s)", tarErr, tarRes.Stderr)
			}
			if err := PreserveModes(candidateDir); err != nil {
				return fmt.Errorf("prepare candidate: %w", err)
			}
		}
	}

	if err := OverlayWorktree(ctx, candidateDir, dirtyPaths, manifest, base, checkpoint, profiles, "kit"); err != nil {
		return fmt.Errorf("prepare candidate: %w", err)
	}

	gitSteps := []struct {
		args []string
	}{
		{[]string{"-C", candidateDir, "init", "-q", "--initial-branch=main"}},
		{[]string{"-C", candidateDir, "config", "user.name", "substrate-maintenance"}},
		{[]string{"-C", candidateDir, "config", "user.email", "substrate@localhost"}},
		{[]string{"-C", candidateDir, "add", "-f", "-A"}},
		{[]string{"-C", candidateDir, "commit", "-q", "--allow-empty", "-m", "chore: seed maintenance candidate"}},
	}
	for _, s := range gitSteps {
		res, err := xshell.Run(ctx, "git", s.args...)
		if err != nil || res.Code != 0 {
			return fmt.Errorf("prepare candidate: git %s: %w (stderr: %s)", s.args[1], err, res.Stderr)
		}
	}

	if err := OverlayWorktree(ctx, candidateDir, dirtyPaths, manifest, base, checkpoint, profiles, "seed"); err != nil {
		return fmt.Errorf("prepare candidate: %w", err)
	}

	return nil
}

func RenderCandidate(ctx context.Context, candidateDir, renderHome, output string, c *Context) error {
	profilesCSV := strings.Join(c.Profiles, ",")

	var forceFlag []string
	if c.Force {
		forceFlag = []string{"--force"}
	}

	sourceRoot, err := os.Getwd()
	if err != nil {
		return fmt.Errorf("render candidate: getwd: %w", err)
	}
	sourceRoot, err = filepath.EvalSymlinks(sourceRoot)
	if err != nil {
		return fmt.Errorf("render candidate: resolve source: %w", err)
	}

	kitRoot, err := resolveKitRoot()
	if err != nil {
		return fmt.Errorf("render candidate: kit root: %w", err)
	}
	kitRoot, err = filepath.EvalSymlinks(kitRoot)
	if err != nil {
		return fmt.Errorf("render candidate: resolve kit: %w", err)
	}

	var worktreeFlag []string
	if c.FromWorktree || sourceRoot == kitRoot {
		worktreeFlag = []string{"--from-worktree"}
	}

	substrateBin := filepath.Join(kitRoot, "bin", "substrate")

	var args []string
	if c.Operation == OpUpdate {
		args = append([]string{"__maintenance-render", "update", "--apply"}, forceFlag...)
		args = append(args, worktreeFlag...)
	} else {
		args = append([]string{"__maintenance-render", c.Operation, "--profile", profilesCSV, "--vcs", c.VCS}, forceFlag...)
		args = append(args, worktreeFlag...)
	}

	res, runErr := xshell.RunIn(ctx, candidateDir, substrateBin, args...)
	combined := append(res.Stdout, res.Stderr...)
	if writeErr := os.WriteFile(output, combined, 0644); writeErr != nil {
		return fmt.Errorf("render candidate: write output: %w", writeErr)
	}
	if runErr != nil || res.Code != 0 {
		return fmt.Errorf("render candidate: render failed (code %d): %w (stderr: %s)", res.Code, runErr, res.Stderr)
	}

	return nil
}

func GateCandidate(ctx context.Context, candidateDir, output, callerHome string, c *Context) error {
	addRes, addErr := xshell.Run(ctx, "git", "-C", candidateDir, "add", "-f", "-A")
	if addErr != nil || addRes.Code != 0 {
		return fmt.Errorf("gate candidate: git add: %w (stderr: %s)", addErr, addRes.Stderr)
	}

	var acceptFlags []string
	if c.AcceptRegression != "" {
		acceptFlags = []string{"--accept-regression=" + c.AcceptRegression, "--reason=" + c.AcceptReason}
	}

	gateScript := filepath.Join(candidateDir, ".substrate", "gate.sh")
	baselinePath := filepath.Join(candidateDir, "substrate-baseline.json")

	var combined []byte
	_, baselineErr := os.Stat(baselinePath)
	noBaseline := os.IsNotExist(baselineErr)

	if noBaseline {
		if c.AcceptBaseline {
			args := append([]string{"--update-baseline"}, acceptFlags...)
			res, runErr := xshell.RunIn(ctx, candidateDir, gateScript, args...)
			combined = append(res.Stdout, res.Stderr...)
			if runErr != nil || res.Code != 0 {
				_ = os.WriteFile(output, combined, 0644)
				return fmt.Errorf("gate candidate: update baseline failed (code %d): %w (stderr: %s)", res.Code, runErr, res.Stderr)
			}
		} else if c.Checkpoint {
			fmt.Fprintf(os.Stderr, "maintenance blocked: initial debt requires --accept-baseline\n")
			return fmt.Errorf("gate candidate: initial debt requires --accept-baseline")
		}
	}

	if c.Checkpoint {
		_, baseErr := os.Stat(baselinePath)
		if baseErr == nil {
			tightenArgs := append([]string{"--tighten"}, acceptFlags...)
			tightenRes, tightenErr := xshell.RunIn(ctx, candidateDir, gateScript, tightenArgs...)
			combined = append(tightenRes.Stdout, tightenRes.Stderr...)
			if tightenErr != nil || tightenRes.Code != 0 {
				_ = os.WriteFile(output, combined, 0644)
				return fmt.Errorf("gate candidate: tighten failed (code %d): %w (stderr: %s)", tightenRes.Code, tightenErr, tightenRes.Stderr)
			}

			gateRes, gateErr := xshell.RunIn(ctx, candidateDir, gateScript)
			combined = append(combined, gateRes.Stdout...)
			combined = append(combined, gateRes.Stderr...)
			if gateErr != nil || gateRes.Code != 0 {
				_ = os.WriteFile(output, combined, 0644)
				return fmt.Errorf("gate candidate: gate failed (code %d): %w (stderr: %s)", gateRes.Code, gateErr, gateRes.Stderr)
			}
		}
	} else if !noBaseline || c.AcceptBaseline {
		gateArgs := acceptFlags
		gateRes, gateErr := xshell.RunIn(ctx, candidateDir, gateScript, gateArgs...)
		combined = append(combined, gateRes.Stdout...)
		combined = append(combined, gateRes.Stderr...)
		if gateErr != nil || gateRes.Code != 0 {
			_ = os.WriteFile(output, combined, 0644)
			return fmt.Errorf("gate candidate: gate failed (code %d): %w (stderr: %s)", gateRes.Code, gateErr, gateRes.Stderr)
		}
	}

	if writeErr := os.WriteFile(output, combined, 0644); writeErr != nil {
		return fmt.Errorf("gate candidate: write output: %w", writeErr)
	}

	return nil
}

func CandidateChanges(ctx context.Context, candidateDir string, manifest []string) ([]string, []string, error) {
	addRes, addErr := xshell.Run(ctx, "git", "-C", candidateDir, "add", "-f", "-A")
	if addErr != nil || addRes.Code != 0 {
		return nil, nil, fmt.Errorf("candidate changes: git add: %w (stderr: %s)", addErr, addRes.Stderr)
	}

	diffRes, diffErr := xshell.RunC(ctx, "git", "-C", candidateDir, "diff", "--cached", "--name-only", "-z", "--no-renames", "HEAD")
	if diffErr != nil || diffRes.Code != 0 {
		return nil, nil, fmt.Errorf("candidate changes: git diff: %w (stderr: %s)", diffErr, diffRes.Stderr)
	}

	parts := bytes.Split(bytes.TrimRight(diffRes.Stdout, "\x00"), []byte("\x00"))
	var changedPaths []string
	var changedLines []string

	for _, p := range parts {
		path := string(p)
		if path == "" {
			continue
		}
		if err := validatePath(path); err != nil {
			return nil, nil, fmt.Errorf("candidate changes: %w", err)
		}
		if !PathInManifest(path, manifest) {
			fmt.Fprintf(os.Stderr, "maintenance renderer wrote outside its manifest: %s\n", path)
			return nil, nil, fmt.Errorf("candidate changes: path outside manifest: %s", path)
		}
		changedPaths = append(changedPaths, path)
		changedLines = append(changedLines, path)
	}

	sort.Strings(changedLines)
	unique := changedLines[:0]
	for i, line := range changedLines {
		if i == 0 || line != changedLines[i-1] {
			unique = append(unique, line)
		}
	}
	changedLines = unique

	return changedPaths, changedLines, nil
}

func ChangedUnits(manifest []string, changedLines []string) []string {
	var units []string
	for _, unit := range manifest {
		for _, path := range changedLines {
			if path == unit || strings.HasPrefix(path, unit+"/") {
				units = append(units, unit)
				break
			}
		}
	}
	return units
}
