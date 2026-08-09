package gate

import (
	"context"
	"fmt"
	"os"
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

	claimsData, err := os.ReadFile(claims)
	if err != nil {
		fmt.Fprintf(os.Stderr, "gate: reading CLAIMS: %v\n", err)
	}
	if err := RunChecks(&ctxRun, specs, claimsData); err != nil {
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


func warn(format string, args ...interface{}) {
	fmt.Fprintf(os.Stderr, "\033[0;33m[!]\033[0m "+format+"\n", args...)
}

func info(format string, args ...interface{}) {
	fmt.Fprintf(os.Stderr, "\033[0;34m[+]\033[0m "+format+"\n", args...)
}

func successMsg(format string, args ...interface{}) {
	fmt.Fprintf(os.Stderr, "\033[0;32m[ok]\033[0m "+format+"\n", args...)
}
