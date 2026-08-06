package comments

import (
	"context"
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
	allowance := b.Allowance("comments:" + rel)
	return RatchetResult{
		Findings:  findings,
		Count:     count,
		Allowance: allowance,
		Blocked:   count > allowance,
	}, nil
}
