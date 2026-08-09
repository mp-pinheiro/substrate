package gate

import (
	"context"
	"fmt"
	"os"
	"strings"
	"time"
)

func Run(ctx context.Context, args []string) int {
	subDir, repoRoot, err := ResolveRoots()
	if err != nil {
		fmt.Fprintf(os.Stderr, "gate: %v\n", err)
		return 12
	}

	flags, rest, err := ParseFlags(args)
	if err != nil {
		fmt.Fprintf(os.Stderr, "gate: %v\n", err)
		return 12
	}

	for _, r := range rest {
		if r == "--list-checks" {
			return listChecks(repoRoot, subDir)
		}
	}

	configPath := repoRoot + "/substrate.json"
	langmapPath := subDir + "/langmap.json"
	baselinePath := repoRoot + "/substrate-baseline.json"

	rc := RunPreflight(Preflight{
		SubDir:   subDir,
		RepoRoot: repoRoot,
		Config:   configPath,
		Langmap:  langmapPath,
		Baseline: baselinePath,
		Flags:    flags,
	})
	if rc != 0 {
		return rc
	}

	inventory, err := BuildInventory(repoRoot, subDir, os.Getenv("SUBSTRATE_FILE_LIST"))
	if err != nil {
		fmt.Fprintf(os.Stderr, "gate: %v\n", err)
		return 3
	}
	defer os.Remove(inventory)

	claimsOut := os.Getenv("SUBSTRATE_CLAIMS_OUT")
	claims, err := BuildClaims(repoRoot, langmapPath, configPath, inventory, claimsOut)
	if err != nil {
		fmt.Fprintf(os.Stderr, "gate: %v\n", err)
		return 3
	}
	defer os.Remove(claims)

	specs, err := DiscoverChecks(repoRoot, subDir)
	if err != nil {
		fmt.Fprintf(os.Stderr, "gate: %v\n", err)
		return 3
	}

	gateStart := time.Now()
	fmt.Printf("[+] substrate gate: %s\n", repoRoot)

	ctxRun := RunContext{
		SubDir:    subDir,
		RepoRoot:  repoRoot,
		Config:    configPath,
		Langmap:   langmapPath,
		Baseline:  baselinePath,
		Inventory: inventory,
		Claims:    claims,
	}

	if err := RunChecks(&ctxRun, specs, nil); err != nil {
		fmt.Fprintf(os.Stderr, "gate: %v\n", err)
		return 3
	}

	metricsFile, err := os.CreateTemp("", "substrate-metrics-*")
	if err == nil {
		metricsPath := metricsFile.Name()
		allMetrics, _ := CollectAllMetrics(ctxRun.Results, ctxRun.RunDir)
		for _, m := range allMetrics {
			dir := m.Dir
			if dir == "" {
				dir = "lo"
			}
			fmt.Fprintf(metricsFile, `{"name":"%s","value":%s,"dir":"%s"}`+"\n", m.Name, string(m.RawValue), dir)
		}
		metricsFile.Close()

		metricsOut := os.Getenv("SUBSTRATE_METRICS_OUT")
		if metricsOut != "" {
			stagedMove(metricsPath, metricsOut)
		}

		ratchetResult, ratchetFailures := RunRatchet(metricsPath, baselinePath, configPath, flags)
		if ratchetFailures > 0 {
			ctxRun.Failures += ratchetFailures
		}

		if flags.UpdateBaseline {
			if ctxRun.Failures > 0 {
				warn("refusing to update baseline with %d failing check(s) — fix detector failures; use --accept-regression only for metric regressions", ctxRun.Failures)
			} else {
				if WriteBaseline(baselinePath, metricsPath, configPath, flags, ratchetResult.AcceptedNow) != 0 {
					ctxRun.Failures++
				}
			}
		}

		os.Remove(metricsPath)
	}
	defer os.RemoveAll(ctxRun.RunDir)

	took := FormatDuration(int(time.Since(gateStart).Milliseconds()))
	if ctxRun.Failures > 0 {
		warn("gate: %d check(s) failed (%s)", ctxRun.Failures, took)
		return 1
	}
	successMsg("gate: all checks passed (%s)", took)
	return 0
}

func listChecks(repoRoot, subDir string) int {
	specs, err := DiscoverChecks(repoRoot, subDir)
	if err != nil {
		fmt.Fprintf(os.Stderr, "gate: %v\n", err)
		return 2
	}
	for _, s := range specs {
		kind := "[bash]"
		if _, ok := NativeRuns[s.Name]; ok {
			kind = "[native]"
		}
		fmt.Printf("%s %s\n", kind, s.Name)
	}
	return 0
}

func writeMetricsSink(metrics []MetricRecord, path string) {
	var lines []string
	for _, m := range metrics {
		dir := m.Dir
		if dir == "" {
			dir = "lo"
		}
		lines = append(lines, fmt.Sprintf(`{"name":"%s","value":%s,"dir":"%s"}`, m.Name, string(m.RawValue), dir))
	}
	data := strings.Join(lines, "\n") + "\n"

	tmp, err := os.CreateTemp(path+".", "substrate-metrics-*")
	if err != nil {
		return
	}
	tmpName := tmp.Name()
	if _, err := tmp.WriteString(data); err != nil {
		tmp.Close()
		os.Remove(tmpName)
		return
	}
	if err := tmp.Close(); err != nil {
		os.Remove(tmpName)
		return
	}
	info, _ := os.Stat(path)
	mode := os.FileMode(0600)
	if info != nil {
		mode = info.Mode()
	}
	os.Chmod(tmpName, mode)
	os.Rename(tmpName, path)
}

func warn(format string, args ...interface{}) {
	fmt.Fprintf(os.Stderr, "[!] "+format+"\n", args...)
}

func info(format string, args ...interface{}) {
	fmt.Fprintf(os.Stderr, "[+] "+format+"\n", args...)
}

func successMsg(format string, args ...interface{}) {
	fmt.Fprintf(os.Stderr, "[ok] "+format+"\n", args...)
}
