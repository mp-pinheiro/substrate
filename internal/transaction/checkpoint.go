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
	"github.com/mp-pinheiro/substrate/internal/recovery"
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

func emitCommitFailure(opts checkpointOpts, err error, rollback func()) int {
	if rollback != nil {
		rollback()
	}
	return emitCheckpointFailure(opts, recovery.Report{
		Status: "blocked", Code: "checkpoint.commit", Owner: "user", Retry: "terminal",
		Summary: "checkpoint commit failed", Details: []string{err.Error()},
		Next: "repair the reported commit failure, then rerun checkpoint",
	}, 1)
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
		return emitGateFailure(opts, gateOut, err)
	}
	logx.Out().Line("%s", gateOut)

	commitPaths := make([]string, len(normalized))
	copy(commitPaths, normalized)
	baseRevision, baseErr := CurrentGateRevision(ctx, repo)
	if baseErr != nil {
		return emitCheckpointFailure(opts, recovery.Report{Status: "blocked", Code: "checkpoint.bookmark-ambiguous", Owner: "user", Retry: "terminal", Summary: "checkpoint base revision unavailable", Details: []string{baseErr.Error()}, Next: "resolve the repository revision and rerun checkpoint"})
	}
	publicationBookmark, bookmarkErr := resolvePublicationBookmark(ctx, repo, baseRevision)
	if bookmarkErr != nil {
		return emitCheckpointFailure(opts, recovery.Report{Status: "blocked", Code: "checkpoint.bookmark-ambiguous", Owner: "user", Retry: "terminal", Summary: "checkpoint publication bookmark is ambiguous", Details: []string{bookmarkErr.Error()}, Next: "choose the intended local bookmark and rerun checkpoint"})
	}

	baselineChanged := false
	currentBaseline, _ := os.ReadFile(baselinePath)
	if string(currentBaseline) != string(baselineBackup) {
		baselineChanged = true
		commitPaths = append(commitPaths, "substrate-baseline.json")
	}

	commit, commitOut, err := commitPathsFn(ctx, repo, repoRoot, opts.message, commitPaths)
	if err != nil {
		var rollback func()
		if baselineChanged {
			rollback = func() { restoreBaseline(baselinePath, baselineBackup) }
		}
		return emitCommitFailure(opts, err, rollback)
	}
	if err := finalizePublicationBookmark(ctx, repo, publicationBookmark, commit); err != nil {
		return emitCheckpointFailure(opts, recovery.Report{Status: "incomplete", Code: "checkpoint.bookmark-finalize", Owner: "user", Retry: "terminal", Summary: "checkpoint committed but publication bookmark finalization failed", Details: []string{fmt.Sprintf("commit: %s", commit), err.Error()}, Next: fmt.Sprintf("run jj bookmark set %s -r %s; do not run jj undo/redo/op restore", publicationBookmark, commit)}, 1)
	}
	logx.Out().Line("%s", commitOut)

	current, err := ChangedPaths(ctx, repo)
	if err != nil {
		return emitCheckpointFailure(opts, recovery.Report{
			Status: "incomplete", Code: "checkpoint.incomplete", Owner: "user", Retry: "terminal",
			Summary: "checkpoint committed but post-commit state inspection failed",
			Details: []string{fmt.Sprintf("commit: %s", commit), "failed phase: post-commit state inspection", err.Error()},
			Next:    "preserve the commit and pending state; do not run jj undo/redo/op restore",
		}, 1)
	}
	if len(current) != 0 {
		details := []string{fmt.Sprintf("commit: %s", commit), "failed phase: post-commit state inspection"}
		details = append(details, current...)
		return emitCheckpointFailure(opts, recovery.Report{
			Status: "incomplete", Code: "checkpoint.incomplete", Owner: "user", Retry: "terminal",
			Summary: "checkpoint committed but pending paths remain",
			Details: details,
			Next:    "preserve the commit and pending state; do not run jj undo/redo/op restore",
		}, 1)
	}

	verifyOut, err := runGate(ctx, repoRoot)
	if err != nil {
		logx.Out().Line("%s", verifyOut)
		details := []string{fmt.Sprintf("commit: %s", commit), "failed phase: post-commit gate verification"}
		if report, ok := parseRecoveryReport(verifyOut); ok {
			details = append(details, report.Details...)
		} else {
			details = append(details, strings.TrimSpace(verifyOut))
		}
		return emitCheckpointFailure(opts, recovery.Report{
			Status: "incomplete", Code: "checkpoint.incomplete", Owner: "user", Retry: "terminal",
			Summary: "checkpoint committed but post-commit verification failed", Details: details,
			Next: "preserve the commit and pending state; do not run jj undo/redo/op restore",
		}, 1)
	}
	logx.Out().Line("%s", verifyOut)

	return finishCheckpoint(ctx, repo, repoRoot, metadataDir, commit, publicationBookmark, opts)
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
	publicationBookmark, bookmarkErr := resolvePublicationBookmark(ctx, repo, base)
	if bookmarkErr != nil {
		return emitCheckpointFailure(opts, recovery.Report{Status: "blocked", Code: "checkpoint.bookmark-ambiguous", Owner: "user", Retry: "terminal", Summary: "checkpoint publication bookmark is ambiguous", Details: []string{bookmarkErr.Error()}, Next: "choose the intended local bookmark and rerun checkpoint"})
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
	gateArgs = append(gateArgs, "--json")
	gateOut, err := candidate.RunGate(ctx, gateArgs...)
	if err != nil {
		return emitGateFailure(opts, gateOut, err)
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
		return emitCommitFailure(opts, err, nil)
	}
	if err := finalizePublicationBookmark(ctx, repo, publicationBookmark, commit); err != nil {
		return emitCheckpointFailure(opts, recovery.Report{Status: "incomplete", Code: "checkpoint.bookmark-finalize", Owner: "user", Retry: "terminal", Summary: "checkpoint committed but publication bookmark finalization failed", Details: []string{fmt.Sprintf("commit: %s", commit), err.Error()}, Next: fmt.Sprintf("run jj bookmark set %s -r %s; do not run jj undo/redo/op restore", publicationBookmark, commit)}, 1)
	}
	logx.Out().Line("%s", commitOut)

	current, err := ChangedPaths(ctx, repo)
	if err != nil {
		return emitCheckpointFailure(opts, recovery.Report{
			Status: "incomplete", Code: "checkpoint.incomplete", Owner: "user", Retry: "terminal",
			Summary: "checkpoint committed but post-commit state inspection failed",
			Details: []string{fmt.Sprintf("commit: %s", commit), err.Error()},
			Next:    "preserve the commit and pending state; do not run jj undo/redo/op restore",
		}, 1)
	}
	if !stringSlicesEqual(current, leftover) {
		return emitCheckpointFailure(opts, recovery.Report{
			Status: "incomplete", Code: "checkpoint.incomplete", Owner: "user", Retry: "terminal",
			Summary: "checkpoint committed but pending paths diverged",
			Details: append([]string{fmt.Sprintf("commit: %s", commit)}, current...),
			Next:    "preserve the commit and pending state; do not run jj undo/redo/op restore",
		}, 1)
	}

	if result := finishCheckpoint(ctx, repo, repoRoot, metadataDir, commit, publicationBookmark, opts); result != 0 {
		return result
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
func finishCheckpoint(ctx context.Context, repo *vcs.Repo, repoRoot, metadataDir, commit, publicationBookmark string, opts checkpointOpts) int {
	acceptCSV := strings.Join(opts.accept, ",")
	receiptJSON, err := receipt.WriteWithPublicationBookmark(ctx, repoRoot, "checkpoint", commit, string(repo.Kind), opts.session, acceptCSV, publicationBookmark)
	if err != nil {
		return emitCheckpointFailure(opts, recovery.Report{
			Status: "incomplete", Code: "checkpoint.incomplete", Owner: "user", Retry: "terminal",
			Summary: "checkpoint committed but exact-state receipt write failed",
			Details: []string{fmt.Sprintf("commit: %s", commit), err.Error()},
			Next:    "preserve the commit and pending state; do not run jj undo/redo/op restore",
		}, 1)
	}

	if opts.session != "" {
		substrateDir := filepath.Join(repoRoot, ".substrate")
		pathsCfg, _ := config.DiscoverFromSubstrateDir(substrateDir)
		le := lifecycle.New(pathsCfg, repo)
		le.SetStateDir(filepath.Join(metadataDir, "substrate", "agent-sessions"))
		result := le.Complete(ctx, opts.session, commit)
		if result.Code != 0 {
			_, _ = os.Stderr.Write(result.Stderr)
			return emitCheckpointFailure(opts, recovery.Report{
				Status: "incomplete", Code: "checkpoint.incomplete", Owner: "user", Retry: "terminal",
				Summary: "checkpoint committed but lifecycle receipt update failed",
				Details: []string{fmt.Sprintf("commit: %s", commit), string(result.Stderr)},
				Next:    "preserve the commit and pending state; do not run jj undo/redo/op restore",
			}, 1)
		}
	}

	if opts.json {
		logx.Out().Line("%s", receiptJSON)
	} else {
		logx.Out().Line("checkpoint complete: %s (%s)", commit[:12], opts.message)
	}
	return 0
}
func runGate(ctx context.Context, repoRoot string, args ...string) (string, error) {
	bin, err := xshell.EngineBin()
	if err != nil {
		return "", fmt.Errorf("gate: %w", err)
	}
	gateArgs := append([]string{"gate"}, args...)
	gateArgs = append(gateArgs, "--json")
	res, err := xshell.RunIn(ctx, repoRoot, bin, gateArgs...)
	output := string(res.Stdout) + string(res.Stderr)
	if err != nil {
		return output, fmt.Errorf("gate: %w", err)
	}
	if res.Code != 0 {
		if report, ok := parseRecoveryReport(output); ok {
			return output, gateReportError{report: report, code: res.Code}
		}
		return output, fmt.Errorf("gate failed with code %d", res.Code)
	}
	return output, nil
}

type gateReportError struct {
	report recovery.Report
	code   int
}

func (e gateReportError) Error() string { return e.report.Summary }

func parseRecoveryReport(output string) (recovery.Report, bool) {
	for _, line := range reverseLines(strings.TrimSpace(output)) {
		var report recovery.Report
		if json.Unmarshal([]byte(line), &report) != nil ||
			(report.Status != "blocked" && report.Status != "incomplete") ||
			report.Code == "" || report.Owner == "" || report.Retry == "" ||
			report.Summary == "" || report.Next == "" {
			continue
		}
		return report, true
	}
	return recovery.Report{}, false
}

func reverseLines(s string) []string {
	if s == "" {
		return nil
	}
	parts := strings.Split(s, "\n")
	for i, j := 0, len(parts)-1; i < j; i, j = i+1, j-1 {
		parts[i], parts[j] = parts[j], parts[i]
	}
	return parts
}

func resolvePublicationBookmark(ctx context.Context, repo *vcs.Repo, base string) (string, error) {
	if repo.Kind != vcs.KindJJ {
		return "", nil
	}
	res, err := xshell.RunIn(ctx, repo.Root, "jj", "bookmark", "list", "--template", `name ++ "\t" ++ if(self.remote(), "remote", "local") ++ "\t" ++ self.normal_target().commit_id() ++ "\n"`)
	if err != nil || res.Code != 0 {
		return "", fmt.Errorf("cannot inspect jj bookmarks")
	}
	var trunk, feature []string
	for _, line := range strings.Split(string(res.Stdout), "\n") {
		parts := strings.SplitN(line, "\t", 3)
		if len(parts) != 3 || parts[1] != "local" || parts[2] != base {
			continue
		}
		if parts[0] == "main" || parts[0] == "master" {
			trunk = append(trunk, parts[0])
		} else {
			feature = append(feature, parts[0])
		}
	}
	if len(trunk) == 1 {
		return trunk[0], nil
	}
	if len(trunk) > 1 || len(feature) > 1 {
		return "", fmt.Errorf("ambiguous publication bookmarks at %s: %s", base, strings.Join(append(trunk, feature...), ", "))
	}
	if len(feature) == 1 {
		return feature[0], nil
	}
	return "main", nil
}

func finalizePublicationBookmark(ctx context.Context, repo *vcs.Repo, name, commit string) error {
	if repo.Kind != vcs.KindJJ || name == "" {
		return nil
	}
	res, err := xshell.RunIn(ctx, repo.Root, "jj", "bookmark", "set", name, "-r", commit)
	if err != nil || res.Code != 0 {
		return fmt.Errorf("jj bookmark set %s -r %s failed", name, commit)
	}
	return nil
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
func emitCheckpointFailure(opts checkpointOpts, report recovery.Report, codes ...int) int {
	if opts.json {
		recovery.Emit(report, true)
	} else {
		recovery.Emit(report, false)
	}
	if len(codes) > 0 {
		return codes[0]
	}
	return 1
}

func emitGateFailure(opts checkpointOpts, output string, cause error) int {
	report, ok := parseRecoveryReport(output)
	if !ok {
		report = recovery.Report{
			Status:  "blocked",
			Code:    "recovery.protocol-invalid",
			Owner:   "user",
			Retry:   "terminal",
			Summary: "checkpoint gate returned an invalid recovery report",
			Details: []string{strings.TrimSpace(output), cause.Error()},
			Next:    "preserve the pending work and hand the gate output to the user",
		}
	}
	return emitCheckpointFailure(checkpointOpts{json: opts.json}, report, 1)
}
