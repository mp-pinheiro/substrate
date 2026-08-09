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

type job struct {
	name      string
	cmd       *exec.Cmd
	outPath   string
	start     time.Time
	native    bool
	nativeRC  int
	nativeOut string
	nativeMs  int
}

func DiscoverChecks(repoRoot, subDir string) ([]checkSpec, error) {
	seen := make(map[string]bool)
	var specs []checkSpec
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
		}
	}
	if len(specs) == 0 {
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

	baseEnv := []string{
		"SUBSTRATE_DIR=" + ctx.SubDir,
		"REPO_ROOT=" + ctx.RepoRoot,
		"CONFIG=" + ctx.Config,
		"LANGMAP=" + ctx.Langmap,
		"BASELINE=" + ctx.Baseline,
		"INVENTORY=" + ctx.Inventory,
		"CLAIMS=" + ctx.Claims,
		"LC_ALL=C",
	}

	max := maxJobs()
	var jobs []job
	var results []CheckResult
	failures := 0
	found := 0

	for _, spec := range specs {
		if isDisabled(spec.Name, ctx.Config) {
			warn("%s: disabled in substrate.json", spec.Name)
			continue
		}
		found = 1

		if runFn, ok := NativeRuns[spec.Name]; ok {
			inv, _ := readInventory(ctx.Inventory)
			envMap := make(map[string]string)
			for _, e := range baseEnv {
				k, v := splitEq(e)
				envMap[k] = v
			}
			envMap["SUBSTRATE_CHECK_NAME"] = spec.Name
			metricsPath := filepath.Join(runDir, spec.Name+".metrics")
			os.WriteFile(metricsPath, nil, 0644)
			envMap["METRICS"] = metricsPath

			rc, metrics, out, runErr := runFn(context.Background(), inv, claimsData, envMap)
			if runErr != nil {
				rc = 3
				out = runErr.Error()
			}
			if out != "" {
				fmt.Print(out)
			}
			jobs = append(jobs, job{
				name:      spec.Name,
				native:    true,
				nativeRC:  rc,
				nativeOut: out,
				nativeMs:  0,
				start:     time.Now(),
			})
			var buf strings.Builder
			for _, m := range metrics {
				fmt.Fprintf(&buf, `{"name":"%s","value":%s,"dir":"%s"}`+"\n", m.Name, string(m.RawValue), m.Dir)
			}
			if buf.Len() > 0 {
				os.WriteFile(filepath.Join(runDir, spec.Name+".metrics"), []byte(buf.String()), 0644)
			}

			if len(jobs)-len(results) >= max {
				reportJob(jobs, &results, &failures, len(specs))
			}
			continue
		}

		outPath := filepath.Join(runDir, spec.Name+".out")
		metricsPath := filepath.Join(runDir, spec.Name+".metrics")
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
		start := time.Now()
		if err := cmd.Start(); err != nil {
			outFile.Close()
			return fmt.Errorf("start %s: %w", spec.Name, err)
		}
		jobs = append(jobs, job{
			name:    spec.Name,
			cmd:     cmd,
			outPath: outPath,
			start:   start,
		})

		if len(jobs)-len(results) >= max {
			reportJob(jobs, &results, &failures, len(specs))
		}
	}

	if found == 0 {
		return fmt.Errorf("no checks in checks.d — a gate with zero checks cannot pass blind")
	}

	for len(results) < len(jobs) {
		reportJob(jobs, &results, &failures, len(specs))
	}

	ctx.Results = results
	ctx.Failures = failures
	return nil
}

func reportJob(jobs []job, results *[]CheckResult, failures *int, total int) {
	j := jobs[len(*results)]
	if j.native {
		if j.nativeRC == 0 {
			fmt.Printf("[ok] %s (0ms) [%d/%d]\n", j.name, len(*results)+1, total)
		} else {
			fmt.Printf("[!] FAIL %s (rc=%d) [%d/%d]\n", j.name, j.nativeRC, len(*results)+1, total)
			*failures++
		}
		*results = append(*results, CheckResult{
			Name:   j.name,
			RC:     j.nativeRC,
			MS:     0,
			Output: j.nativeOut,
		})
		return
	}

	j.cmd.Wait()
	j.cmd.Stdout.(*os.File).Close()
	elapsed := time.Since(j.start)
	rc := resolveRC(j.cmd)
	outData, _ := os.ReadFile(j.outPath)
	took := FormatDuration(int(elapsed.Milliseconds()))

	if outStr := string(outData); outStr != "" {
		fmt.Print(outStr)
	}
	if rc == 0 {
		fmt.Printf("[ok] %s (%s) [%d/%d]\n", j.name, took, len(*results)+1, total)
	} else {
		fmt.Printf("[!] FAIL %s (%s) [%d/%d]\n", j.name, took, len(*results)+1, total)
		*failures++
	}
	*results = append(*results, CheckResult{
		Name:   j.name,
		RC:     rc,
		MS:     int(elapsed.Milliseconds()),
		Output: string(outData),
	})
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
