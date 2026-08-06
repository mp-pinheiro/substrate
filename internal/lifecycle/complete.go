package lifecycle

import (
	"context"

	"github.com/mp-pinheiro/substrate/internal/canonjson"
	"github.com/mp-pinheiro/substrate/internal/vcs"
)

func (e *Engine) Complete(ctx context.Context, session, commit string) Result {
	statePath := e.statePath(session)
	state, present, err := e.loadLedgerOrBail(statePath)
	if !present {
		return Result{Code: 0}
	}
	if err != nil {
		return Result{Code: 2}
	}

	current := e.snapshot(ctx)
	pending := intersectPreserveOrder(current.Entries.Keys(), objStringArray(state, "ownedPaths"))
	if len(pending) != 0 {
		return Result{Stderr: []byte("substrate lifecycle: checkpoint left owned paths pending\n"), Code: 2}
	}
	if current.Revision != commit {
		return Result{Stderr: []byte("substrate lifecycle: checkpoint receipt does not match repository revision\n"), Code: 2}
	}

	next := state
	next.Set("observed", current.Doc())
	next.Set("initial", current.Doc())
	next.Set("ownedPaths", []canonjson.Value{})
	next.Set("trackingError", nil)
	next.Set("driftNotice", nil)
	next.Set("stopBlocked", false)
	next.Set("completedCommit", commit)

	if e.repo.Kind == vcs.KindJJ {
		change, _ := e.repo.ChangeIDFor(ctx, commit)
		if change != "" {
			existing := objStringArray(next, "sessionChanges")
			union := sortedUnique(append(append([]string(nil), existing...), change))
			next.Set("sessionChanges", stringsToValues(union))
		}
	}

	return e.writeLedgerResult(statePath, next)
}
