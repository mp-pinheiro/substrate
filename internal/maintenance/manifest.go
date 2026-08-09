package maintenance

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

func resolveKitRoot() (string, error) {
	if kr := os.Getenv("SUBSTRATE_KIT_ROOT"); kr != "" {
		return kr, nil
	}
	exe, err := os.Executable()
	if err != nil {
		return "", fmt.Errorf("resolve kit root: %w", err)
	}
	return filepath.Dir(filepath.Dir(exe)), nil
}

func ManifestAdd(path string) (string, error) {
	p := strings.TrimPrefix(path, "./")
	if p == "" || p == "." {
		return "", fmt.Errorf("manifest: empty path")
	}
	if filepath.IsAbs(p) {
		return "", fmt.Errorf("manifest: absolute path not allowed: %s", p)
	}
	if strings.HasPrefix(p, "-") {
		return "", fmt.Errorf("manifest: path starts with dash: %s", p)
	}
	if strings.Contains(p, "..") {
		return "", fmt.Errorf("manifest: path contains ..: %s", p)
	}
	if strings.ContainsAny(p, "\t\n") {
		return "", fmt.Errorf("manifest: path contains control characters")
	}
	return p, nil
}

func manifestAssetRoot(path string) (string, error) {
	fi, err := os.Lstat(path)
	if err != nil {
		if os.IsNotExist(err) {
			return ManifestAdd(path)
		}
		return "", fmt.Errorf("manifest: stat %s: %w", path, err)
	}
	if fi.Mode()&os.ModeSymlink != 0 {
		repo, err := os.Getwd()
		if err != nil {
			return "", fmt.Errorf("manifest: getwd: %w", err)
		}
		resolved, err := filepath.EvalSymlinks(path)
		if err != nil {
			return "", fmt.Errorf("manifest: resolve symlink %s: %w", path, err)
		}
		rel, err := filepath.Rel(repo, resolved)
		if err != nil || strings.HasPrefix(rel, "..") {
			return "", fmt.Errorf("manifest: symlink %s resolves outside repo", path)
		}
		return ManifestAdd(rel)
	}
	return ManifestAdd(path)
}

func readProfileTemplates(dir string) ([]string, error) {
	data, err := os.ReadFile(filepath.Join(dir, "profile.json"))
	if err != nil {
		return nil, fmt.Errorf("read profile.json: %w", err)
	}
	var cfg struct {
		Templates []struct {
			Dest string `json:"dest"`
		} `json:"templates"`
	}
	if err := json.Unmarshal(data, &cfg); err != nil {
		return nil, fmt.Errorf("parse profile.json: %w", err)
	}
	var dests []string
	for _, t := range cfg.Templates {
		if t.Dest != "" {
			dests = append(dests, t.Dest)
		}
	}
	return dests, nil
}

func BuildManifest(profiles []string, operation string, checkpoint, acceptBaseline bool, vcs string) ([]string, error) {
	seen := make(map[string]bool)
	var result []string

	add := func(p string) error {
		validated, err := ManifestAdd(p)
		if err != nil {
			return err
		}
		if !seen[validated] {
			seen[validated] = true
			result = append(result, validated)
		}
		return nil
	}

	staticPaths := []string{".substrate", ".omp/extensions/substrate-quality.ts"}
	for _, p := range staticPaths {
		if err := add(p); err != nil {
			return nil, err
		}
	}

	if operation != OpUpdate {
		fixedPaths := []string{
			"substrate.json", ".github/workflows", ".claude/settings.json",
			".omp/lsp.json", "justfile", "Makefile",
		}
		for _, p := range fixedPaths {
			if err := add(p); err != nil {
				return nil, err
			}
		}

		assetDirs := []string{".claude/skills", ".omp/skills", ".claude/agents", ".omp/agents"}
		for _, p := range assetDirs {
			entry, err := manifestAssetRoot(p)
			if err != nil {
				return nil, fmt.Errorf("manifest: asset root %s: %w", p, err)
			}
			if !seen[entry] {
				seen[entry] = true
				result = append(result, entry)
			}
		}

		if vcs == "jj" {
			if err := add("docs/jj-workflow.md"); err != nil {
				return nil, err
			}
		}

		kitRoot, err := resolveKitRoot()
		if err != nil {
			return nil, err
		}
		for _, p := range profiles {
			dir, err := profileDir(p, kitRoot)
			if err != nil {
				return nil, fmt.Errorf("manifest: profile %s: %w", p, err)
			}
			dests, err := readProfileTemplates(dir)
			if err != nil {
				return nil, fmt.Errorf("manifest: profile %s: %w", p, err)
			}
			for _, dest := range dests {
				if err := add(dest); err != nil {
					return nil, err
				}
			}
		}
	}

	if checkpoint || acceptBaseline {
		if err := add("substrate-baseline.json"); err != nil {
			return nil, err
		}
	}

	sort.Strings(result)
	return result, nil
}

func PathInManifest(path string, manifest []string) bool {
	for _, unit := range manifest {
		if unit == "" {
			continue
		}
		if path == unit {
			return true
		}
		if strings.HasPrefix(path, unit+"/") {
			return true
		}
	}
	return false
}
