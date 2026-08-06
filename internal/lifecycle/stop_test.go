package lifecycle

import (
	"testing"

	"github.com/mp-pinheiro/substrate/internal/canonjson"
)

func ledgerFixture(t *testing.T, initialRevision, observedFingerprint, completedCommit, trackingError string, ownedPaths []string, stopBlocked bool) *canonjson.Object {
	t.Helper()
	return canonjson.NewObject().
		Set("session", "sess-1").
		Set("repoRoot", "/repo").
		Set("initial", canonjson.NewObject().Set("revision", initialRevision)).
		Set("observed", canonjson.NewObject().Set("fingerprint", observedFingerprint)).
		Set("ownedPaths", stringsToValues(ownedPaths)).
		Set("trackingError", nullable(trackingError)).
		Set("stopBlocked", stopBlocked).
		Set("completedCommit", nullable(completedCommit))
}

func snapshotFixture(revision, fp, errText string, entries map[string]string) *Snapshot {
	obj := canonjson.NewObject()
	for k, v := range entries {
		obj.Set(k, v)
	}
	return &Snapshot{Revision: revision, Entries: obj, Fingerprint: fp, Error: errText}
}

func TestEvaluateStopDecisionMatrix(t *testing.T) {
	cases := []struct {
		name             string
		ledger           *canonjson.Object
		current          *Snapshot
		stopActive       bool
		wantPending      []string
		wantUnowned      []string
		wantBypass       bool
		wantTracking     string
		wantCurrentError string
		wantAttempt      bool
		wantClean        bool
	}{
		{
			name:       "clean tree",
			ledger:     ledgerFixture(t, "rev1", "fp1", "", "", nil, false),
			current:    snapshotFixture("rev1", "fp1", "", nil),
			wantClean:  true,
			wantBypass: false,
		},
		{
			name:        "owned pending triggers checkpoint attempt",
			ledger:      ledgerFixture(t, "rev1", "fp1", "", "", []string{"a.txt"}, false),
			current:     snapshotFixture("rev1", "fp1", "", map[string]string{"a.txt": "file:aa"}),
			wantPending: []string{"a.txt"},
			wantAttempt: true,
			wantClean:   false,
		},
		{
			name:        "unowned pending alone still clean exits",
			ledger:      ledgerFixture(t, "rev1", "fp1", "", "", nil, false),
			current:     snapshotFixture("rev1", "fp1", "", map[string]string{"b.txt": "file:bb"}),
			wantUnowned: []string{"b.txt"},
			wantClean:   true,
		},
		{
			name:       "revision bypass blocks even with no pending",
			ledger:     ledgerFixture(t, "rev1", "fp1", "", "", nil, false),
			current:    snapshotFixture("rev2", "fp1", "", nil),
			wantBypass: true,
			wantClean:  false,
		},
		{
			name:       "revision change covered by completed commit is not a bypass",
			ledger:     ledgerFixture(t, "rev1", "fp1", "rev2", "", nil, false),
			current:    snapshotFixture("rev2", "fp1", "", nil),
			wantBypass: false,
			wantClean:  true,
		},
		{
			name:         "tracking error blocks and suppresses checkpoint attempt",
			ledger:       ledgerFixture(t, "rev1", "fp1", "", "state went stale", []string{"a.txt"}, false),
			current:      snapshotFixture("rev1", "fp1", "", map[string]string{"a.txt": "file:aa"}),
			wantPending:  []string{"a.txt"},
			wantTracking: "state went stale",
			wantAttempt:  false,
			wantClean:    false,
		},
		{
			name:             "inspection error blocks and suppresses checkpoint attempt",
			ledger:           ledgerFixture(t, "rev1", "fp1", "", "", []string{"a.txt"}, false),
			current:          snapshotFixture("rev1", "fp1", "unsafe changed path: /etc/passwd", map[string]string{"a.txt": "file:aa"}),
			wantPending:      []string{"a.txt"},
			wantCurrentError: "unsafe changed path: /etc/passwd",
			wantAttempt:      false,
			wantClean:        false,
		},
		{
			name:         "fingerprint drift overrides tracking error even when previously clean",
			ledger:       ledgerFixture(t, "rev1", "fp-old", "", "", []string{"a.txt"}, false),
			current:      snapshotFixture("rev1", "fp-new", "", map[string]string{"a.txt": "file:aa"}),
			wantPending:  []string{"a.txt"},
			wantTracking: "working copy changed outside an observed Claude tool call",
			wantAttempt:  false,
			wantClean:    false,
		},
		{
			name:      "tracking error suppressed when working copy has no entries",
			ledger:    ledgerFixture(t, "rev1", "fp-old", "", "stale tracking", []string{"a.txt"}, false),
			current:   snapshotFixture("rev1", "fp-old", "", nil),
			wantClean: true,
		},
		{
			name:        "stop_hook_active suppresses the checkpoint attempt but not the pending block",
			ledger:      ledgerFixture(t, "rev1", "fp1", "", "", []string{"a.txt"}, false),
			current:     snapshotFixture("rev1", "fp1", "", map[string]string{"a.txt": "file:aa"}),
			stopActive:  true,
			wantPending: []string{"a.txt"},
			wantAttempt: false,
			wantClean:   false,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			d := evaluateStop(tc.ledger, tc.current, tc.stopActive)
			if !stringSliceEqual(d.Pending, tc.wantPending) {
				t.Errorf("Pending = %v, want %v", d.Pending, tc.wantPending)
			}
			if !stringSliceEqual(d.Unowned, tc.wantUnowned) {
				t.Errorf("Unowned = %v, want %v", d.Unowned, tc.wantUnowned)
			}
			if d.RevisionBypass != tc.wantBypass {
				t.Errorf("RevisionBypass = %v, want %v", d.RevisionBypass, tc.wantBypass)
			}
			if d.Tracking != tc.wantTracking {
				t.Errorf("Tracking = %q, want %q", d.Tracking, tc.wantTracking)
			}
			if d.CurrentError != tc.wantCurrentError {
				t.Errorf("CurrentError = %q, want %q", d.CurrentError, tc.wantCurrentError)
			}
			if d.AttemptCheckpoint != tc.wantAttempt {
				t.Errorf("AttemptCheckpoint = %v, want %v", d.AttemptCheckpoint, tc.wantAttempt)
			}
			if d.CleanExit != tc.wantClean {
				t.Errorf("CleanExit = %v, want %v", d.CleanExit, tc.wantClean)
			}
		})
	}
}

func TestEvaluateStopReentrancy(t *testing.T) {
	ledger := ledgerFixture(t, "rev1", "fp1", "", "", []string{"a.txt"}, true)
	current := snapshotFixture("rev1", "fp1", "", map[string]string{"a.txt": "file:aa"})

	d := evaluateStop(ledger, current, false)
	if !d.AlreadyBlocked {
		t.Fatal("AlreadyBlocked should be true when the ledger already carries stopBlocked")
	}

	d2 := evaluateStop(ledgerFixture(t, "rev1", "fp1", "", "", []string{"a.txt"}, false), current, true)
	if !d2.StopActive {
		t.Fatal("StopActive should reflect the payload's stop_hook_active flag")
	}
}

func TestReasonTextOrdering(t *testing.T) {
	d := stopDecision{
		Pending:        []string{"a.txt", "b.txt"},
		Unowned:        []string{"c.txt"},
		RevisionBypass: true,
		Tracking:       "tracking failed",
		CurrentError:   "inspection failed",
	}
	got := d.reasonText("sess-1", " Automatic checkpoint failed: boom.")
	want := "[substrate \u2014 completion blocked] Agent-owned pending paths: a.txt, b.txt." +
		" Unowned pending paths: c.txt." +
		" Repository revision changed without a checkpoint receipt." +
		" Ownership error: tracking failed." +
		" Inspection error: inspection failed." +
		" Automatic checkpoint failed: boom." +
		" Run direct verification, then: substrate checkpoint --session sess-1 --message 'type(scope): subject'. Never push."
	if got != want {
		t.Fatalf("reasonText() =\n%q\nwant\n%q", got, want)
	}
}

func stringSliceEqual(a, b []string) bool {
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
