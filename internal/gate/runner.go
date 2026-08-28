package gate

import (
	"context"
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/mp-pinheiro/substrate/internal/recovery"
)

func emitFailure(flags PreflightFlags, report recovery.Report, rc int) int {
	recovery.Emit(report, flags.JSON)
	return rc
}

func gateFailure(flags PreflightFlags, results []CheckResult, ratchet *RatchetResult) recovery.Report {
	details := make([]string, 0)
	for _, result := range results {
		if result.RC == 0 {
			continue
		}
		class := "finding"
		if result.RC >= 2 {
			class = "infrastructure"
		}
		details = append(details, fmt.Sprintf("%s: exit=%d (%s)\n%s", result.Name, result.RC, class, result.Output))
	}
	code := "gate.findings"
	next := "fix the named checks, then rerun substrate-engine gate"
	if ratchet != nil {
		if len(ratchet.Worse) > 0 || len(ratchet.FailureDetails) > 0 {
			code = "gate.ratchet"
			next = "refactor first; if that costs more, present these exact keys and the alternative to the user"
		}
		if len(ratchet.FailureDetails) > 0 {
			details = append(details, ratchet.FailureDetails...)
		} else {
			details = append(details, ratchet.Worse...)
		}
	}
	for _, warning := range ratchetWarnings(ratchet) {
		details = append(details, warning)
	}
	if len(details) == 0 {
		details = append(details, "gate failed without detector details")
	}
	return recovery.Report{Status: "blocked", Code: code, Owner: "agent", Retry: "after-change", Summary: "gate checks did not pass", Details: details, Next: next}
}

func ratchetWarnings(r *RatchetResult) []string {
	if r == nil {
		return nil
	}
	return append([]string(nil), r.BudgetWarn...)
}

func Run(ctx context.Context, args []string) int {
	subDir, repoRoot, err := ResolveRoots()
	if err != nil {
		if containsJSON(args) {
			recovery.Emit(recovery.Report{Status: "blocked", Code: "gate.infrastructure", Owner: "user", Retry: "terminal", Summary: "gate could not resolve repository roots", Details: []string{err.Error()}, Next: "repair the repository setup, then rerun the gate"}, true)
		} else {
			fmt.Fprintf(os.Stderr, "gate: %v\n", err)
		}
		return 12
	}
	flags, rest, err := ParseFlags(args)
	if err != nil {
		if containsJSON(args) {
			recovery.Emit(recovery.Report{Status: "blocked", Code: "gate.infrastructure", Owner: "user", Retry: "terminal", Summary: "gate arguments are invalid", Details: []string{err.Error()}, Next: "correct the command arguments"}, true)
		} else {
			fmt.Fprintf(os.Stderr, "gate: %v\n", err)
		}
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
		if flags.JSON {
			return emitFailure(flags, recovery.Report{Status: "blocked", Code: "gate.infrastructure", Owner: "user", Retry: "terminal", Summary: "gate preflight failed", Details: []string{"preflight rejected the gate inputs"}, Next: "repair the reported preflight issue, then rerun the gate"}, rc)
		}
		return rc
	}
	if flags.AcceptRegression && strings.Contains(","+flags.AcceptKeys+",", ",max_file_lines,") {
		const next = "max_file_lines is a hard budget, not a ratchet; split the file or request a reviewed substrate.json policy change"
		report := recovery.Report{Status: "blocked", Code: "gate.budget-acceptance", Owner: "user", Retry: "terminal", Summary: "max_file_lines cannot be accepted as a regression", Details: []string{next}, Next: next}
		return emitFailure(flags, report, 1)
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
	fmt.Printf("[+] substrate gate: %s (%d checks)\n", repoRoot, len(specs))

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

	var ratchetResult *RatchetResult
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

		var ratchetFailures int
		ratchetResult, ratchetFailures = RunRatchet(metricsPath, baselinePath, configPath, flags)
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
		return emitFailure(flags, gateFailure(flags, ctxRun.Results, ratchetResult), 1)
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
func containsJSON(args []string) bool {
	for _, arg := range args {
		if arg == "--json" {
			return true
		}
	}
	return false
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
