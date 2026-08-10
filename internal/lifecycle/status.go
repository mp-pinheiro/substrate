package lifecycle

import (
	"context"
	"os"

	"github.com/mp-pinheiro/substrate/internal/canonjson"
)

// Status is the read-only ownership query backing the omp extension's shim over
// the engine: it returns the ledger's ownership view plus a fresh snapshot so a
// non-Claude harness can decide whether to checkpoint without spawning a full
// gate. Unlike Verify it never gates — a tracking error or fingerprint drift is
// reported as data, not an exit-2 refusal.
func (e *Engine) Status(ctx context.Context, session string) Result {
	statePath := e.statePath(session)
	if _, err := os.Stat(statePath); err != nil {
		return Result{Stderr: []byte("substrate lifecycle: no ownership state for session " + session + "\n"), Code: 2}
	}
	state, err := readLedger(statePath)
	if err != nil {
		return Result{Code: 2}
	}

	current := e.snapshot(ctx)
	owned := objStringArray(state, "ownedPaths")
	pending := intersectPreserveOrder(current.Entries.Keys(), owned)
	observed := objObject(state, "observed")

	doc := canonjson.NewObject().
		Set("session", session).
		Set("repoRoot", objString(state, "repoRoot")).
		Set("ownedPaths", stringsToValues(owned)).
		Set("dirtyPaths", stringsToValues(current.Entries.Keys())).
		Set("pendingOwned", stringsToValues(pending)).
		Set("trackingError", nullable(objString(state, "trackingError"))).
		Set("driftNotice", nullable(objString(state, "driftNotice"))).
		Set("revision", current.Revision).
		Set("fingerprint", current.Fingerprint).
		Set("observedFingerprint", objString(observed, "fingerprint")).
		Set("stale", current.Fingerprint != "" && current.Fingerprint != objString(observed, "fingerprint")).
		Set("error", nullable(current.Error))
	out, err := marshalLine(doc)
	if err != nil {
		return Result{Code: 2}
	}
	return Result{Stdout: out, Code: 0}
}
