package gate

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

type RunContext struct {
	SubDir    string
	RepoRoot  string
	Config    string
	Langmap   string
	Baseline  string
	Inventory string
	Claims    string
	RunDir    string
	Results   []CheckResult
	Failures  int
}

type checkSpec struct {
	Name string
	Path string
}

func DiscoverChecks(repoRoot, subDir string) ([]checkSpec, error) {
	seen := make(map[string]bool)
	var specs []checkSpec
	for name := range NativeRuns {
		seen[name] = true
		specs = append(specs, checkSpec{Name: name})
	}
	fileBacked := 0
	for _, d := range []string{
		filepath.Join(repoRoot, "core", "checks.d"),
		filepath.Join(subDir, "checks.d"),
	} {
		entries, err := os.ReadDir(d)
		if err != nil {
			continue
		}
		for _, e := range entries {
			if e.IsDir() || !strings.HasSuffix(e.Name(), ".sh") {
				continue
			}
			if seen[e.Name()] {
				continue
			}
			seen[e.Name()] = true
			specs = append(specs, checkSpec{
				Name: e.Name(),
				Path: filepath.Join(d, e.Name()),
			})
			fileBacked++
		}
	}
	if fileBacked == 0 {
		return nil, fmt.Errorf("no checks in checks.d — a gate with zero checks cannot pass blind")
	}
	sort.Slice(specs, func(i, j int) bool {
		return specs[i].Name < specs[j].Name
	})
	return specs, nil
}

func isDisabled(name, configPath string) bool {
	data, err := os.ReadFile(configPath)
	if err != nil {
		return false
	}
	var cfg struct {
		Checks struct {
			Disabled []string `json:"disabled"`
		} `json:"checks"`
	}
	if err := json.Unmarshal(data, &cfg); err != nil {
		return false
	}
	for _, d := range cfg.Checks.Disabled {
		if strings.Contains(d, name) {
			return true
		}
	}
	return false
}

func maxJobs() int {
	if s := os.Getenv("SUBSTRATE_GATE_JOBS"); s != "" {
		n, err := strconv.Atoi(s)
		if err == nil && n >= 1 {
			return n
		}
	}
	out, err := exec.Command("nproc").Output()
	if err == nil {
		n, err := strconv.Atoi(strings.TrimSpace(string(out)))
		if err == nil && n >= 1 {
			return n
		}
	}
	return 4
}

func RunChecks(ctx *RunContext, specs []checkSpec, claimsData []byte) error {
	runDir, err := os.MkdirTemp("", "substrate-run-*")
	if err != nil {
		return fmt.Errorf("create run dir: %w", err)
	}
	ctx.RunDir = runDir

	nativeNames := make([]string, 0, len(NativeRuns))
	for name := range NativeRuns {
		nativeNames = append(nativeNames, name)
	}
	sort.Strings(nativeNames)

	baseEnv := []string{
		"SUBSTRATE_DIR=" + ctx.SubDir,
		"REPO_ROOT=" + ctx.RepoRoot,
		"CONFIG=" + ctx.Config,
		"LANGMAP=" + ctx.Langmap,
		"BASELINE=" + ctx.Baseline,
		"INVENTORY=" + ctx.Inventory,
		"CLAIMS=" + ctx.Claims,
		"SUBSTRATE_NATIVE_CHECKS=" + strings.Join(nativeNames, " "),
		"LC_ALL=C",
	}

	max := maxJobs()
	sem := make(chan struct{}, max)
	results := make(chan CheckResult, len(specs))
	var wg sync.WaitGroup
	found := 0

	for _, spec := range specs {
		if isDisabled(spec.Name, ctx.Config) {
			warn("%s: disabled in substrate.json", spec.Name)
			continue
		}
		found++
		wg.Add(1)
		go func(spec checkSpec) {
			defer wg.Done()
			sem <- struct{}{}
			defer func() { <-sem }()

			start := time.Now()
			res := runCheck(spec, baseEnv, claimsData, ctx)
			res.MS = int(time.Since(start).Milliseconds())
			results <- res
		}(spec)
	}

	if found == 0 {
		return fmt.Errorf("no checks in checks.d — a gate with zero checks cannot pass blind")
	}

	go func() {
		wg.Wait()
		close(results)
	}()

	var collected []CheckResult
	for r := range results {
		collected = append(collected, r)
	}
	sort.Slice(collected, func(i, j int) bool {
		return collected[i].Name < collected[j].Name
	})

	total := len(specs)
	failures := 0
	for i, r := range collected {
		if r.Output != "" {
			fmt.Print(strings.TrimRight(r.Output, "\n"))
			fmt.Print("\n")
		}
		took := FormatDuration(r.MS)
		if r.RC == 0 {
			fmt.Printf("[ok] %s (%s) [%d/%d]\n", r.Name, took, i+1, total)
		} else {
			if r.RC >= 2 {
				fmt.Printf("[!] FAIL %s: infrastructure failure (rc=%d) — the gate cannot pass blind (%s) [%d/%d]\n", r.Name, r.RC, took, i+1, total)
			} else {
				fmt.Printf("[!] FAIL %s (%s) [%d/%d]\n", r.Name, took, i+1, total)
			}
			failures++
		}
	}

	ctx.Results = collected
	ctx.Failures = failures
	return nil
}

// runCheck runs one check (native or bash subprocess), returning its result
// without duration. Each call writes its own output/metrics files.
func runCheck(spec checkSpec, baseEnv []string, claimsData []byte, ctx *RunContext) CheckResult {
	if runFn, ok := NativeRuns[spec.Name]; ok {
		inv, _ := readInventory(ctx.Inventory)
		envMap := make(map[string]string)
		for _, e := range baseEnv {
			k, v := splitEq(e)
			envMap[k] = v
		}
		envMap["SUBSTRATE_CHECK_NAME"] = spec.Name
		metricsPath := filepath.Join(ctx.RunDir, spec.Name+".metrics")
		os.WriteFile(metricsPath, nil, 0644)
		envMap["METRICS"] = metricsPath

		rc, metrics, out, runErr := runFn(context.Background(), inv, claimsData, envMap)
		if runErr != nil {
			rc = 3
			out = runErr.Error()
		}
		var buf strings.Builder
		for _, m := range metrics {
			fmt.Fprintf(&buf, `{"name":"%s","value":%s,"dir":"%s"}`+"\n", m.Name, string(m.RawValue), m.Dir)
		}
		if buf.Len() > 0 {
			os.WriteFile(metricsPath, []byte(buf.String()), 0644)
		}
		return CheckResult{Name: spec.Name, RC: rc, Output: out}
	}

	outPath := filepath.Join(ctx.RunDir, spec.Name+".out")
	metricsPath := filepath.Join(ctx.RunDir, spec.Name+".metrics")
	os.WriteFile(metricsPath, nil, 0644)

	cmd := exec.Command("bash", spec.Path)
	cmd.Dir = ctx.RepoRoot
	outFile, _ := os.Create(outPath)
	cmd.Stdout = outFile
	cmd.Stderr = outFile
	cmd.Env = append(os.Environ(),
		append(baseEnv,
			"SUBSTRATE_CHECK_NAME="+spec.Name,
			"METRICS="+metricsPath,
		)...,
	)
	if startErr := cmd.Start(); startErr != nil {
		outFile.Close()
		return CheckResult{Name: spec.Name, RC: 3, Output: fmt.Sprintf("start %s: %v", spec.Name, startErr)}
	}
	cmd.Wait()
	outFile.Close()
	rc := resolveRC(cmd)
	outData, _ := os.ReadFile(outPath)
	return CheckResult{Name: spec.Name, RC: rc, Output: string(outData)}
}

func splitEq(s string) (string, string) {
	k, v, _ := strings.Cut(s, "=")
	return k, v
}

func resolveRC(cmd *exec.Cmd) int {
	state := cmd.ProcessState
	if state == nil {
		return 70
	}
	if state.Success() {
		return 0
	}
	code := state.ExitCode()
	if code >= 0 {
		return code
	}
	return 70
}

func readInventory(path string) ([]string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read inventory %s: %w", path, err)
	}
	var lines []string
	scanner := bufio.NewScanner(strings.NewReader(string(data)))
	for scanner.Scan() {
		lines = append(lines, scanner.Text())
	}
	if err := scanner.Err(); err != nil {
		return nil, fmt.Errorf("scan inventory: %w", err)
	}
	return lines, nil
}

func CollectAllMetrics(results []CheckResult, runDir string) ([]MetricRecord, error) {
	var all []MetricRecord
	for _, r := range results {
		metricsPath := filepath.Join(runDir, r.Name+".metrics")
		data, err := os.ReadFile(metricsPath)
		if err != nil {
			continue
		}
		scanner := bufio.NewScanner(strings.NewReader(string(data)))
		for scanner.Scan() {
			line := strings.TrimSpace(scanner.Text())
			if line == "" {
				continue
			}
			var m struct {
				Name  string          `json:"name"`
				Value json.RawMessage `json:"value"`
				Dir   string          `json:"dir"`
			}
			if err := json.Unmarshal([]byte(line), &m); err != nil {
				continue
			}
			all = append(all, MetricRecord{
				Name:     m.Name,
				RawValue: m.Value,
				Dir:      m.Dir,
			})
		}
	}
	return all, nil
}
