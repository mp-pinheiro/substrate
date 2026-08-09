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

	shebangInterps := parseShebang2(langmap)
	repoRoot := env["REPO_ROOT"]
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
		if ext == "" && shebangInterps != nil {
			interp := shebangInterp(filepath.Join(repoRoot, f))
			if interp != "" && shebangInterps[interp] {
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
		return matchGlobstar2(pattern, name)
	}
	if strings.HasSuffix(pattern, "/*") {
		return strings.HasPrefix(name, pattern[:len(pattern)-1])
	}
	return false
}

func matchGlobstar2(pattern, name string) bool {
	patParts := strings.Split(pattern, "/")
	nameParts := strings.Split(name, "/")
	return matchGlobstarRec2(patParts, nameParts)
}

func matchGlobstarRec2(pat, name []string) bool {
	if len(pat) == 0 {
		return len(name) == 0
	}
	if pat[0] == "**" {
		for i := 0; i <= len(name); i++ {
			if matchGlobstarRec2(pat[1:], name[i:]) {
				return true
			}
		}
		return false
	}
	if len(name) == 0 {
		return false
	}
	if match, _ := filepath.Match(pat[0], name[0]); !match {
		return false
	}
	return matchGlobstarRec2(pat[1:], name[1:])
}

func parseShebang2(langmap map[string]interface{}) map[string]bool {
	if langmap == nil {
		return nil
	}
	raw, ok := langmap["__shebang__"]
	if !ok {
		return nil
	}
	arr, ok := raw.([]interface{})
	if !ok {
		return nil
	}
	out := make(map[string]bool)
	for _, item := range arr {
		obj, ok := item.(map[string]interface{})
		if !ok {
			continue
		}
		matchArr, ok := obj["match"].([]interface{})
		if !ok {
			continue
		}
		for _, m := range matchArr {
			if s, ok := m.(string); ok {
				out[s] = true
			}
		}
	}
	return out
}
