package gate

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

func check05Unclaimed(ctx context.Context, inv []string, claims []byte, env map[string]string) (int, []MetricRecord, string, error) {
	configPath := env["CONFIG"]
	langmapPath := env["LANGMAP"]

	configData, err := os.ReadFile(configPath)
	if err != nil {
		return 0, nil, "", nil
	}
	var cfg struct {
		Unscanned []string `json:"unscanned"`
	}
	if err := json.Unmarshal(configData, &cfg); err != nil {
		return 0, nil, "", nil
	}

	langmapData, err := os.ReadFile(langmapPath)
	if err != nil {
		return 0, nil, "", nil
	}
	var langmap map[string]interface{}
	json.Unmarshal(langmapData, &langmap)

	var findings []string
	rc := 0

	for _, f := range inv {
		if isClaimed(claims, f) {
			continue
		}
		ext := filepath.Ext(f)
		if ext != "" && langmap != nil {
			if _, ok := langmap[ext]; ok {
				continue
			}
		}
		skip := false
		for _, g := range cfg.Unscanned {
			if matchUnscannedShell(g, f) {
				skip = true
				break
			}
		}
		if skip {
			continue
		}
		findings = append(findings, fmt.Sprintf("%s: claimed by no profile — add a profile claim or list it in substrate.json unscanned", f))
		rc = 1
	}

	return rc, nil, strings.Join(findings, "\n"), nil
}

func isClaimed(claims []byte, path string) bool {
	if claims == nil {
		return false
	}
	lines := strings.Split(string(claims), "\n")
	for _, line := range lines {
		idx := strings.IndexByte(line, 0x1f)
		if idx < 0 {
			continue
		}
		if line[:idx] == path {
			return true
		}
	}
	return false
}

func matchUnscannedShell(pattern, name string) bool {
	match, err := filepath.Match(pattern, name)
	if err == nil && match {
		return true
	}
	if strings.HasPrefix(pattern, "*.") {
		return strings.HasSuffix(name, pattern[1:])
	}
	if strings.Contains(pattern, "**") {
		prefix, suffix, _ := strings.Cut(pattern, "**")
		if prefix != "" && !strings.HasPrefix(name, prefix) {
			return false
		}
		if suffix != "" {
			rest := name
			if prefix != "" {
				rest = name[len(prefix):]
			}
			return strings.HasSuffix(rest, suffix)
		}
		return true
	}
	if strings.HasSuffix(pattern, "/*") {
		return strings.HasPrefix(name, pattern[:len(pattern)-1])
	}
	return false
}
