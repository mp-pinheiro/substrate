package gate

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

const (
	dupBaseline  = `{"metrics":{"dup_pct":2.122568},"direction":{"dup_pct":"lo"}}`
	covBaseline  = `{"metrics":{"cov":90},"direction":{"cov":"hi"}}`
	dupTolerance = `{"ratchet":{"tolerance":{"dup_pct":0.05}}}`
	covTolerance = `{"ratchet":{"tolerance":{"cov":0.5}}}`
)

type ratchetRun struct {
	result       *RatchetResult
	rc           int
	metricsPath  string
	baselinePath string
	configPath   string
}

func ratchetCase(t *testing.T, name, metrics, baseline, config string, flags PreflightFlags, check func(*testing.T, ratchetRun)) {
	t.Helper()
	t.Run(name, func(t *testing.T) {
		t.Parallel()
		dir := t.TempDir()
		run := ratchetRun{
			metricsPath:  filepath.Join(dir, "metrics.jsonl"),
			baselinePath: filepath.Join(dir, "substrate-baseline.json"),
			configPath:   filepath.Join(dir, "substrate.json"),
		}
		for path, body := range map[string]string{run.metricsPath: metrics, run.baselinePath: baseline, run.configPath: config} {
			if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
				t.Fatal(err)
			}
		}
		run.result, run.rc = RunRatchet(run.metricsPath, run.baselinePath, run.configPath, flags)
		check(t, run)
	})
}

func metricLine(name, value, dir string) string {
	return `{"name":"` + name + `","value":` + value + `,"dir":"` + dir + `"}` + "\n"
}

func TestRunRatchetTolerance(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name          string
		metrics       string
		baseline      string
		config        string
		wantRC        int
		wantWorse     []string
		wantTolerated []string
		wantDetail    string
	}{
		{
			name: "absent key keeps the exact ratchet", metrics: metricLine("dup_pct", "2.123294", "lo"),
			baseline: dupBaseline, config: `{}`,
			wantRC: 1, wantWorse: []string{"dup_pct: 2.123294 (best 2.122568)"},
		},
		{
			name: "inside tolerance passes and is reported", metrics: metricLine("dup_pct", "2.123294", "lo"),
			baseline: dupBaseline, config: dupTolerance,
			wantTolerated: []string{"dup_pct"},
		},
		{
			name: "the boundary is inside", metrics: metricLine("dup_pct", "2.172568", "lo"),
			baseline: dupBaseline, config: dupTolerance,
			wantTolerated: []string{"dup_pct"},
		},
		{
			name: "beyond tolerance fails with the exact-ratchet line", metrics: metricLine("dup_pct", "2.2", "lo"),
			baseline: dupBaseline, config: dupTolerance,
			wantRC: 1, wantWorse: []string{"dup_pct: 2.2 (best 2.122568)"},
		},
		{
			name: "an improvement is not reported as tolerated", metrics: metricLine("dup_pct", "2.1", "lo"),
			baseline: dupBaseline, config: dupTolerance,
		},
		{
			name: "higher-is-better mirrors the slack", metrics: metricLine("cov", "89.7", "hi"),
			baseline: covBaseline, config: covTolerance,
			wantTolerated: []string{"cov"},
		},
		{
			name: "higher-is-better fails beyond the slack", metrics: metricLine("cov", "89.4", "hi"),
			baseline: covBaseline, config: covTolerance,
			wantRC: 1, wantWorse: []string{"cov: 89.4 (best 90)"},
		},
		{
			name: "a metric the baseline lacks gets no slack", metrics: metricLine("dup_pct", "0.03", "lo"),
			baseline: covBaseline, config: dupTolerance,
			wantRC: 1, wantWorse: []string{"dup_pct: 0.03 (best 0)"},
		},
		{
			name: "a hard cap ignores tolerance", metrics: metricLine("oversized", "11", "lo"),
			baseline: `{"metrics":{"oversized":10},"direction":{"oversized":"lo"}}`,
			config:   `{"budgets":{"oversized":10},"ratchet":{"tolerance":{"oversized":5}}}`,
			wantRC:   1, wantWorse: []string{"oversized: 11 (best 10, hard cap 10 \u2014 over cap)"},
		},
		{
			name: "a negative tolerance fails closed", metrics: metricLine("dup_pct", "2.122568", "lo"),
			baseline: dupBaseline, config: `{"ratchet":{"tolerance":{"dup_pct":-0.1}}}`,
			wantRC: 1, wantDetail: "ratchet.tolerance.dup_pct must be a non-negative number",
		},
		{
			name: "a quoted tolerance fails closed", metrics: metricLine("dup_pct", "2.122568", "lo"),
			baseline: dupBaseline, config: `{"ratchet":{"tolerance":{"dup_pct":"0.05"}}}`,
			wantRC: 1, wantDetail: "ratchet.tolerance.dup_pct must be a non-negative number",
		},
		{
			name: "a non-object tolerance fails closed", metrics: metricLine("dup_pct", "2.122568", "lo"),
			baseline: dupBaseline, config: `{"ratchet":{"tolerance":0.05}}`,
			wantRC: 1, wantDetail: "ratchet.tolerance must map metric keys",
		},
	}

	for _, tt := range tests {
		ratchetCase(t, tt.name, tt.metrics, tt.baseline, tt.config, PreflightFlags{}, func(t *testing.T, run ratchetRun) {
			if run.rc != tt.wantRC {
				t.Fatalf("rc = %d, want %d (details %v)", run.rc, tt.wantRC, run.result.FailureDetails)
			}
			if tt.wantDetail != "" {
				if len(run.result.FailureDetails) != 1 || !strings.Contains(run.result.FailureDetails[0], tt.wantDetail) {
					t.Fatalf("failure details = %v, want one naming %q", run.result.FailureDetails, tt.wantDetail)
				}
				return
			}
			if len(run.result.Worse)+len(tt.wantWorse) > 0 && !reflect.DeepEqual(run.result.Worse, tt.wantWorse) {
				t.Fatalf("worse = %v, want %v", run.result.Worse, tt.wantWorse)
			}
			if len(run.result.Tolerated)+len(tt.wantTolerated) > 0 && !reflect.DeepEqual(run.result.Tolerated, tt.wantTolerated) {
				t.Fatalf("tolerated = %v, want %v", run.result.Tolerated, tt.wantTolerated)
			}
		})
	}
}

func TestWriteBaselineUnderTolerance(t *testing.T) {
	t.Parallel()

	tighten := PreflightFlags{UpdateBaseline: true, TightenBaseline: true}
	accept := PreflightFlags{
		UpdateBaseline: true, TightenBaseline: true, AcceptRegression: true,
		AcceptKeys: "dup_pct", AcceptReason: "a ratio moved because the denominator shrank",
	}
	writes := []struct {
		name    string
		value   string
		flags   PreflightFlags
		wantCap string
	}{
		{name: "tighten keeps a tolerated ceiling", value: "2.123294", flags: tighten, wantCap: "2.122568"},
		{name: "keyed accept cannot raise a tolerated ceiling", value: "2.123294", flags: accept, wantCap: "2.122568"},
		{name: "tighten writes an improvement exactly", value: "2.1004", flags: tighten, wantCap: "2.1004"},
	}

	for _, w := range writes {
		ratchetCase(t, w.name, metricLine("dup_pct", w.value, "lo"), dupBaseline, dupTolerance, w.flags, func(t *testing.T, run ratchetRun) {
			if run.rc != 0 {
				t.Fatalf("ratchet rc = %d (details %v)", run.rc, run.result.FailureDetails)
			}
			if rc := WriteBaseline(run.baselinePath, run.metricsPath, run.configPath, w.flags, run.result.AcceptedNow, run.result.Tolerated); rc != 0 {
				t.Fatalf("baseline write rc = %d", rc)
			}
			data, err := os.ReadFile(run.baselinePath)
			if err != nil {
				t.Fatal(err)
			}
			var doc struct {
				Metrics  map[string]json.RawMessage `json:"metrics"`
				Accepted map[string]json.RawMessage `json:"accepted"`
			}
			if err := json.Unmarshal(data, &doc); err != nil {
				t.Fatal(err)
			}
			if got := string(doc.Metrics["dup_pct"]); got != w.wantCap {
				t.Fatalf("ceiling = %s, want %s", got, w.wantCap)
			}
			if len(doc.Accepted) != 0 {
				t.Fatalf("accepted = %s, want no record", data)
			}
		})
	}
}
