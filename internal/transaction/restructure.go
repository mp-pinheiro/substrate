package transaction

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/mp-pinheiro/substrate/internal/logx"
	"github.com/mp-pinheiro/substrate/internal/vcs"
	"github.com/mp-pinheiro/substrate/internal/xshell"
)

// RunRestructure implements the restructure transaction (jj-only split/describe/squash).
func RunRestructure(ctx context.Context, args []string) int {
	opts, code := parseRestructureArgs(args)
	if code != 0 {
		return code
	}

	repoRoot, err := resolveRepoRoot()
	if err != nil {
		logx.Err().Line("restructure blocked: %v", err)
		return ExitPreflight
	}

	if _, err := os.Stat(filepath.Join(repoRoot, ".jj")); err != nil || !xshell.Have("jj") {
		logx.Err().Line("restructure blocked: requires a Jujutsu repository (`.jj` + `jj` on PATH)")
		return ExitPreflight
	}

	repo, err := DetectRepo(repoRoot)
	if err != nil {
		logx.Err().Line("restructure blocked: %v", err)
		return ExitPreflight
	}

	metadataDir, err := ResolveMetadataDir(ctx, repo)
	if err != nil {
		logx.Err().Line("restructure blocked: no repository metadata found")
		return ExitPreflight
	}

	targetChange := resolveChange(ctx, repo, opts.revision)
	if targetChange == "" {
		logx.Err().Line("restructure blocked: revision does not resolve to exactly one commit: %s", opts.revision)
		return ExitPreflight
	}

	var allowedChanges []string
	if opts.session != "" {
		stateDir := filepath.Join(metadataDir, "substrate", "agent-sessions")
		allowedChanges = readSessionChanges(stateDir, opts.session)
	} else {
		allowedChanges = opts.allowChanges
	}
	if len(allowedChanges) == 0 {
		logx.Err().Line("restructure blocked: no session-authored commits to restructure; checkpoint first")
		return ExitPreflight
	}
	if !isAllowedRestructure(targetChange, allowedChanges) {
		logx.Err().Line("restructure blocked: %s is not an agent session-authored commit", opts.revision)
		return ExitPreflight
	}

	lockPath := filepath.Join(metadataDir, "substrate-restructure.lock")
	if err := Lock(lockPath); err != nil {
		logx.Err().Line("restructure blocked: %v", err)
		return ExitPreflight
	}
	defer Unlock(lockPath)

	pendingBefore := sortedDiffNames(ctx, repo)
	tipBefore := jjTip(ctx, repo)
	opBefore := jjOpID(ctx, repo)
	if tipBefore == "" || opBefore == "" {
		logx.Err().Line("restructure blocked: cannot capture the current operation state")
		return ExitPreflight
	}

	if err := executeRestructure(ctx, repo, repoRoot, metadataDir, opts, targetChange, allowedChanges, pendingBefore, tipBefore, opBefore); err != nil {
		logx.Err().Line("restructure failed: %v; repository restored to operation %s", err, opBefore[:12])
		return 1
	}

	if opts.json {
		receiptJSON := readReceipt(metadataDir)
		logx.Out().Line("%s", receiptJSON)
	} else {
		logx.Out().Line("restructured: %s (%s)", targetChange, opts.op)
	}
	return 0
}

type restructureOpts struct {
	op           string
	revision     string
	into         string
	message      string
	message2     string
	session      string
	json         bool
	paths        []string
	allowChanges []string
}

func parseRestructureArgs(args []string) (restructureOpts, int) {
	var opts restructureOpts
	for i := 0; i < len(args); i++ {
		switch {
		case args[i] == "--op":
			i++; if i >= len(args) { rsUsage(); return opts, ExitPreflight }
			opts.op = args[i]
		case args[i] == "--revision":
			i++; if i >= len(args) { rsUsage(); return opts, ExitPreflight }
			opts.revision = args[i]
		case args[i] == "--into":
			i++; if i >= len(args) { rsUsage(); return opts, ExitPreflight }
			opts.into = args[i]
		case args[i] == "--message":
			i++; if i >= len(args) { rsUsage(); return opts, ExitPreflight }
			opts.message = args[i]
		case args[i] == "--message2":
			i++; if i >= len(args) { rsUsage(); return opts, ExitPreflight }
			opts.message2 = args[i]
		case args[i] == "--path":
			i++; if i >= len(args) { rsUsage(); return opts, ExitPreflight }
			opts.paths = append(opts.paths, args[i])
		case args[i] == "--session":
			i++; if i >= len(args) { rsUsage(); return opts, ExitPreflight }
			opts.session = args[i]
		case args[i] == "--allow-change":
			i++; if i >= len(args) { rsUsage(); return opts, ExitPreflight }
			opts.allowChanges = append(opts.allowChanges, args[i])
		case args[i] == "--json":
			opts.json = true
		default:
			rsUsage(); return opts, ExitPreflight
		}
	}
	switch opts.op {
	case "split", "describe", "squash":
	default:
		rsUsage(); return opts, ExitPreflight
	}
	if opts.revision == "" { rsUsage(); return opts, ExitPreflight }
	if opts.message != "" && !convCommitRe.MatchString(opts.message) {
		logx.Err().Line("restructure blocked: message must follow Conventional Commits — type(scope): subject")
		return opts, ExitPreflight
	}
	if opts.message2 != "" && !convCommitRe.MatchString(opts.message2) {
		logx.Err().Line("restructure blocked: --message2 must follow Conventional Commits")
		return opts, ExitPreflight
	}
	return opts, 0
}

func rsUsage() {
	logx.Err().Line("usage: substrate-engine restructure --op split|describe|squash --revision <rev> --message \"type(scope): subject\" [--message2 \"type(scope): subject\"] [--into <rev>] [--path <p> ...] (--session <id> | --allow-change <change-id> ...) [--json]")
}

func executeRestructure(ctx context.Context, repo *vcs.Repo, repoRoot, metadataDir string, opts restructureOpts, targetChange string, allowedChanges []string, pendingBefore, tipBefore, opBefore string) error {
	var newChanges []string

	switch opts.op {
	case "split":
		if len(opts.paths) == 0 {
			return fmt.Errorf("split requires --path")
		}
		childrenBefore, _ := childrenChanges(ctx, repo, targetChange)
		res, err := xshell.RunIn(ctx, repo.Root, "jj", append([]string{"split", "-r", targetChange, "-m", opts.message, "--"}, opts.paths...)...)
		if err != nil || res.Code != 0 {
			rollback(ctx, repo, opBefore)
			return fmt.Errorf("jj split rejected the transaction")
		}
		childrenAfter, _ := childrenChanges(ctx, repo, targetChange)
		remainder := setDifferenceSorted(childrenAfter, childrenBefore)
		if len(remainder) != 1 {
			rollback(ctx, repo, opBefore)
			return fmt.Errorf("could not identify the remainder commit")
		}
		if opts.message2 != "" {
			res, err := xshell.RunIn(ctx, repo.Root, "jj", "describe", "-r", remainder[0], "-m", opts.message2)
			if err != nil || res.Code != 0 {
				rollback(ctx, repo, opBefore)
				return fmt.Errorf("jj describe rejected the remainder message")
			}
		}
		newChanges = append(newChanges, remainder[0])

	case "describe":
		res, err := xshell.RunIn(ctx, repo.Root, "jj", "describe", "-r", targetChange, "-m", opts.message)
		if err != nil || res.Code != 0 {
			rollback(ctx, repo, opBefore)
			return fmt.Errorf("jj describe rejected the transaction")
		}

	case "squash":
		if opts.into == "" {
			return fmt.Errorf("squash requires --into")
		}
		destChange := resolveChange(ctx, repo, opts.into)
		if destChange == "" {
			return fmt.Errorf("--into does not resolve to exactly one commit: %s", opts.into)
		}
		if !isAllowedRestructure(destChange, allowedChanges) {
			return fmt.Errorf("%s is not an agent session-authored commit", opts.into)
		}
		if destChange == targetChange {
			return fmt.Errorf("squash source and destination are the same commit")
		}
		res, err := xshell.RunIn(ctx, repo.Root, "jj", "squash", "--from", targetChange, "--into", destChange, "-m", opts.message)
		if err != nil || res.Code != 0 {
			rollback(ctx, repo, opBefore)
			return fmt.Errorf("jj squash rejected the transaction")
		}
	}

	if hasConflicts, _ := jjHasConflicts(ctx, repo); hasConflicts {
		return fmt.Errorf("the operation produced conflicts")
	}
	pendingAfter := sortedDiffNames(ctx, repo)
	if pendingBefore != pendingAfter {
		return fmt.Errorf("pending working-copy paths changed")
	}
	if changed, _ := jjDiffRange(ctx, repo, tipBefore, "@"); changed != "" {
		return fmt.Errorf("the working-copy tree changed")
	}

	newRevision := jjTip(ctx, repo)
	targetCommit := resolveCommitID(ctx, repo, targetChange)
	if targetCommit == "" {
		targetCommit = "abandoned"
	}

	now := time.Now().UTC().Format("2006-01-02T15:04:05Z")
	newJSON := "[]"
	if len(newChanges) > 0 {
		data, _ := json.Marshal(newChanges)
		newJSON = string(data)
	}
	receipt := fmt.Sprintf(
		`{"operation":"restructure","op":"%s","changeId":"%s","commit":"%s","newChangeIds":%s,"revision":"%s","fromOperation":"%s","vcs":"jj","noPush":true,"at":"%s","status":"restructured"}`,
		opts.op, targetChange, targetCommit, newJSON, newRevision, opBefore, now,
	)

	receiptDir := filepath.Join(metadataDir, "substrate")
	_ = os.MkdirAll(receiptDir, 0755)
	receiptPath := filepath.Join(receiptDir, "restructure-receipt.json")
	if err := xshell.WriteFileAtomicPreservingMode(receiptPath, []byte(receipt+"\n"), 0600); err != nil {
		return fmt.Errorf("restructure incomplete: receipt write failed")
	}

	if opts.session != "" {
		stateDir := filepath.Join(metadataDir, "substrate", "agent-sessions")
		_ = updateSessionAfterRestructure(stateDir, repo, opts.session, newRevision, newChanges)
	}

	return nil
}

func rollback(ctx context.Context, repo *vcs.Repo, opBefore string) {
	_, _ = xshell.RunIn(ctx, repo.Root, "jj", "op", "restore", opBefore)
}

func resolveChange(ctx context.Context, repo *vcs.Repo, rev string) string {
	res, err := xshell.RunIn(ctx, repo.Root, "jj", "log", "-r", rev, "--no-graph", "-T", "change_id ++ \"\\n\"")
	if err != nil || res.Code != 0 {
		return ""
	}
	lines := splitNonEmpty(string(res.Stdout))
	if len(lines) != 1 {
		return ""
	}
	return lines[0]
}

func isAllowedRestructure(change string, allowed []string) bool {
	for _, a := range allowed {
		if a == change {
			return true
		}
	}
	return false
}

func childrenChanges(ctx context.Context, repo *vcs.Repo, change string) ([]string, error) {
	res, err := xshell.RunInC(ctx, repo.Root, "jj", "log", "-r", "children("+change+")", "--no-graph", "-T", "change_id ++ \"\\n\"")
	if err != nil || res.Code != 0 {
		return nil, fmt.Errorf("restructure: children: %w", err)
	}
	return splitNonEmpty(string(res.Stdout)), nil
}

func sortedDiffNames(ctx context.Context, repo *vcs.Repo) string {
	res, err := xshell.RunInC(ctx, repo.Root, "jj", "diff", "--name-only")
	if err != nil || res.Code != 0 {
		return ""
	}
	return strings.TrimSpace(string(res.Stdout))
}

func jjTip(ctx context.Context, repo *vcs.Repo) string {
	res, err := xshell.RunIn(ctx, repo.Root, "jj", "log", "-r", "@", "--no-graph", "-T", "commit_id")
	if err != nil || res.Code != 0 {
		return ""
	}
	return strings.TrimSpace(string(res.Stdout))
}

func jjOpID(ctx context.Context, repo *vcs.Repo) string {
	res, err := xshell.RunIn(ctx, repo.Root, "jj", "op", "log", "-n", "1", "--no-graph", "-T", "id.short(64)")
	if err != nil || res.Code != 0 {
		return ""
	}
	return strings.TrimSpace(string(res.Stdout))
}

func jjHasConflicts(ctx context.Context, repo *vcs.Repo) (bool, error) {
	res, err := xshell.RunIn(ctx, repo.Root, "jj", "log", "-r", "conflicts()", "--no-graph", "-T", "change_id ++ \"\\n\"")
	if err != nil || res.Code != 0 {
		return true, fmt.Errorf("restructure: conflicts: %w", err)
	}
	return strings.TrimSpace(string(res.Stdout)) != "", nil
}

func jjDiffRange(ctx context.Context, repo *vcs.Repo, from, to string) (string, error) {
	res, err := xshell.RunIn(ctx, repo.Root, "jj", "diff", "--from", from, "--to", to, "--name-only")
	if err != nil || res.Code != 0 {
		return "", fmt.Errorf("restructure: diff range: %w", err)
	}
	return strings.TrimSpace(string(res.Stdout)), nil
}

func resolveCommitID(ctx context.Context, repo *vcs.Repo, change string) string {
	res, err := xshell.RunIn(ctx, repo.Root, "jj", "log", "-r", change, "--no-graph", "-T", "commit_id")
	if err != nil || res.Code != 0 {
		return ""
	}
	return strings.TrimSpace(string(res.Stdout))
}

func setDifferenceSorted(a, b []string) []string {
	set := make(map[string]bool, len(a))
	for _, s := range a {
		set[s] = true
	}
	var out []string
	for _, s := range b {
		if !set[s] {
			out = append(out, s)
		}
	}
	sort.Strings(out)
	return out
}

func splitNonEmpty(raw string) []string {
	var out []string
	for _, l := range strings.Split(raw, "\n") {
		l = strings.TrimSpace(l)
		if l != "" {
			out = append(out, l)
		}
	}
	return out
}

func readSessionChanges(stateDir, session string) []string {
	data, err := os.ReadFile(filepath.Join(stateDir, session+".json"))
	if err != nil {
		return nil
	}
	var state struct {
		SessionChanges []string `json:"sessionChanges"`
	}
	_ = json.Unmarshal(data, &state)
	return state.SessionChanges
}

func updateSessionAfterRestructure(stateDir string, repo *vcs.Repo, session, newRevision string, newChangeIDs []string) error {
	statePath := filepath.Join(stateDir, session+".json")
	data, err := os.ReadFile(statePath)
	if err != nil {
		return fmt.Errorf("restructure: read state: %w", err)
	}
	var state map[string]interface{}
	if err := json.Unmarshal(data, &state); err != nil {
		return fmt.Errorf("restructure: unmarshal state: %w", err)
	}
	state["completedCommit"] = newRevision
	if observed, ok := state["observed"].(map[string]interface{}); ok {
		observed["revision"] = newRevision
	}
	if initial, ok := state["initial"].(map[string]interface{}); ok {
		initial["revision"] = newRevision
	}
	existing := make(map[string]bool)
	if sc, ok := state["sessionChanges"].([]interface{}); ok {
		for _, c := range sc {
			if s, ok := c.(string); ok {
				existing[s] = true
			}
		}
	}
	for _, c := range newChangeIDs {
		existing[c] = true
	}
	var merged []string
	for c := range existing {
		merged = append(merged, c)
	}
	sort.Strings(merged)
	state["sessionChanges"] = merged
	newData, _ := json.Marshal(state)
	newData = append(newData, '\n')
	if err := xshell.WriteFileAtomicPreservingMode(statePath, newData, 0600); err != nil {
		return fmt.Errorf("restructure: write state: %w", err)
	}
	return nil
}

func readReceipt(metadataDir string) string {
	path := filepath.Join(metadataDir, "substrate", "restructure-receipt.json")
	data, err := os.ReadFile(path)
	if err != nil {
		return "{}"
	}
	return strings.TrimSpace(string(data))
}
