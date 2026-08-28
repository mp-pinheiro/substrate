package gate

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

func check40DataValidity(ctx context.Context, inv []string, claims []byte, env map[string]string) (int, []MetricRecord, string, error) {
	repoRoot := env["REPO_ROOT"]
	configPath := env["CONFIG"]

	unscanned := loadUnscanned2(configPath)

	var findings []string
	rc := 0

	for _, f := range inv {
		if isUnscanned2(f, unscanned) {
			continue
		}
		if !strings.HasSuffix(f, ".json") {
			continue
		}
		fullPath := filepath.Join(repoRoot, f)
		data, err := os.ReadFile(fullPath)
		if err != nil {
			continue
		}
		if !json.Valid(data) {
			findings = append(findings, fmt.Sprintf("invalid JSON: %s", f))
			rc = 1
		}
	}

	return rc, nil, strings.Join(findings, "\n"), nil
}

func loadUnscanned2(configPath string) []string {
	data, err := os.ReadFile(configPath)
	if err != nil {
		return nil
	}
	var cfg struct {
		Unscanned []string `json:"unscanned"`
	}
	if err := json.Unmarshal(data, &cfg); err != nil {
		return nil
	}
	return cfg.Unscanned
}

func isUnscanned2(path string, patterns []string) bool {
	for _, p := range patterns {
		if matchUnscannedShell(p, path) {
			return true
		}
	}
	return false
}
