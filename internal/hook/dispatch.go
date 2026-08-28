// Package hook adapts the ported bash hooks to the engine: payload parsing,
// env resolution, per-hook routing, and stdout/stderr/exit rendering.
package hook

import (
	"context"
	"fmt"
	"io"
	"os"

	"github.com/mp-pinheiro/substrate/internal/config"
	"github.com/mp-pinheiro/substrate/internal/vcs"
)

// EngineVersion namespaces the changed-files-scan memo (amendment A7); main
// sets it once from the build-time version before any Dispatch call.
var EngineVersion = "unknown"

type env struct {
	repoRoot     string
	substrateDir string
}

// resolveEnv mirrors every hook's own HOOK_DIR/SUBSTRATE_DIR/REPO_ROOT
// derivation: the bash shim exports both before exec'ing the engine.
func resolveEnv() env {
	repoRoot := os.Getenv("REPO_ROOT")
	substrateDir := os.Getenv("SUBSTRATE_DIR")
	if repoRoot == "" {
		repoRoot, _ = os.Getwd()
	}
	if substrateDir == "" {
		substrateDir = repoRoot + "/.substrate"
	}
	return env{repoRoot: repoRoot, substrateDir: substrateDir}
}

func (e env) paths() config.Paths {
	p, err := config.DiscoverFromSubstrateDir(e.substrateDir)
	if err != nil {
		return config.Paths{
			RepoRoot:     e.repoRoot,
			SubstrateDir: e.substrateDir,
			ConfigPath:   e.repoRoot + "/substrate.json",
			LangMapPath:  e.substrateDir + "/langmap.json",
			BaselinePath: e.repoRoot + "/substrate-baseline.json",
		}
	}
	return p
}

func (e env) repo() (*vcs.Repo, error) {
	repo, err := vcs.Detect(e.repoRoot)
	if err != nil {
		return nil, fmt.Errorf("hook: detect vcs: %w", err)
	}
	return repo, nil
}

// Dispatch routes one hook invocation to its handler and renders the result.
func Dispatch(ctx context.Context, name string, args []string, stdin io.Reader) int {
	e := resolveEnv()
	switch name {
	case "agent-lifecycle":
		return dispatchLifecycle(ctx, e, args, stdin)
	case "protect-paths":
		return dispatchProtectPaths(e, stdin)
	// check-hard is internal-only: the OMP stop hook uses it to distinguish
	// permanent name-governed paths from fixable protect-paths failures.
	case "check-hard":
		return dispatchCheckHard(stdin)
	case "protect-command":
		return dispatchProtectCommand(e, stdin)
	case "enforce-jj":
		return dispatchEnforceJJ(e, stdin)
	case "enforce-conventional-commits":
		return dispatchEnforceConventionalCommits(e, stdin)
	case "gate-before-push":
		return dispatchGateBeforePush(ctx, e, stdin)
	case "changed-files-scan":
		return dispatchChangedFilesScan(ctx, e, stdin)
	case "comment-ratchet":
		return dispatchCommentRatchet(ctx, e, args)
	default:
		return 2
	}
}
