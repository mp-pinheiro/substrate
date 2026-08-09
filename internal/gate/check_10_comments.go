package gate

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"encoding/json"
)

func check10Comments(ctx context.Context, inv []string, claims []byte, env map[string]string) (int, []MetricRecord, string, error) {
	subDir := env["SUBSTRATE_DIR"]
	repoRoot := env["REPO_ROOT"]
	baselinePath := env["BASELINE"]

	var files []string
	for _, f := range inv {
		if !isClaimed(claims, f) {
			continue
		}
		files = append(files, f)
	}
	if len(files) == 0 {
		return 0, nil, "", nil
	}

	script := filepath.Join(subDir, "check-comments.sh")
	cmd := exec.CommandContext(ctx, "bash", append([]string{script}, files...)...)
	cmd.Dir = repoRoot
	out, err := cmd.Output()

	rc := 0
	if cmd.ProcessState != nil {
		rc = cmd.ProcessState.ExitCode()
	}

	if err != nil && rc >= 2 {
		return rc, nil, string(out), nil
	}

	counts := make(map[string]int)
	for _, line := range strings.Split(string(out), "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		idx := strings.Index(line, ":")
		if idx < 0 {
			continue
		}
		f := line[:idx]
		counts[f]++
	}

	var metrics []MetricRecord
	for f, n := range counts {
		metrics = append(metrics, MetricRecord{
			Name:     "comments:" + f,
			RawValue: []byte(strconv.Itoa(n)),
			Dir:      "lo",
		})
	}

	baseData, err := os.ReadFile(baselinePath)
	if err != nil {
		return 0, metrics, "", nil
	}

	var baseline struct {
		Metrics map[string]float64 `json:"metrics"`
	}
	if err := json.Unmarshal(baseData, &baseline); err != nil {
		return 0, metrics, "", nil
	}

	var findings []string
	for f, n := range counts {
		key := "comments:" + f
		base, ok := baseline.Metrics[key]
		if ok && float64(n) > base {
			for _, line := range strings.Split(string(out), "\n") {
				if strings.HasPrefix(line, f+":") {
					findings = append(findings, line)
				}
			}
		}
	}

	if len(findings) > 0 {
		sort.Strings(findings)
		findings = append(findings, "comment gate: remove the flagged comments or encode the fact in names/structure.")
		findings = append(findings, "A rare keeper may stay: append \"gate:allow-comment\" to the line.")
		return 1, metrics, strings.Join(findings, "\n"), nil
	}

	return 0, metrics, "", nil
}
