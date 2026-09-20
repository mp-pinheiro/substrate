package gate

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
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
	unscanned := loadUnscanned2(configPath)
	exempt := make(map[string]bool)
	for _, line := range strings.Split(string(claims), "\n") {
		parts := strings.SplitN(line, "\x1f", 5)
		if len(parts) >= 4 && parts[3] == "exempt" {
			exempt[parts[0]] = true
		}
	}

	max := 0
	capLines := int(cfg.Budgets.MaxFileLines)
	type offender struct {
		path  string
		lines int
	}
	over := make([]offender, 0, 8)

	for _, f := range inv {
		if exempt[f] || isUnscanned2(f, unscanned) || !isClaimed(claims, f) {
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
		}
		if lines > capLines {
			over = append(over, offender{path: f, lines: lines})
		}
	}

	metrics := []MetricRecord{
		{Name: "max_file_lines", RawValue: []byte(strconv.Itoa(max)), Dir: "lo"},
		{Name: "oversized_files", RawValue: []byte(strconv.Itoa(len(over))), Dir: "lo"},
	}

	if len(over) == 0 {
		return 0, metrics, "", nil
	}
	sort.Slice(over, func(i, j int) bool {
		if over[i].lines != over[j].lines {
			return over[i].lines > over[j].lines
		}
		return over[i].path < over[j].path
	})
	shown := over
	if len(shown) > 10 {
		shown = shown[:10]
	}
	names := make([]string, 0, len(shown))
	for _, o := range shown {
		names = append(names, fmt.Sprintf("%s (%d)", o.path, o.lines))
	}
	msg := fmt.Sprintf("%d file(s) over the %d-line target (ratcheted as oversized_files): %s", len(over), capLines, strings.Join(names, ", "))
	if len(over) > len(shown) {
		msg += fmt.Sprintf(", +%d more", len(over)-len(shown))
	}
	return 0, metrics, msg, nil
}
