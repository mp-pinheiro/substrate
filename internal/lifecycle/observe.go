package lifecycle

import (
	"context"
	"os"
	"path/filepath"

	"github.com/mp-pinheiro/substrate/internal/canonjson"
	"github.com/mp-pinheiro/substrate/internal/xshell"
)

func (e *Engine) Observe(ctx context.Context, payload []byte) Result {
	session, _ := sessionFromPayload(payload)
	statePath := e.statePath(session)
	current := e.snapshot(ctx)

	if _, err := os.Stat(statePath); err != nil {
		state := newLedger(session, e.paths.RepoRoot, current, "SessionStart ownership state missing")
		return e.writeLedgerResult(statePath, state)
	}

	state, err := readLedger(statePath)
	if err != nil {
		return Result{Code: 2}
	}

	observed := objObject(state, "observed")
	changed := computeChanged(objObject(observed, "entries"), current.Entries)
	beforeRevision := objString(observed, "revision")
	currentRevision := current.Revision

	if beforeRevision != currentRevision && e.maintenanceReconcileApplies(ctx, beforeRevision, currentRevision) {
		next := reconcileLedger(state, current, changed)
		next.Set("trackingError", nil)
		next.Set("driftNotice", nil)
		next.Set("stopBlocked", false)
		next.Set("completedCommit", current.Revision)
		return e.writeLedgerResult(statePath, next)
	}

	next := reconcileLedger(state, current, changed)
	if len(changed) > 0 {
		next.Set("stopBlocked", false)
		next.Set("completedCommit", nil)
	}
	next.Set("trackingError", nullable(current.Error))
	if beforeRevision != currentRevision {
		next.Set("driftNotice", "repository revision changed outside the checkpoint transaction; ownership re-baselined")
	}

	return e.writeLedgerResult(statePath, next)
}

func computeChanged(before, after *canonjson.Object) []string {
	seen := map[string]bool{}
	var all []string
	if before != nil {
		for _, k := range before.Keys() {
			if !seen[k] {
				seen[k] = true
				all = append(all, k)
			}
		}
	}
	if after != nil {
		for _, k := range after.Keys() {
			if !seen[k] {
				seen[k] = true
				all = append(all, k)
			}
		}
	}
	sorted := sortedUnique(all)
	var changed []string
	for _, k := range sorted {
		var bv, av canonjson.Value
		if before != nil {
			bv, _ = before.Get(k)
		}
		if after != nil {
			av, _ = after.Get(k)
		}
		if bv != av {
			changed = append(changed, k)
		}
	}
	return changed
}

// reconcileLedger ports the `reconcile` jq filter verbatim (agent-lifecycle.sh:140-145): rebaseline observed/initial against current, recompute ownedPaths.
func reconcileLedger(state *canonjson.Object, current *Snapshot, changed []string) *canonjson.Object {
	state.Set("observed", current.Doc())

	initial := objObject(state, "initial")
	initialEntries := objObject(initial, "entries")
	filtered := canonjson.NewObject()
	if initialEntries != nil {
		for _, k := range initialEntries.Keys() {
			if _, ok := current.Entries.Get(k); ok {
				v, _ := initialEntries.Get(k)
				filtered.Set(k, v)
			}
		}
	}
	initial.Set("entries", filtered)
	initial.Set("revision", current.Revision)

	owned := objStringArray(state, "ownedPaths")
	union := sortedUnique(append(append([]string(nil), owned...), changed...))
	var newOwned []string
	for _, p := range union {
		_, inCurrent := current.Entries.Get(p)
		_, inInit := filtered.Get(p)
		if inCurrent && !inInit {
			newOwned = append(newOwned, p)
		}
	}
	state.Set("ownedPaths", stringsToValues(newOwned))
	return state
}

func (e *Engine) maintenanceReconcileApplies(ctx context.Context, from, to string) bool {
	receiptPath := filepath.Join(e.stateDir, "..", "maintenance-receipt.json")
	if !e.maintenanceReceiptMatches(ctx, receiptPath) {
		return false
	}
	return e.receiptFieldsMatch(receiptPath, from, to)
}

// WHY: maintenance_repository_receipt_matches belongs to P4's
// internal/maintenance; call the vendored bash rather than forking a copy.
func (e *Engine) maintenanceReceiptMatches(ctx context.Context, receiptPath string) bool {
	script := `set -uo pipefail; . "$1/maintenance-lib.sh" || exit 1; maintenance_repository_receipt_matches "$2"`
	res, err := xshell.RunIn(ctx, e.paths.RepoRoot, "bash", "-c", script, "_", e.paths.SubstrateDir, receiptPath)
	if err != nil || res.Code != 0 {
		return false
	}
	return true
}

func (e *Engine) receiptFieldsMatch(receiptPath, from, to string) bool {
	raw, err := os.ReadFile(receiptPath)
	if err != nil {
		return false
	}
	val, err := canonjson.Unmarshal(raw)
	if err != nil {
		return false
	}
	obj, ok := val.(*canonjson.Object)
	if !ok {
		return false
	}
	op := stringEquals(obj, "operation", "init") ||
		stringEquals(obj, "operation", "bootstrap") ||
		stringEquals(obj, "operation", "update")
	if !op {
		return false
	}
	if !boolEquals(obj, "noPush", true) {
		return false
	}
	repository := objObject(obj, "repository")
	if repository == nil {
		return false
	}
	return stringEquals(repository, "status", "committed") &&
		stringEquals(repository, "fromRevision", from) &&
		stringEquals(repository, "toRevision", to) &&
		stringEquals(repository, "commit", to)
}
