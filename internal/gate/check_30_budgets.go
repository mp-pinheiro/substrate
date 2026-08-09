package gate

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"encoding/json"
)

func check30Budgets(ctx context.Context, inv []string, claims []byte, env map[string]string) (int, []MetricRecord, string, error) {
	configPath := env["CONFIG"]
	data, err := os.ReadFile(configPath)
	if err != nil {
		return 0, nil, "", fmt.Errorf("read config: %w", err)
	}

	var cfg struct {
		Budgets struct {
			MaxFileLines float64 `json:"max_file_lines"`
		} `json:"budgets"`
	}
	if err := json.Unmarshal(data, &cfg); err != nil {
		return 0, nil, "", fmt.Errorf("parse config: %w", err)
	}

	if cfg.Budgets.MaxFileLines == 0 {
		return 0, nil, "budgets opted out in substrate.json (max_file_lines: 0)", nil
	}

	max := 0
	maxFile := ""

	for _, f := range inv {
		if !isClaimed(claims, f) {
			continue
		}
		fullPath := filepath.Join(env["REPO_ROOT"], f)
		data, err := os.ReadFile(fullPath)
		if err != nil {
			continue
		}
		lines := 0
		for _, b := range data {
			if b == '\n' {
				lines++
			}
		}
		if lines > max {
			max = lines
			maxFile = f
		}
	}

	cap := int(cfg.Budgets.MaxFileLines)
	metrics := []MetricRecord{{
		Name:     "max_file_lines",
		RawValue: []byte(strconv.Itoa(max)),
		Dir:      "lo",
	}}

	if max > cap {
		return 1, metrics, fmt.Sprintf("%s: %d lines exceeds the hard cap %d — split it (budgets.max_file_lines in substrate.json)", maxFile, max, cap), nil
	}
	return 0, metrics, "", nil
}
