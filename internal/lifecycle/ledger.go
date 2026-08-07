package lifecycle

import (
	"errors"
	"fmt"
	"os"
	"sort"
	"strings"

	"github.com/mp-pinheiro/substrate/internal/canonjson"
	"github.com/mp-pinheiro/substrate/internal/xshell"
)

func trimTrailingNewlines(s string) string {
	return strings.TrimRight(s, "\n")
}

func (e *Engine) writeLedger(path string, doc *canonjson.Object) error {
	b, err := canonjson.Marshal(doc)
	if err != nil {
		return fmt.Errorf("lifecycle: encode ledger: %w", err)
	}
	b = append(b, '\n')
	if err := xshell.WriteFileAtomic(path, b, 0o600); err != nil {
		return fmt.Errorf("lifecycle: write ledger: %w", err)
	}
	return nil
}

func readLedger(path string) (*canonjson.Object, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("lifecycle: read ledger: %w", err)
	}
	val, err := canonjson.Unmarshal(raw)
	if err != nil {
		return nil, fmt.Errorf("lifecycle: decode ledger: %w", err)
	}
	obj, ok := val.(*canonjson.Object)
	if !ok {
		return nil, errors.New("lifecycle: ledger root is not an object")
	}
	// SAFETY: jq null-propagates through a missing/null .initial but errors
	// indexing a scalar; only a present non-null non-object .initial mirrors that error.
	if iv, present := obj.Get("initial"); present && iv != nil {
		if _, ok := iv.(*canonjson.Object); !ok {
			return nil, errors.New("lifecycle: ledger initial is not an object")
		}
	}
	return obj, nil
}

// loadLedgerOrBail is the shared "[ -f $STATE ] || exit 0" preamble: present=false
// means the caller returns Code 0; present=true with err!=nil means Code 2.
func (e *Engine) loadLedgerOrBail(statePath string) (state *canonjson.Object, present bool, err error) {
	if _, statErr := os.Stat(statePath); statErr != nil {
		return nil, false, nil
	}
	state, err = readLedger(statePath)
	return state, true, err
}

// newLedger builds the fresh-ledger document shape shared by Start and
// Observe's missing-state branch, in jq's own key order.
func newLedger(session, repoRoot string, current *Snapshot, trackingError canonjson.Value) *canonjson.Object {
	return canonjson.NewObject().
		Set("session", session).
		Set("repoRoot", repoRoot).
		Set("initial", current.Doc()).
		Set("observed", current.Doc()).
		Set("ownedPaths", []canonjson.Value{}).
		Set("trackingError", trackingError).
		Set("stopBlocked", false).
		Set("completedCommit", nil)
}

// writeLedgerResult is the "write, then Code 0 or 2" tail Complete and
// Observe share.
func (e *Engine) writeLedgerResult(statePath string, doc *canonjson.Object) Result {
	if err := e.writeLedger(statePath, doc); err != nil {
		return Result{Code: 2}
	}
	return Result{Code: 0}
}

// marshalLine mirrors jq's own stdout writer: `-cn` compact JSON plus the
// trailing newline jq always appends after a printed value.
func marshalLine(doc *canonjson.Object) ([]byte, error) {
	b, err := canonjson.Marshal(doc)
	if err != nil {
		return nil, fmt.Errorf("lifecycle: marshal: %w", err)
	}
	return append(b, '\n'), nil
}

func nullable(s string) canonjson.Value {
	if s == "" {
		return nil
	}
	return s
}

func objString(o *canonjson.Object, key string) string {
	if o == nil {
		return ""
	}
	v, ok := o.Get(key)
	if !ok {
		return ""
	}
	s, ok := v.(string)
	if !ok {
		return ""
	}
	return s
}

func objBool(o *canonjson.Object, key string, def bool) bool {
	if o == nil {
		return def
	}
	v, ok := o.Get(key)
	if !ok {
		return def
	}
	b, ok := v.(bool)
	if !ok {
		return def
	}
	return b
}

func objObject(o *canonjson.Object, key string) *canonjson.Object {
	if o == nil {
		return nil
	}
	v, ok := o.Get(key)
	if !ok {
		return nil
	}
	obj, ok := v.(*canonjson.Object)
	if !ok {
		return nil
	}
	return obj
}

func objStringArray(o *canonjson.Object, key string) []string {
	if o == nil {
		return nil
	}
	v, ok := o.Get(key)
	if !ok {
		return nil
	}
	arr, ok := v.([]canonjson.Value)
	if !ok {
		return nil
	}
	out := make([]string, 0, len(arr))
	for _, item := range arr {
		if s, ok := item.(string); ok {
			out = append(out, s)
		}
	}
	return out
}

func stringsToValues(xs []string) []canonjson.Value {
	out := make([]canonjson.Value, len(xs))
	for i, x := range xs {
		out[i] = x
	}
	return out
}

func stringEquals(o *canonjson.Object, key, target string) bool {
	if o == nil {
		return false
	}
	v, ok := o.Get(key)
	if !ok {
		return false
	}
	s, ok := v.(string)
	if !ok {
		return false
	}
	return s == target
}

func boolEquals(o *canonjson.Object, key string, target bool) bool {
	if o == nil {
		return false
	}
	v, ok := o.Get(key)
	if !ok {
		return false
	}
	b, ok := v.(bool)
	if !ok {
		return false
	}
	return b == target
}

// sortedUnique replicates jq's `unique`: sort by raw byte order, then dedupe.
func sortedUnique(xs []string) []string {
	if len(xs) == 0 {
		return nil
	}
	cp := append([]string(nil), xs...)
	sort.Strings(cp)
	out := cp[:1]
	for _, x := range cp[1:] {
		if x != out[len(out)-1] {
			out = append(out, x)
		}
	}
	return out
}

// intersectPreserveOrder replicates jq's `$a - ($a - $b)`: elements of a
// that are also in b, in a's original order.
func intersectPreserveOrder(a, b []string) []string {
	set := make(map[string]bool, len(b))
	for _, x := range b {
		set[x] = true
	}
	var out []string
	for _, x := range a {
		if set[x] {
			out = append(out, x)
		}
	}
	return out
}

func subtractPreserveOrder(a, b []string) []string {
	set := make(map[string]bool, len(b))
	for _, x := range b {
		set[x] = true
	}
	var out []string
	for _, x := range a {
		if !set[x] {
			out = append(out, x)
		}
	}
	return out
}
