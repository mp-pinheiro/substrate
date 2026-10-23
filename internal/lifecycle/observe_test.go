package lifecycle

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/mp-pinheiro/substrate/internal/canonjson"
	"github.com/mp-pinheiro/substrate/internal/config"
	"github.com/mp-pinheiro/substrate/internal/vcs"
)

func entriesObj(m map[string]string) *canonjson.Object {
	o := canonjson.NewObject()
	for k, v := range m {
		o.Set(k, v)
	}
	return o
}

func TestComputeChanged(t *testing.T) {
	cases := []struct {
		name   string
		before map[string]string
		after  map[string]string
		want   []string
	}{
		{
			name:   "no change",
			before: map[string]string{"a.txt": "file:1"},
			after:  map[string]string{"a.txt": "file:1"},
			want:   nil,
		},
		{
			name:   "value changed",
			before: map[string]string{"a.txt": "file:1"},
			after:  map[string]string{"a.txt": "file:2"},
			want:   []string{"a.txt"},
		},
		{
			name:   "new key appears",
			before: map[string]string{"a.txt": "file:1"},
			after:  map[string]string{"a.txt": "file:1", "b.txt": "file:2"},
			want:   []string{"b.txt"},
		},
		{
			name:   "key disappears (reverts to deleted state)",
			before: map[string]string{"a.txt": "file:1", "b.txt": "file:2"},
			after:  map[string]string{"a.txt": "file:1"},
			want:   []string{"b.txt"},
		},
		{
			name:   "sorted union order regardless of input order",
			before: map[string]string{"z.txt": "file:1"},
			after:  map[string]string{"a.txt": "file:2"},
			want:   []string{"a.txt", "z.txt"},
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := computeChanged(entriesObj(tc.before), entriesObj(tc.after))
			if !stringSliceEqual(got, tc.want) {
				t.Errorf("computeChanged() = %v, want %v", got, tc.want)
			}
		})
	}
}

func TestReconcileLedgerOwnedPathsUnionAndInitialIntersection(t *testing.T) {
	state := canonjson.NewObject().
		Set("session", "sess-1").
		Set("initial", canonjson.NewObject().
			Set("revision", "rev1").
			Set("entries", entriesObj(map[string]string{
				"baseline.txt":       "file:base",
				"gone.txt":           "file:gone",
				"baseline-owned.txt": "file:baseowned",
			}))).
		Set("observed", canonjson.NewObject()).
		Set("ownedPaths", stringsToValues([]string{"already-owned.txt", "baseline-owned.txt"}))

	current := &Snapshot{
		Revision: "rev2",
		Entries: entriesObj(map[string]string{
			"baseline.txt":       "file:base",
			"already-owned.txt":  "file:owned",
			"newly-changed.txt":  "file:new",
			"baseline-owned.txt": "file:baseowned2",
		}),
		Fingerprint: "fp2",
	}
	changed := []string{"already-owned.txt", "newly-changed.txt", "baseline-owned.txt"}

	next := reconcileLedger(state, current, changed)

	initial := objObject(next, "initial")
	if initial == nil {
		t.Fatal("initial missing after reconcile")
	}
	if got := objString(initial, "revision"); got != "rev2" {
		t.Errorf("initial.revision = %q, want rev2", got)
	}
	filtered := objObject(initial, "entries")
	if filtered == nil || filtered.Len() != 2 {
		t.Fatalf("initial.entries after filter = %#v, want baseline.txt and baseline-owned.txt", filtered)
	}
	if _, ok := filtered.Get("baseline.txt"); !ok {
		t.Error("initial.entries should keep baseline.txt (still present in current)")
	}
	if _, ok := filtered.Get("gone.txt"); ok {
		t.Error("initial.entries should drop gone.txt (absent from current)")
	}

	owned := objStringArray(next, "ownedPaths")
	want := []string{"already-owned.txt", "newly-changed.txt"}
	if !stringSliceEqual(owned, want) {
		t.Errorf("ownedPaths = %v, want %v (baseline-owned.txt drops out: it is back in the initial baseline)", owned, want)
	}

	observed := objObject(next, "observed")
	if objString(observed, "fingerprint") != "fp2" {
		t.Error("observed should be replaced with the current snapshot doc")
	}
}

func TestReconcileLedgerOwnedPathsSortedAndDeduped(t *testing.T) {
	state := canonjson.NewObject().
		Set("initial", canonjson.NewObject().Set("revision", "").Set("entries", canonjson.NewObject())).
		Set("observed", canonjson.NewObject()).
		Set("ownedPaths", stringsToValues([]string{"z.txt", "a.txt"}))

	current := &Snapshot{
		Revision: "rev1",
		Entries:  entriesObj(map[string]string{"z.txt": "file:1", "a.txt": "file:2"}),
	}
	changed := []string{"a.txt"}

	next := reconcileLedger(state, current, changed)
	owned := objStringArray(next, "ownedPaths")
	want := []string{"a.txt", "z.txt"}
	if !stringSliceEqual(owned, want) {
		t.Errorf("ownedPaths = %v, want %v (sorted, deduped)", owned, want)
	}
}

// TestObserveInitialGuardMatchesReconcileRequirement pins the precondition
// Observe checks: reconcileLedger's initial.Set panics on a nil *canonjson.Object.
func TestObserveInitialGuardMatchesReconcileRequirement(t *testing.T) {
	cases := []struct {
		name     string
		state    *canonjson.Object
		wantBail bool
	}{
		{"missing initial", canonjson.NewObject(), true},
		{"null initial", canonjson.NewObject().Set("initial", nil), true},
		{"object initial", canonjson.NewObject().Set("initial", canonjson.NewObject()), false},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := objObject(tc.state, "initial") == nil; got != tc.wantBail {
				t.Errorf("objObject(state, %q) nil-ness = %v, want bail = %v", "initial", got, tc.wantBail)
			}
		})
	}
}

func TestObserveDriftNoticeTracksRemainingOwnership(t *testing.T) {
	if _, err := exec.LookPath("jj"); err != nil {
		t.Skip("jj not on PATH")
	}
	t.Setenv("JJ_CONFIG", filepath.Join(t.TempDir(), "config.toml"))
	noMaintenance, err := exec.LookPath("false")
	if err != nil {
		t.Skip("false not on PATH")
	}
	t.Setenv("SUBSTRATE_ENGINE_BIN", noMaintenance)
	root := t.TempDir()
	jj := func(args ...string) {
		t.Helper()
		if out, err := exec.Command("jj", append([]string{"-R", root}, args...)...).CombinedOutput(); err != nil {
			t.Fatalf("jj %v: %v\n%s", args, err, out)
		}
	}
	write := func(name string) {
		t.Helper()
		if err := os.WriteFile(filepath.Join(root, name), []byte(name+"\n"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	if out, err := exec.Command("jj", "git", "init", root).CombinedOutput(); err != nil {
		t.Fatalf("jj git init: %v\n%s", err, out)
	}
	write("base.txt")
	jj("commit", "-m", "base")

	engine := New(config.Paths{RepoRoot: root}, &vcs.Repo{Root: root, Kind: vcs.KindJJ})
	run := func(action string) {
		t.Helper()
		if res := engine.Run(context.Background(), []string{action}, strings.NewReader(`{"session_id":"s1"}`)); res.Code != 0 {
			t.Fatalf("%s: code %d: %s", action, res.Code, res.Stderr)
		}
	}
	ledger := func() (notice string, owned []string) {
		t.Helper()
		state, err := readLedger(engine.statePath("s1"))
		if err != nil {
			t.Fatal(err)
		}
		return objString(state, "driftNotice"), objStringArray(state, "ownedPaths")
	}

	run("start")
	write("owned.txt")
	run("observe")

	jj("describe", "-r", "@-", "-m", "base reworded")
	run("observe")
	if notice, owned := ledger(); notice == "" || !stringSliceEqual(owned, []string{"owned.txt"}) {
		t.Fatalf("revision moved under owned work: notice=%q owned=%v, want a drift notice and owned.txt still owned", notice, owned)
	}

	jj("commit", "-m", "user commits the owned work")
	run("observe")
	if notice, owned := ledger(); notice != "" || len(owned) != 0 {
		t.Fatalf("user committed all owned work: notice=%q owned=%v, want no notice and nothing owned; a checkpoint has nothing left to clear it", notice, owned)
	}
}
