package comments

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/mp-pinheiro/substrate/internal/config"
)

type RatchetResult struct {
	Findings  []Finding
	Count     int
	Allowance int
	Blocked   bool
}

// BaselineMetricError signals a baseline metric that fails the "non-negative
// whole number" contract — an infrastructure failure, not a clean pass.
type BaselineMetricError struct {
	Key string
	Err error
}

func (e *BaselineMetricError) Error() string {
	return fmt.Sprintf("comment ratchet: baseline metric %s is not a whole number — fix substrate-baseline.json", e.Key)
}

func (e *BaselineMetricError) Unwrap() error { return e.Err }

func Ratchet(ctx context.Context, s *Scanner, lm *config.LangMap, b *config.Baseline, repoRoot, file string) (RatchetResult, error) {
	rel := file
	if prefix := repoRoot + "/"; strings.HasPrefix(file, prefix) {
		rel = strings.TrimPrefix(file, prefix)
	}
	fullPath := filepath.Join(repoRoot, rel)
	info, err := os.Stat(fullPath)
	if err != nil || !info.Mode().IsRegular() {
		return RatchetResult{}, nil
	}

	findings, err := s.ScanFiles(ctx, lm, []string{fullPath})
	if err != nil {
		return RatchetResult{}, err
	}
	for i := range findings {
		findings[i].Name = rel
	}

	count := len(findings)
	key := "comments:" + rel
	allowance, err := b.Allowance(key)
	if err != nil {
		return RatchetResult{}, &BaselineMetricError{Key: key, Err: err}
	}
	return RatchetResult{
		Findings:  findings,
		Count:     count,
		Allowance: allowance,
		Blocked:   count > allowance,
	}, nil
}
