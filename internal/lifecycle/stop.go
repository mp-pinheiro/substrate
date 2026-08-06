package lifecycle

import (
	"context"
	"fmt"
	"strings"

	"github.com/mp-pinheiro/substrate/internal/canonjson"
)

// stopDecision is the pure projection of the batched jq computation at
// agent-lifecycle.sh:233-262 plus its derived-value overrides — no disk/subprocess I/O, so the whole matrix is table-testable.
type stopDecision struct {
	Pending           []string
	Unowned           []string
	RevisionBypass    bool
	Tracking          string
	CurrentError      string
	AttemptCheckpoint bool
	CleanExit         bool
	StopActive        bool
	AlreadyBlocked    bool
}

func evaluateStop(state *canonjson.Object, current *Snapshot, stopActive bool) stopDecision {
	paths := current.Entries.Keys()
	owned := objStringArray(state, "ownedPaths")
	pending := intersectPreserveOrder(paths, owned)
	unowned := subtractPreserveOrder(paths, owned)

	completed := objString(state, "completedCommit")
	initialRevision := objString(objObject(state, "initial"), "revision")
	tracking := objString(state, "trackingError")
	currentError := current.Error
	fingerprintChanged := current.Fingerprint != objString(objObject(state, "observed"), "fingerprint")

	revisionBypass := current.Revision != initialRevision && current.Revision != completed

	if len(owned) > 0 && fingerprintChanged {
		tracking = "working copy changed outside an observed Claude tool call"
	}
	if tracking != "" && len(paths) == 0 {
		tracking = ""
	}

	return stopDecision{
		Pending:           pending,
		Unowned:           unowned,
		RevisionBypass:    revisionBypass,
		Tracking:          tracking,
		CurrentError:      currentError,
		AttemptCheckpoint: len(pending) > 0 && tracking == "" && currentError == "" && !stopActive,
		CleanExit:         len(pending) == 0 && !revisionBypass && tracking == "" && currentError == "",
		StopActive:        stopActive,
		AlreadyBlocked:    objBool(state, "stopBlocked", false),
	}
}

func (d stopDecision) reasonText(session, autoNote string) string {
	reason := "[substrate \u2014 completion blocked]"
	if len(d.Pending) > 0 {
		reason += fmt.Sprintf(" Agent-owned pending paths: %s.", strings.Join(d.Pending, ", "))
	}
	if len(d.Unowned) > 0 {
		reason += fmt.Sprintf(" Unowned pending paths: %s.", strings.Join(d.Unowned, ", "))
	}
	if d.RevisionBypass {
		reason += " Repository revision changed without a checkpoint receipt."
	}
	if d.Tracking != "" {
		reason += fmt.Sprintf(" Ownership error: %s.", d.Tracking)
	}
	if d.CurrentError != "" {
		reason += fmt.Sprintf(" Inspection error: %s.", d.CurrentError)
	}
	reason += autoNote
	reason += fmt.Sprintf(
		" Run direct verification, then: substrate checkpoint --session %s --message 'type(scope): subject'. Never push.",
		session)
	return reason
}

func (e *Engine) Stop(ctx context.Context, payload []byte) Result {
	session, _ := sessionFromPayload(payload)
	statePath := e.statePath(session)
	state, present, err := e.loadLedgerOrBail(statePath)
	if !present {
		return Result{Code: 0}
	}
	if err != nil {
		return Result{Code: 2}
	}
	current := e.snapshot(ctx)
	decision := evaluateStop(state, current, stopHookActive(payload))

	autoNote := ""
	if decision.AttemptCheckpoint {
		out, code, runErr := e.runAutoCheckpoint(ctx, session)
		if runErr != nil {
			out, code = runErr.Error(), -1
		}
		last := lastLine(out)
		if code == 0 {
			commit := commitFieldOf(last)
			if commit == "" {
				commit = "unknown"
			}
			msg := fmt.Sprintf("Substrate auto-checkpoint %s committed agent-owned work. No push performed.", commit)
			doc := canonjson.NewObject().Set("systemMessage", msg)
			body, err := marshalLine(doc)
			if err != nil {
				return Result{Code: 2}
			}
			return Result{Stdout: body, Code: 0}
		}
		autoNote = fmt.Sprintf(" Automatic checkpoint failed: %s.", last)
	}

	if decision.CleanExit {
		return Result{Code: 0}
	}

	reason := decision.reasonText(session, autoNote)

	if decision.StopActive || decision.AlreadyBlocked {
		doc := canonjson.NewObject().Set("systemMessage", reason)
		body, err := marshalLine(doc)
		if err != nil {
			return Result{Code: 2}
		}
		return Result{Stdout: body, Code: 0}
	}

	state.Set("stopBlocked", true)
	if err := e.writeLedger(statePath, state); err != nil {
		return Result{Code: 2}
	}
	doc := canonjson.NewObject().Set("decision", "block").Set("reason", reason)
	body, err := marshalLine(doc)
	if err != nil {
		return Result{Code: 2}
	}
	return Result{Stderr: body, Code: 2}
}

func stopHookActive(payload []byte) bool {
	val, err := canonjson.Unmarshal(payload)
	if err != nil {
		return false
	}
	obj, ok := val.(*canonjson.Object)
	if !ok {
		return false
	}
	v, ok := obj.Get("stop_hook_active")
	if !ok {
		return false
	}
	switch t := v.(type) {
	case bool:
		return t
	case string:
		return t == "true"
	default:
		return false
	}
}
