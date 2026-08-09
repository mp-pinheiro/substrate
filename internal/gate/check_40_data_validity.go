package gate

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"encoding/json"
)

func check40DataValidity(ctx context.Context, inv []string, claims []byte, env map[string]string) (int, []MetricRecord, string, error) {
	repoRoot := env["REPO_ROOT"]
	var findings []string
	rc := 0

	for _, f := range inv {
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
