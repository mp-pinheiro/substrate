package hook

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"github.com/mp-pinheiro/substrate/internal/bashglob"
	"github.com/mp-pinheiro/substrate/internal/comments"
	"github.com/mp-pinheiro/substrate/internal/config"
	"github.com/mp-pinheiro/substrate/internal/vcs"
	"github.com/mp-pinheiro/substrate/internal/xshell"
)

func matchesAny(globs []string, path string) bool {
	for _, g := range globs {
		if bashglob.Match(g, path) {
			return true
		}
	}
	return false
}

func isDeleteStatus(kind vcs.Kind, status string) bool {
	if kind == vcs.KindJJ {
		return status == "D"
	}
	return strings.Contains(status, "D")
}

func sigFile(path string) string {
	sum, err := xshell.SHA256File(path)
	if err != nil {
		return "0"
	}
	return sum
}

// EngineVersion is baked into the hash so a cache never survives an incompatible engine change.
func scanCachePath(repoRoot, baselinePath, configPath string) string {
	ns := sha256.Sum256([]byte(fmt.Sprintf("%s|%s|%s|%s", repoRoot, sigFile(baselinePath), sigFile(configPath), EngineVersion)))
	tmp := os.Getenv("TMPDIR")
	if tmp == "" {
		tmp = "/tmp"
	}
	return filepath.Join(tmp, fmt.Sprintf("substrate-scan-go-%d-%s", os.Getuid(), hex.EncodeToString(ns[:])[:16]))
}

func readCacheLines(path string) map[string]bool {
	data, err := os.ReadFile(path)
	if err != nil {
		return map[string]bool{}
	}
	lines := strings.Split(string(data), "\n")
	set := make(map[string]bool, len(lines))
	for _, l := range lines {
		if l != "" {
			set[l] = true
		}
	}
	return set
}

func appendCacheLines(path string, entries []string) {
	if len(entries) == 0 {
		return
	}
	f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
	if err != nil {
		return
	}
	defer func() { _ = f.Close() }()
	for _, e := range entries {
		_, _ = f.WriteString(e + "\n")
	}
}

func renderRatchetFindings(rel string, r comments.RatchetResult) string {
	var b strings.Builder
	for _, f := range r.Findings {
		b.WriteString(f.String())
		b.WriteString("\n")
	}
	b.WriteString("\ncomment gate: remove the flagged comments or encode the fact in names/structure.\n")
	b.WriteString("A rare, genuinely non-obvious fact may stay: append \"gate:allow-comment\" to the line.\n")
	fmt.Fprintf(&b, "comment ratchet: %s has %d finding(s), grandfathered allowance is %d.\n", rel, r.Count, r.Allowance)
	return b.String()
}

func infraFailureText(err error) (stdout, stderr string) {
	code := 3
	var infra *comments.InfrastructureError
	if errors.As(err, &infra) {
		code = infra.Code
	}
	stdout = fmt.Sprintf("\ncomment ratchet: detector infrastructure failed (rc=%d) — fix it before editing\n", code)
	stderr = err.Error() + "\n"
	return stdout, stderr
}

// renderInfraFailureEntry: order matters — stderr must precede stdout to match bash's `2>&1` capture.
func renderInfraFailureEntry(err error) string {
	stdout, stderr := infraFailureText(err)
	return stderr + stdout
}

// corruptJSON mirrors `jq -e . PATH`: a missing file, invalid JSON, or a
// document whose decoded value is JSON null/false all count as corrupt.
func corruptJSON(path string) bool {
	data, err := os.ReadFile(path)
	if err != nil {
		return true
	}
	var v any
	if err := json.Unmarshal(data, &v); err != nil {
		return true
	}
	if v == nil {
		return true
	}
	b, isBool := v.(bool)
	return isBool && !b
}

func precheckInfra(paths config.Paths) error {
	if corruptJSON(paths.LangMapPath) {
		return &comments.InfrastructureError{Code: 3, Err: fmt.Errorf("comment gate: langmap missing or corrupt: %s", paths.LangMapPath)}
	}
	if corruptJSON(paths.ConfigPath) {
		return &comments.InfrastructureError{Code: 3, Err: fmt.Errorf("comment gate: config missing or corrupt: %s", paths.ConfigPath)}
	}
	return nil
}

func dispatchChangedFilesScan(ctx context.Context, e env, stdin io.Reader) int {
	_, _ = io.ReadAll(stdin)

	paths := e.paths()
	if _, err := os.Stat(paths.ConfigPath); err != nil {
		return 0
	}
	cfg, err := config.LoadConfig(paths.ConfigPath)
	if err != nil || cfg == nil {
		cfg = &config.Config{}
	}
	repo, err := e.repo()
	if err != nil {
		return 0
	}
	changes, err := repo.ChangedSummary(ctx)
	if err != nil {
		return 0
	}

	var changedPaths []string
	for _, c := range changes {
		if !isDeleteStatus(repo.Kind, c.Status) {
			changedPaths = append(changedPaths, c.Path)
		}
	}
	if len(changedPaths) == 0 {
		return 0
	}

	infraErr := precheckInfra(paths)
	var lm *config.LangMap
	if infraErr == nil {
		lm, err = config.LoadLangMap(paths.LangMapPath)
		if err != nil {
			infraErr = &comments.InfrastructureError{Code: 3, Err: err}
		}
	}
	baseline, err := config.LoadBaseline(paths.BaselinePath)
	if err != nil {
		// bash's comment-ratchet.sh treats an unreadable baseline as allowed=0 and proceeds;
		// nil is safe here since Baseline's Allowance has a nil-receiver guard (baseline.go).
		baseline = nil
	}
	scanner := comments.NewScanner(cfg)

	cachePath := scanCachePath(paths.RepoRoot, paths.BaselinePath, paths.ConfigPath)
	cacheLines := readCacheLines(cachePath)
	if len(cacheLines) > 4096 {
		cacheLines = map[string]bool{}
		_ = os.WriteFile(cachePath, nil, 0o600)
	}

	var report strings.Builder
	var newEntries []string
	for _, path := range changedPaths {
		if matchesAny(cfg.ProtectedPaths, path) {
			fmt.Fprintf(&report, "protected path written outside the write hook: %s — revert it and edit the source instead\n", path)
			continue
		}
		full := filepath.Join(paths.RepoRoot, path)
		info, statErr := os.Stat(full)
		if statErr != nil || !info.Mode().IsRegular() {
			continue
		}
		if matchesAny(cfg.Unscanned, path) {
			continue
		}
		key := path + "|" + sigFile(full)
		if cacheLines[key] {
			continue
		}
		if infraErr != nil {
			report.WriteString(renderInfraFailureEntry(infraErr))
			continue
		}
		result, ratchetErr := comments.Ratchet(ctx, scanner, lm, baseline, paths.RepoRoot, path)
		if ratchetErr != nil {
			var baselineErr *comments.BaselineMetricError
			if errors.As(ratchetErr, &baselineErr) {
				report.WriteString(baselineErr.Error() + "\n")
				continue
			}
			report.WriteString(renderInfraFailureEntry(ratchetErr))
			continue
		}
		if result.Blocked {
			report.WriteString(renderRatchetFindings(path, result))
			continue
		}
		newEntries = append(newEntries, key)
	}
	appendCacheLines(cachePath, newEntries)

	if report.Len() == 0 {
		return 0
	}
	writeResult(nil, []byte(report.String()))
	return 2
}

func dispatchCommentRatchet(ctx context.Context, e env, args []string) int {
	if len(args) == 0 || args[0] == "" {
		return 0
	}
	file := args[0]
	if prefix := e.repoRoot + "/"; strings.HasPrefix(file, prefix) {
		file = strings.TrimPrefix(file, prefix)
	}
	full := filepath.Join(e.repoRoot, file)
	info, err := os.Stat(full)
	if err != nil || !info.Mode().IsRegular() {
		return 0
	}

	paths := e.paths()
	if infraErr := precheckInfra(paths); infraErr != nil {
		stdout, stderr := infraFailureText(infraErr)
		writeResult([]byte(stdout), []byte(stderr))
		return 1
	}

	cfg, cfgErr := config.LoadConfig(paths.ConfigPath)
	if cfgErr != nil || cfg == nil {
		cfg = &config.Config{}
	}
	lm, lmErr := config.LoadLangMap(paths.LangMapPath)
	if lmErr != nil {
		stdout, stderr := infraFailureText(&comments.InfrastructureError{Code: 3, Err: lmErr})
		writeResult([]byte(stdout), []byte(stderr))
		return 1
	}
	baseline, baselineErr := config.LoadBaseline(paths.BaselinePath)
	if baselineErr != nil {
		baseline = nil
	}
	scanner := comments.NewScanner(cfg)

	result, ratchetErr := comments.Ratchet(ctx, scanner, lm, baseline, e.repoRoot, file)
	if ratchetErr != nil {
		var baselineErr *comments.BaselineMetricError
		if errors.As(ratchetErr, &baselineErr) {
			writeResult([]byte(baselineErr.Error()+"\n"), nil)
			return 1
		}
		stdout, stderr := infraFailureText(ratchetErr)
		writeResult([]byte(stdout), []byte(stderr))
		return 1
	}
	if result.Blocked {
		writeResult([]byte(renderRatchetFindings(file, result)), nil)
		return 1
	}
	return 0
}
