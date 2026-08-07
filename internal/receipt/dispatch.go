package receipt

import (
	"context"
	"fmt"
	"os"

	"github.com/mp-pinheiro/substrate/internal/logx"
)

// resolveRepoRoot falls back to the cwd because receipt's bash callers cd to $REPO_ROOT first.
func resolveRepoRoot() (string, error) {
	if root := os.Getenv("REPO_ROOT"); root != "" {
		return root, nil
	}
	cwd, err := os.Getwd()
	if err != nil {
		return "", fmt.Errorf("receipt: getwd: %w", err)
	}
	return cwd, nil
}

// Dispatch routes one `receipt <verb>` invocation (binding B2). It never
// returns 2 — that exit code is reserved for main.go's unknown top-level verb.
func Dispatch(ctx context.Context, args []string) int {
	if len(args) == 0 {
		return 1
	}
	switch args[0] {
	case "fingerprint":
		return dispatchFingerprint(ctx)
	case "matches":
		return dispatchMatches(ctx)
	case "write":
		return dispatchWrite(ctx, args[1:])
	default:
		return 1
	}
}

func dispatchFingerprint(ctx context.Context) int {
	repoRoot, err := resolveRepoRoot()
	if err != nil {
		return 1
	}
	state, err := BuildState(ctx, repoRoot)
	if err != nil {
		return 1
	}
	fp, err := Fingerprint(state)
	if err != nil {
		return 1
	}
	logx.Out().Line("%s", fp)
	return 0
}

func dispatchMatches(ctx context.Context) int {
	repoRoot, err := resolveRepoRoot()
	if err != nil {
		return 1
	}
	ok, err := Matches(ctx, repoRoot)
	if err != nil || !ok {
		return 1
	}
	return 0
}

func dispatchWrite(ctx context.Context, args []string) int {
	if len(args) < 3 {
		return 1
	}
	source, commit, vcsName := args[0], args[1], args[2]
	session := ""
	if len(args) > 3 {
		session = args[3]
	}
	repoRoot, err := resolveRepoRoot()
	if err != nil {
		return 1
	}
	receiptJSON, err := Write(ctx, repoRoot, source, commit, vcsName, session)
	if err != nil {
		return 1
	}
	logx.Out().Line("%s", receiptJSON)
	return 0
}
