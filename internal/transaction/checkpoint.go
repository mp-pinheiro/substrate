package transaction

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"github.com/mp-pinheiro/substrate/internal/config"
	"github.com/mp-pinheiro/substrate/internal/lifecycle"
	"github.com/mp-pinheiro/substrate/internal/logx"
	"github.com/mp-pinheiro/substrate/internal/policy"
	"github.com/mp-pinheiro/substrate/internal/receipt"
	"github.com/mp-pinheiro/substrate/internal/vcs"
	"github.com/mp-pinheiro/substrate/internal/xshell"
)

var convCommitRe = regexp.MustCompile(`^(feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert)(\([^)]+\))?!?: [^[:space:]]`)

// RunCheckpoint is the checkpoint transaction state machine, porting core/checkpoint.sh.
// Returns 0 on success, ExitPreflight for preflight refusal, or 1 for runtime failure.
func RunCheckpoint(ctx context.Context, args []string) int {
	opts, code := parseCheckpointArgs(args)
	if code != 0 {
		return code
	}

	repoRoot, err := resolveRepoRoot()
	if err != nil {
		logx.Err().Line("checkpoint blocked: %v", err)
		return ExitPreflight
	}

	baselinePath := filepath.Join(repoRoot, "substrate-baseline.json")
	if _, err := os.Stat(baselinePath); err != nil {
		logx.Err().Line("checkpoint blocked: establish initial debt explicitly with: substrate baseline")
		return ExitPreflight
	}

	repo, err := DetectRepo(repoRoot)
	if err != nil {
		logx.Err().Line("checkpoint blocked: %v", err)
		return ExitPreflight
	}

	metadataDir, err := ResolveMetadataDir(ctx, repo)
	if err != nil {
		logx.Err().Line("checkpoint blocked: no repository metadata found")
		return ExitPreflight
	}
	lockPath := filepath.Join(metadataDir, "substrate-checkpoint.lock")
	if err := Lock(lockPath); err != nil {
		logx.Err().Line("checkpoint blocked: %v", err)
		return ExitPreflight
	}
	defer Unlock(lockPath)

	var ownedPaths []string
	if opts.session != "" {
		substrateDir := filepath.Join(repoRoot, ".substrate")
		pathsCfg, err := config.DiscoverFromSubstrateDir(substrateDir)
		if err != nil {
			logx.Err().Line("checkpoint blocked: config resolution failed")
			return ExitPreflight
		}
		le := lifecycle.New(pathsCfg, repo)
		le.SetStateDir(filepath.Join(metadataDir, "substrate", "agent-sessions"))
		result := le.Verify(ctx, opts.session)
		if result.Code != 0 {
			_, _ = os.Stderr.Write(result.Stderr)
			return ExitPreflight
		}
		ownedPaths = parseVerifyPaths(result.Stdout)
		if len(ownedPaths) == 0 {
			logx.Err().Line("checkpoint blocked: no pending agent-owned changes")
			return ExitPreflight
		}
	} else {
		ownedPaths = opts.paths
	}
	if len(ownedPaths) == 0 {
		logx.Err().Line("checkpoint blocked: no agent-owned paths were supplied; pass --path <path> once per file")
		return ExitPreflight
	}

	normalized, err := NormalizePaths(ownedPaths)
	if err != nil {
		logx.Err().Line("checkpoint blocked: %v", err)
		return ExitPreflight
	}
	for _, p := range normalized {
		if d, blocked := policy.CheckHard(p); blocked {
			logx.Err().Line("checkpoint %s", strings.TrimSuffix(d.Stderr, "\n"))
			return ExitPreflight
		}
	}

	current, err := ChangedPaths(ctx, repo)
	if err != nil {
		logx.Err().Line("checkpoint blocked: cannot inspect working-copy changes")
		return ExitPreflight
	}

	missing := CommMinus23(normalized, current)
	if len(missing) > 0 {
		logx.Err().Line("checkpoint blocked: the following paths are not pending working-copy changes:")
		for _, p := range missing {
			logx.Err().Line("  %s", p)
		}
		return ExitPreflight
	}

	leftover := SetDifference(normalized, current)
	if len(leftover) == 0 {
		return runCheckpointFull(ctx, repo, repoRoot, metadataDir, normalized, opts, baselinePath)
	}
	return runCheckpointScoped(ctx, repo, repoRoot, metadataDir, normalized, leftover, opts, baselinePath)
}

type checkpointOpts struct {
	message string
	session string
	paths   []string
	accept  []string
	reason  string
	json    bool
}

func parseCheckpointArgs(args []string) (checkpointOpts, int) {
	var opts checkpointOpts
	for i := 0; i < len(args); i++ {
		switch {
		case args[i] == "--message":
			if i+1 >= len(args) {
				usage()
				return opts, ExitPreflight
			}
			i++
			opts.message = args[i]
		case args[i] == "--path":
			if i+1 >= len(args) {
				usage()
				return opts, ExitPreflight
			}
			i++
			opts.paths = append(opts.paths, args[i])
		case args[i] == "--session":
			if i+1 >= len(args) {
				usage()
				return opts, ExitPreflight
			}
			i++
			opts.session = args[i]
		case args[i] == "--accept-regression":
			logx.Err().Line("checkpoint blocked: --accept-regression requires the keyed form: --accept-regression=<metric>[,<metric>]")
			return opts, ExitPreflight
		case strings.HasPrefix(args[i], "--accept-regression="):
			csv := strings.TrimPrefix(args[i], "--accept-regression=")
			if csv == "" {
				logx.Err().Line("checkpoint blocked: --accept-regression= needs at least one metric")
				return opts, ExitPreflight
			}
			opts.accept = strings.Split(csv, ",")
		case args[i] == "--reason":
			if i+1 >= len(args) {
				usage()
				return opts, ExitPreflight
			}
			i++
			opts.reason = args[i]
		case args[i] == "--json":
			opts.json = true
		default:
			usage()
			return opts, ExitPreflight
		}
	}

	if opts.message == "" {
		usage()
		return opts, ExitPreflight
	}
	if !convCommitRe.MatchString(opts.message) {
		logx.Err().Line("checkpoint blocked: message must follow Conventional Commits — type(scope): subject")
		return opts, ExitPreflight
	}
	if len(opts.accept) > 0 && opts.reason == "" {
		logx.Err().Line("checkpoint blocked: --accept-regression requires --reason \"<text>\" — the justification is committed to substrate-baseline.json")
		return opts, ExitPreflight
	}
	if opts.reason != "" && len(opts.accept) == 0 {
		logx.Err().Line("checkpoint blocked: --reason applies only to --accept-regression")
		return opts, ExitPreflight
	}

	return opts, 0
}

func usage() {
	logx.Err().Line("usage: substrate-engine checkpoint --message \"type(scope): subject\" [--session <id> | --path <repo-relative-path> ...] [--accept-regression=<metric>[,<metric>] --reason <text>] [--json]")
}

func runCheckpointFull(ctx context.Context, repo *vcs.Repo, repoRoot, metadataDir string, normalized []string, opts checkpointOpts, baselinePath string) int {
	baselineBackup, err := os.ReadFile(baselinePath)
	if err != nil {
		logx.Err().Line("checkpoint blocked: cannot read baseline")
		return 1
	}

	gateArgs := []string{"--tighten"}
	if len(opts.accept) > 0 {
		gateArgs = append(gateArgs, "--accept-regression="+strings.Join(opts.accept, ","))
		gateArgs = append(gateArgs, "--reason="+opts.reason)
	}
	gateOut, err := runGate(ctx, repoRoot, gateArgs...)
	if err != nil {
		logx.Out().Line("%s", gateOut)
		logx.Err().Line("checkpoint blocked: gate or baseline tightening failed")
		return 1
	}
	logx.Out().Line("%s", gateOut)

	commitPaths := make([]string, len(normalized))
	copy(commitPaths, normalized)

	baselineChanged := false
	currentBaseline, _ := os.ReadFile(baselinePath)
	if string(currentBaseline) != string(baselineBackup) {
		baselineChanged = true
		commitPaths = append(commitPaths, "substrate-baseline.json")
	}

	commit, commitOut, err := commitPathsFn(ctx, repo, repoRoot, opts.message, commitPaths)
	if err != nil {
		if baselineChanged {
			restoreBaseline(baselinePath, baselineBackup)
		}
		logx.Err().Line("checkpoint failed: %v", err)
		return 1
	}
	logx.Out().Line("%s", commitOut)

	current, err := ChangedPaths(ctx, repo)
	if err != nil {
		logx.Err().Line("checkpoint incomplete: cannot inspect post-commit working copy")
		return 1
	}
	if len(current) != 0 {
		logx.Err().Line("checkpoint incomplete: post-commit pending paths remain")
		for _, p := range current {
			logx.Err().Line("  %s", p)
		}
		return 1
	}

	verifyOut, err := runGate(ctx, repoRoot)
	if err != nil {
		logx.Out().Line("%s", verifyOut)
		logx.Err().Line("checkpoint incomplete: post-commit gate failed; receipt not written")
		return 1
	}
	logx.Out().Line("%s", verifyOut)

	acceptCSV := strings.Join(opts.accept, ",")
	receiptJSON, err := receipt.Write(ctx, repoRoot, "checkpoint", commit, string(repo.Kind), opts.session, acceptCSV)
	if err != nil {
		logx.Err().Line("checkpoint incomplete: exact-state receipt write failed")
		return 1
	}

	if opts.session != "" {
		substrateDir := filepath.Join(repoRoot, ".substrate")
		pathsCfg, _ := config.DiscoverFromSubstrateDir(substrateDir)
		le := lifecycle.New(pathsCfg, repo)
		le.SetStateDir(filepath.Join(metadataDir, "substrate", "agent-sessions"))
		result := le.Complete(ctx, opts.session, commit)
		if result.Code != 0 {
			_, _ = os.Stderr.Write(result.Stderr)
			logx.Err().Line("checkpoint incomplete: commit exists but Claude lifecycle receipt update failed")
			return 1
		}
	}

	if opts.json {
		logx.Out().Line("%s", receiptJSON)
	} else {
		logx.Out().Line("checkpoint complete: %s (%s)", commit[:12], opts.message)
	}
	return 0
}

func runCheckpointScoped(ctx context.Context, repo *vcs.Repo, repoRoot, metadataDir string, normalized, leftover []string, opts checkpointOpts, baselinePath string) int {
	for _, p := range leftover {
		if p == "substrate-baseline.json" {
			logx.Err().Line("checkpoint blocked: substrate-baseline.json carries changes outside agent ownership — resolve it before a path-scoped checkpoint")
			return ExitPreflight
		}
	}

	base, err := CurrentGateRevision(ctx, repo)
	if err != nil || base == "" {
		logx.Err().Line("checkpoint blocked: cannot resolve the checked revision")
		return ExitPreflight
	}
	res, err := xshell.RunIn(ctx, repoRoot, "git", "cat-file", "-e", base+"^{commit}")
	if err != nil || res.Code != 0 {
		logx.Err().Line("checkpoint blocked: path-scoped checkpoint needs git object access to revision %s", base)
		return ExitPreflight
	}

	candidate, err := NewCandidate(ctx, repo, base, normalized)
	if err != nil {
		logx.Err().Line("checkpoint blocked: %v", err)
		return ExitPreflight
	}
	defer candidate.Cleanup()

	gateArgs := []string{"--tighten"}
	if len(opts.accept) > 0 {
		gateArgs = append(gateArgs, "--accept-regression="+strings.Join(opts.accept, ","))
		gateArgs = append(gateArgs, "--reason="+opts.reason)
	}
	gateOut, err := candidate.RunGate(ctx, gateArgs...)
	if err != nil {
		logx.Out().Line("%s", gateOut)
		logx.Err().Line("checkpoint blocked: gate failed for the agent-owned paths (unowned pending work was excluded)")
		return 1
	}
	logx.Out().Line("%s", gateOut)

	baselineChanged, err := candidate.CopyBaseline(repoRoot)
	if err != nil {
		logx.Err().Line("checkpoint blocked: %v", err)
		return ExitPreflight
	}

	commitPaths := make([]string, len(normalized))
	copy(commitPaths, normalized)
	if baselineChanged {
		commitPaths = append(commitPaths, "substrate-baseline.json")
	}

	commit, commitOut, err := commitPathsFn(ctx, repo, repoRoot, opts.message, commitPaths)
	if err != nil {
		logx.Err().Line("checkpoint failed: %v", err)
		return 1
	}
	logx.Out().Line("%s", commitOut)

	current, err := ChangedPaths(ctx, repo)
	if err != nil {
		logx.Err().Line("checkpoint incomplete: cannot inspect post-commit working copy")
		return 1
	}
	if !stringSlicesEqual(current, leftover) {
		logx.Err().Line("checkpoint incomplete: post-commit pending paths diverge from the expected remainder")
		return 1
	}

	acceptCSV := strings.Join(opts.accept, ",")
	receiptJSON, err := receipt.Write(ctx, repoRoot, "checkpoint", commit, string(repo.Kind), opts.session, acceptCSV)
	if err != nil {
		logx.Err().Line("checkpoint incomplete: exact-state receipt write failed")
		return 1
	}

	if opts.session != "" {
		substrateDir := filepath.Join(repoRoot, ".substrate")
		pathsCfg, _ := config.DiscoverFromSubstrateDir(substrateDir)
		le := lifecycle.New(pathsCfg, repo)
		le.SetStateDir(filepath.Join(metadataDir, "substrate", "agent-sessions"))
		result := le.Complete(ctx, opts.session, commit)
		if result.Code != 0 {
			_, _ = os.Stderr.Write(result.Stderr)
			logx.Err().Line("checkpoint incomplete: commit exists but Claude lifecycle receipt update failed")
			return 1
		}
	}

	if opts.json {
		logx.Out().Line("%s", receiptJSON)
	} else {
		logx.Out().Line("checkpoint complete: %s (%s)", commit[:12], opts.message)
	}
	if len(leftover) > 0 {
		logx.Err().Line("checkpoint left unowned pending paths in place:")
		for _, p := range leftover {
			logx.Err().Line("  %s", p)
		}
	}
	return 0
}

func resolveRepoRoot() (string, error) {
	if r := os.Getenv("REPO_ROOT"); r != "" {
		return r, nil
	}
	dir, err := os.Getwd()
	if err != nil {
		return "", fmt.Errorf("checkpoint: getwd: %w", err)
	}
	return dir, nil
}

func runGate(ctx context.Context, repoRoot string, args ...string) (string, error) {
	bin, err := xshell.EngineBin()
	if err != nil {
		return "", fmt.Errorf("gate: %w", err)
	}
	res, err := xshell.RunIn(ctx, repoRoot, bin, append([]string{"gate"}, args...)...)
	output := string(res.Stdout) + string(res.Stderr)
	if err != nil {
		return output, fmt.Errorf("gate: %w", err)
	}
	if res.Code != 0 {
		return output, fmt.Errorf("gate failed with code %d", res.Code)
	}
	return output, nil
}

func commitPathsFn(ctx context.Context, repo *vcs.Repo, repoRoot, message string, paths []string) (string, string, error) {
	if repo.Kind == vcs.KindJJ {
		return commitJJ(ctx, repo, message, paths)
	}
	return commitGit(ctx, repoRoot, message, paths)
}

func commitJJ(ctx context.Context, repo *vcs.Repo, message string, paths []string) (string, string, error) {
	args := append([]string{"commit", "--message", message, "--"}, paths...)
	res, runErr := xshell.RunIn(ctx, repo.Root, "jj", args...)
	output := string(res.Stdout)
	if runErr != nil || res.Code != 0 {
		return "", output + string(res.Stderr), fmt.Errorf("jj commit rejected the transaction: %w", runErr)
	}
	revRes, revErr := xshell.RunIn(ctx, repo.Root, "jj", "log", "-r", "@-", "--no-graph", "-T", "commit_id")
	if revErr != nil || revRes.Code != 0 {
		return "", output, fmt.Errorf("cannot resolve commit id: %w", revErr)
	}
	return strings.TrimSpace(string(revRes.Stdout)), output, nil
}

func commitGit(ctx context.Context, repoRoot, message string, paths []string) (string, string, error) {
	addArgs := append([]string{"add", "--"}, paths...)
	addRes, addErr := xshell.RunIn(ctx, repoRoot, "git", addArgs...)
	if addErr != nil || addRes.Code != 0 {
		return "", string(addRes.Stderr), fmt.Errorf("git could not stage the owned paths")
	}
	commitArgs := append([]string{"commit", "--only", "-m", message, "--"}, paths...)
	commitRes, commitErr := xshell.RunIn(ctx, repoRoot, "git", commitArgs...)
	output := string(commitRes.Stdout)
	if commitErr != nil || commitRes.Code != 0 {
		_, _ = xshell.RunIn(ctx, repoRoot, "git", append([]string{"reset", "--quiet", "--"}, paths...)...)
		return "", output + string(commitRes.Stderr), fmt.Errorf("git commit rejected the transaction: %w", commitErr)
	}
	revRes, revErr := xshell.RunIn(ctx, repoRoot, "git", "rev-parse", "HEAD")
	if revErr != nil || revRes.Code != 0 {
		return "", output, fmt.Errorf("cannot resolve commit hash: %w", revErr)
	}
	return strings.TrimSpace(string(revRes.Stdout)), output, nil
}

func restoreBaseline(path string, backup []byte) {
	staged, err := os.CreateTemp(filepath.Dir(path), "substrate-baseline.json.*")
	if err != nil {
		return
	}
	stagedPath := staged.Name()
	_ = staged.Close()
	_ = os.WriteFile(stagedPath, backup, 0644)
	_ = os.Rename(stagedPath, path)
}

type verifyOutput struct {
	Paths []string `json:"paths"`
}

func parseVerifyPaths(raw []byte) []string {
	var out verifyOutput
	if err := json.Unmarshal(raw, &out); err != nil {
		return nil
	}
	return out.Paths
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
