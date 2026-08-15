package gate

import (
	"context"
	"errors"
	"os"
	"sort"
	"strconv"
	"strings"

	"github.com/mp-pinheiro/substrate/internal/comments"
	"github.com/mp-pinheiro/substrate/internal/config"
)

func check10Comments(ctx context.Context, inv []string, claims []byte, env map[string]string) (int, []MetricRecord, string, error) {
	subDir := env["SUBSTRATE_DIR"]
	repoRoot := env["REPO_ROOT"]

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

	paths, err := config.DiscoverFromSubstrateDir(subDir)
	if err != nil {
		return 0, nil, "", nil
	}
	unscanned := loadUnscanned2(paths.ConfigPath)
	scanFiles := files[:0]
	for _, f := range files {
		if isUnscanned2(f, unscanned) {
			continue
		}
		scanFiles = append(scanFiles, f)
	}
	if len(scanFiles) == 0 {
		return 0, nil, "", nil
	}

	cfg, err := config.LoadConfig(paths.ConfigPath)
	if err != nil || cfg == nil {
		cfg = &config.Config{}
	}
	lm, err := config.LoadLangMap(paths.LangMapPath)
	if err != nil {
		return 0, nil, "", nil
	}
	baseline, err := config.LoadBaseline(paths.BaselinePath)
	if err != nil {
		baseline = nil
	}
	_, statErr := os.Stat(paths.BaselinePath)
	hasBaseline := statErr == nil
	scanner := comments.NewScanner(cfg)

	var findings []string
	var metrics []MetricRecord

	for _, f := range scanFiles {
		result, ratErr := comments.Ratchet(ctx, scanner, lm, baseline, repoRoot, f)
		if ratErr != nil {
			var baselineErr *comments.BaselineMetricError
			if errors.As(ratErr, &baselineErr) {
				continue
			}
			return 2, nil, ratErr.Error(), nil
		}
		metrics = append(metrics, MetricRecord{
			Name:     "comments:" + f,
			RawValue: []byte(strconv.Itoa(result.Count)),
			Dir:      "lo",
		})
		if hasBaseline && result.Blocked {
			for _, finding := range result.Findings {
				findings = append(findings, finding.String())
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
