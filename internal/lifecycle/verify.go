package lifecycle

import (
	"context"
	"fmt"
	"os"

	"github.com/mp-pinheiro/substrate/internal/canonjson"
)

func (e *Engine) Verify(ctx context.Context, session string) Result {
	statePath := e.statePath(session)
	if _, err := os.Stat(statePath); err != nil {
		return Result{Stderr: []byte("checkpoint blocked: agent ownership state is missing\n"), Code: 2}
	}
	state, err := readLedger(statePath)
	if err != nil {
		return Result{Code: 2}
	}

	if objString(state, "repoRoot") != e.paths.RepoRoot {
		return Result{Stderr: []byte("checkpoint blocked: ownership state belongs to another repository\n"), Code: 2}
	}

	if trackingError := objString(state, "trackingError"); trackingError != "" {
		return Result{Stderr: []byte(fmt.Sprintf("checkpoint blocked: %s\n", trackingError)), Code: 2}
	}

	current := e.snapshot(ctx)
	if current.Error != "" {
		return Result{Stderr: []byte("checkpoint blocked: working-copy inspection failed\n"), Code: 2}
	}

	observed := objObject(state, "observed")
	if current.Fingerprint != objString(observed, "fingerprint") {
		return Result{Stderr: []byte("checkpoint blocked: working copy changed outside an observed agent tool call\n"), Code: 2}
	}

	pending := intersectPreserveOrder(current.Entries.Keys(), objStringArray(state, "ownedPaths"))
	if len(pending) == 0 {
		return Result{Stderr: []byte("checkpoint blocked: no pending agent-owned changes; if the work is in another governed repo, commit it there: (cd <repo> && ./bin/substrate checkpoint --message <msg> --path <path>)\n"), Code: 2}
	}

	doc := canonjson.NewObject().Set("paths", stringsToValues(pending)).Set("fingerprint", current.Fingerprint)
	out, err := marshalLine(doc)
	if err != nil {
		return Result{Code: 2}
	}
	return Result{Stdout: out, Code: 0}
}
